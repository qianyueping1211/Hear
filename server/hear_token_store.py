# -*- coding: utf-8 -*-
"""听见 Token 管理服务的数据层：SQLite 持久化、迁移和业务规则（只用标准库）。

所有让网关清单变化的操作（签发、改有效期、撤销、停用或删除用户）都在同一个
数据库事务里同时提升对应网关的修订号。
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager

from hear_auth import describe, format_time, parse_time

TOKEN_PREFIX = "hear_ut_"
GATEWAY_CREDENTIAL_PREFIX = "hear_gw_"
SNAPSHOT_HISTORY_US = 90 * 86400 * 1000000
SESSION_ABSOLUTE_US = 8 * 3600 * 1000000
SESSION_IDLE_US = 60 * 60 * 1000000
PASSWORD_ITERATIONS = 600000
MAX_LIMIT = 200

USERNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$")
GATEWAY_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$")
TOKEN_STATUSES = ("scheduled", "active", "expired", "revoked")
USER_STATUSES = ("active", "disabled", "deleted")

MIGRATIONS = [
    # 1: 初始结构
    """
    CREATE TABLE admins (
        admin_id      TEXT PRIMARY KEY,
        username      TEXT NOT NULL,
        username_key  TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role          TEXT NOT NULL CHECK (role IN ('admin', 'viewer')),
        status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
        created_us    INTEGER NOT NULL,
        updated_us    INTEGER NOT NULL
    );
    CREATE TABLE admin_sessions (
        session_sha256 TEXT PRIMARY KEY,
        admin_id       TEXT NOT NULL REFERENCES admins(admin_id),
        csrf_token     TEXT NOT NULL,
        created_us     INTEGER NOT NULL,
        last_seen_us   INTEGER NOT NULL,
        expires_us     INTEGER NOT NULL
    );
    CREATE TABLE gateways (
        gateway_id         TEXT PRIMARY KEY,
        name               TEXT NOT NULL DEFAULT '',
        credential_sha256  TEXT NOT NULL UNIQUE,
        revision           INTEGER NOT NULL DEFAULT 0,
        snapshot_requests  INTEGER NOT NULL DEFAULT 0,
        last_snapshot_us   INTEGER,
        credential_rotated_us INTEGER NOT NULL,
        created_us         INTEGER NOT NULL,
        updated_us         INTEGER NOT NULL
    );
    CREATE TABLE users (
        user_id      TEXT PRIMARY KEY,
        username     TEXT NOT NULL,
        username_key TEXT NOT NULL,
        display_name TEXT NOT NULL DEFAULT '',
        notes        TEXT NOT NULL DEFAULT '',
        status       TEXT NOT NULL CHECK (status IN ('active', 'disabled', 'deleted')),
        created_us   INTEGER NOT NULL,
        updated_us   INTEGER NOT NULL,
        disabled_us  INTEGER,
        deleted_us   INTEGER
    );
    CREATE UNIQUE INDEX users_live_username ON users(username_key) WHERE status <> 'deleted';
    CREATE TABLE tokens (
        token_id          TEXT PRIMARY KEY,
        user_id           TEXT NOT NULL REFERENCES users(user_id),
        gateway_id        TEXT NOT NULL REFERENCES gateways(gateway_id),
        label             TEXT NOT NULL,
        sha256            TEXT NOT NULL UNIQUE,
        token_suffix      TEXT NOT NULL,
        starts_us         INTEGER NOT NULL,
        expires_us        INTEGER NOT NULL,
        revoked_us        INTEGER,
        revocation_reason TEXT,
        created_us        INTEGER NOT NULL,
        updated_us        INTEGER NOT NULL,
        created_by        TEXT NOT NULL,
        CHECK (expires_us > starts_us)
    );
    CREATE INDEX tokens_user ON tokens(user_id);
    CREATE INDEX tokens_gateway ON tokens(gateway_id, expires_us);
    CREATE TABLE audit_events (
        seq          INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id     TEXT NOT NULL UNIQUE,
        occurred_us  INTEGER NOT NULL,
        actor_type   TEXT NOT NULL,
        actor_id     TEXT NOT NULL,
        actor_name   TEXT NOT NULL,
        action       TEXT NOT NULL,
        target_type  TEXT NOT NULL,
        target_id    TEXT NOT NULL,
        user_id      TEXT,
        token_id     TEXT,
        gateway_id   TEXT,
        before_json  TEXT,
        after_json   TEXT,
        request_id   TEXT
    );
    CREATE INDEX audit_time ON audit_events(occurred_us);
    CREATE INDEX audit_user ON audit_events(user_id);
    CREATE INDEX audit_token ON audit_events(token_id);
    """,
]


class StoreError(Exception):
    def __init__(self, http_status, code, message, field=None):
        super().__init__(message)
        self.http_status = http_status
        self.code = code
        self.message = message
        self.field = field


def invalid(field, message):
    return StoreError(422, "VALIDATION_FAILED", message, field)


def new_id(prefix):
    return prefix + secrets.token_hex(8)


def sha256_hex(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def hash_password(password, iterations=PASSWORD_ITERATIONS):
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return "pbkdf2_sha256$%d$%s$%s" % (iterations, base64.b64encode(salt).decode(), base64.b64encode(digest).decode())


def check_password(password, stored):
    try:
        scheme, iterations, salt, digest = stored.split("$")
        if scheme != "pbkdf2_sha256":
            return False
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), base64.b64decode(salt), int(iterations))
        return hmac.compare_digest(actual, base64.b64decode(digest))
    except (ValueError, TypeError):
        return False


# 登录失败时也做一次同样耗时的计算，避免用耗时区分“用户名不存在”
_DUMMY_HASH = hash_password(secrets.token_hex(8), 1000)


def encode_cursor(seq):
    return base64.urlsafe_b64encode(json.dumps([seq]).encode()).decode().rstrip("=")


def decode_cursor(cursor):
    if not cursor:
        return None
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        value = json.loads(base64.urlsafe_b64decode(padded.encode()).decode())
        if isinstance(value, list) and len(value) == 1 and isinstance(value[0], int):
            return value[0]
    except (ValueError, UnicodeDecodeError):
        pass
    raise invalid("cursor", "cursor 不合法")


def parse_limit(value, default=50):
    if value in (None, ""):
        return default
    try:
        limit = int(value)
    except (TypeError, ValueError):
        raise invalid("limit", "limit 需要是 1 到 %d 的整数" % MAX_LIMIT)
    if not 1 <= limit <= MAX_LIMIT:
        raise invalid("limit", "limit 需要是 1 到 %d 的整数" % MAX_LIMIT)
    return limit


def parse_api_time(value, field):
    try:
        return parse_time(value)
    except (TypeError, ValueError):
        raise invalid(field, "%s 需要是带时区的 ISO 8601 时间，例如 2027-01-15T08:00:00+08:00" % field)


def clean_text(value, field, max_length, required=False):
    if value is None:
        if required:
            raise invalid(field, "%s 必填" % field)
        return ""
    if not isinstance(value, str):
        raise invalid(field, "%s 需要是字符串" % field)
    value = value.strip()
    if required and not value:
        raise invalid(field, "%s 必填" % field)
    if len(value) > max_length:
        raise invalid(field, "%s 最长 %d 个字符" % (field, max_length))
    if any(ord(ch) < 32 and ch not in "\n\t" for ch in value):
        raise invalid(field, "%s 含有控制字符" % field)
    return value


def check_fields(body, allowed):
    if not isinstance(body, dict):
        raise invalid(None, "请求体需要是 JSON 对象")
    unknown = sorted(set(body) - set(allowed))
    if unknown:
        raise invalid(unknown[0], "不支持的字段：%s" % ", ".join(unknown))


class Store:
    def __init__(self, path, clock=time.time):
        self.path = path
        self.clock = clock
        self._local = threading.local()
        directory = os.path.dirname(os.path.abspath(path))
        os.makedirs(directory, exist_ok=True)

    # ------------------------------------------------------------ 连接与事务

    def now(self):
        return int(self.clock() * 1000000)

    def conn(self):
        connection = getattr(self._local, "connection", None)
        if connection is None:
            connection = sqlite3.connect(self.path, timeout=10, isolation_level=None, check_same_thread=False)
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute("PRAGMA busy_timeout = 10000")
            try:
                connection.execute("PRAGMA journal_mode = WAL")
            except sqlite3.OperationalError:
                pass
            connection.execute("PRAGMA synchronous = FULL")
            self._local.connection = connection
        return connection

    @contextmanager
    def tx(self, write=True):
        connection = self.conn()
        connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
        try:
            yield connection
        except BaseException:
            connection.execute("ROLLBACK")
            raise
        else:
            connection.execute("COMMIT")

    def migrate(self):
        connection = self.conn()
        connection.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_us INTEGER NOT NULL)")
        current = connection.execute("SELECT COALESCE(MAX(version), 0) FROM schema_migrations").fetchone()[0]
        applied = []
        for version, script in enumerate(MIGRATIONS, start=1):
            if version <= current:
                continue
            connection.execute("BEGIN IMMEDIATE")
            try:
                for statement in [part.strip() for part in script.split(";") if part.strip()]:
                    connection.execute(statement)
                connection.execute("INSERT INTO schema_migrations VALUES (?, ?)", (version, self.now()))
                connection.execute("COMMIT")
            except BaseException:
                connection.execute("ROLLBACK")
                raise
            applied.append(version)
        if os.name != "nt":
            for suffix in ("", "-wal", "-shm"):
                try:
                    os.chmod(self.path + suffix, 0o600)
                except OSError:
                    pass
        return applied

    def schema_version(self):
        return self.conn().execute("SELECT COALESCE(MAX(version), 0) FROM schema_migrations").fetchone()[0]

    def backup(self, destination):
        """在线一致性备份（服务运行中也可以执行）。"""
        if os.path.exists(destination):
            raise FileExistsError(destination)
        target = sqlite3.connect(destination)
        try:
            self.conn().backup(target)
        finally:
            target.close()
        return destination

    # ------------------------------------------------------------ 审计

    def audit(self, connection, actor, action, target_type, target_id, before=None, after=None,
              user_id=None, token_id=None, gateway_id=None, request_id=None):
        connection.execute(
            "INSERT INTO audit_events (event_id, occurred_us, actor_type, actor_id, actor_name, action,"
            " target_type, target_id, user_id, token_id, gateway_id, before_json, after_json, request_id)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (new_id("evt_"), self.now(), actor["type"], actor["id"], actor.get("username", ""), action,
             target_type, target_id, user_id, token_id, gateway_id,
             None if before is None else json.dumps(before, ensure_ascii=False, sort_keys=True),
             None if after is None else json.dumps(after, ensure_ascii=False, sort_keys=True),
             request_id))

    def list_audit(self, action=None, user_id=None, token_id=None, actor_id=None, since=None, until=None,
                   limit=None, cursor=None):
        limit = parse_limit(limit)
        where, params = [], []
        for column, value in (("action", action), ("user_id", user_id), ("token_id", token_id),
                              ("actor_id", actor_id)):
            if value:
                where.append("%s = ?" % column)
                params.append(value)
        if since:
            where.append("occurred_us >= ?")
            params.append(parse_api_time(since, "since"))
        if until:
            where.append("occurred_us < ?")
            params.append(parse_api_time(until, "until"))
        seq = decode_cursor(cursor)
        if seq is not None:
            where.append("seq < ?")
            params.append(seq)
        sql = "SELECT * FROM audit_events"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY seq DESC LIMIT ?"
        rows = self.conn().execute(sql, params + [limit + 1]).fetchall()
        items = [{
            "event_id": row["event_id"],
            "occurred_at": format_time(row["occurred_us"]),
            "actor": {"type": row["actor_type"], "id": row["actor_id"], "username": row["actor_name"]},
            "action": row["action"],
            "target_type": row["target_type"],
            "target_id": row["target_id"],
            "user_id": row["user_id"],
            "token_id": row["token_id"],
            "gateway_id": row["gateway_id"],
            "before": json.loads(row["before_json"]) if row["before_json"] else None,
            "after": json.loads(row["after_json"]) if row["after_json"] else None,
            "request_id": row["request_id"],
        } for row in rows[:limit]]
        next_cursor = encode_cursor(rows[limit - 1]["seq"]) if len(rows) > limit else None
        return {"items": items, "next_cursor": next_cursor}

    # ------------------------------------------------------------ 管理员与会话

    def create_admin(self, username, password, role="admin", actor=None):
        if not USERNAME_RE.match(username or ""):
            raise invalid("username", "管理员用户名只能用字母、数字和 _ . @ -，最长 64 个字符")
        if role not in ("admin", "viewer"):
            raise invalid("role", "role 只能是 admin 或 viewer")
        if len(password or "") < 12:
            raise invalid("password", "管理员密码至少 12 个字符")
        now = self.now()
        admin_id = new_id("adm_")
        actor = actor or {"type": "cli", "id": "cli", "username": "cli"}
        with self.tx() as connection:
            if connection.execute("SELECT 1 FROM admins WHERE username_key = ?", (username.lower(),)).fetchone():
                raise StoreError(409, "USERNAME_TAKEN", "管理员用户名已存在", "username")
            connection.execute("INSERT INTO admins VALUES (?, ?, ?, ?, ?, 'active', ?, ?)",
                               (admin_id, username, username.lower(), hash_password(password), role, now, now))
            self.audit(connection, actor, "admin.create", "admin", admin_id,
                       after={"username": username, "role": role})
        return {"admin_id": admin_id, "username": username, "role": role}

    def set_admin_password(self, username, password, actor=None):
        if len(password or "") < 12:
            raise invalid("password", "管理员密码至少 12 个字符")
        actor = actor or {"type": "cli", "id": "cli", "username": "cli"}
        with self.tx() as connection:
            row = connection.execute("SELECT admin_id FROM admins WHERE username_key = ?",
                                     (username.lower(),)).fetchone()
            if row is None:
                raise StoreError(404, "NOT_FOUND", "没有这个管理员")
            connection.execute("UPDATE admins SET password_hash = ?, updated_us = ? WHERE admin_id = ?",
                               (hash_password(password), self.now(), row["admin_id"]))
            # 改密码后旧会话全部作废
            connection.execute("DELETE FROM admin_sessions WHERE admin_id = ?", (row["admin_id"],))
            self.audit(connection, actor, "admin.password_reset", "admin", row["admin_id"])

    def authenticate(self, username, password):
        row = self.conn().execute("SELECT * FROM admins WHERE username_key = ?",
                                  ((username or "").lower(),)).fetchone()
        if row is None or row["status"] != "active":
            check_password(password or "", _DUMMY_HASH)
            return None
        if not check_password(password or "", row["password_hash"]):
            return None
        return {"admin_id": row["admin_id"], "username": row["username"], "role": row["role"]}

    def create_session(self, admin):
        raw = secrets.token_urlsafe(32)
        csrf = secrets.token_urlsafe(32)
        now = self.now()
        with self.tx() as connection:
            connection.execute("DELETE FROM admin_sessions WHERE expires_us <= ? OR last_seen_us <= ?",
                               (now, now - SESSION_IDLE_US))
            connection.execute("INSERT INTO admin_sessions VALUES (?, ?, ?, ?, ?, ?)",
                               (sha256_hex(raw), admin["admin_id"], csrf, now, now, now + SESSION_ABSOLUTE_US))
            self.audit(connection, self.actor(admin), "admin.login", "admin", admin["admin_id"])
        return raw, csrf

    def session(self, raw):
        if not raw or len(raw) > 200:
            return None
        now = self.now()
        connection = self.conn()
        row = connection.execute(
            "SELECT s.*, a.username, a.role, a.status FROM admin_sessions s JOIN admins a USING (admin_id)"
            " WHERE s.session_sha256 = ?", (sha256_hex(raw),)).fetchone()
        if row is None or row["status"] != "active" or row["expires_us"] <= now \
                or row["last_seen_us"] <= now - SESSION_IDLE_US:
            return None
        if now - row["last_seen_us"] > 60 * 1000000:
            connection.execute("UPDATE admin_sessions SET last_seen_us = ? WHERE session_sha256 = ?",
                               (now, row["session_sha256"]))
        return {"admin_id": row["admin_id"], "username": row["username"], "role": row["role"],
                "csrf_token": row["csrf_token"], "expires_at": format_time(row["expires_us"])}

    def delete_session(self, raw, admin=None):
        with self.tx() as connection:
            connection.execute("DELETE FROM admin_sessions WHERE session_sha256 = ?", (sha256_hex(raw or ""),))
            if admin:
                self.audit(connection, self.actor(admin), "admin.logout", "admin", admin["admin_id"])

    @staticmethod
    def actor(admin):
        return {"type": "admin", "id": admin["admin_id"], "username": admin["username"]}

    # ------------------------------------------------------------ 网关

    def gateway_view(self, row):
        return {
            "gateway_id": row["gateway_id"],
            "name": row["name"],
            "revision": row["revision"],
            "snapshot_requests": row["snapshot_requests"],
            "last_snapshot_at": format_time(row["last_snapshot_us"]),
            "credential_rotated_at": format_time(row["credential_rotated_us"]),
            "created_at": format_time(row["created_us"]),
            "updated_at": format_time(row["updated_us"]),
        }

    def list_gateways(self):
        rows = self.conn().execute("SELECT * FROM gateways ORDER BY gateway_id").fetchall()
        return {"items": [self.gateway_view(row) for row in rows], "next_cursor": None}

    def create_gateway(self, gateway_id, name="", actor=None, request_id=None):
        if not isinstance(gateway_id, str) or not GATEWAY_ID_RE.match(gateway_id):
            raise invalid("gateway_id", "gateway_id 只能用字母、数字和 _ . : -，最长 64 个字符")
        name = clean_text(name, "name", 100)
        credential = GATEWAY_CREDENTIAL_PREFIX + secrets.token_urlsafe(32)
        now = self.now()
        actor = actor or {"type": "cli", "id": "cli", "username": "cli"}
        with self.tx() as connection:
            if connection.execute("SELECT 1 FROM gateways WHERE gateway_id = ?", (gateway_id,)).fetchone():
                raise StoreError(409, "GATEWAY_EXISTS", "网关 ID 已存在", "gateway_id")
            connection.execute(
                "INSERT INTO gateways (gateway_id, name, credential_sha256, revision, credential_rotated_us,"
                " created_us, updated_us) VALUES (?, ?, ?, 1, ?, ?, ?)",
                (gateway_id, name, sha256_hex(credential), now, now, now))
            row = connection.execute("SELECT * FROM gateways WHERE gateway_id = ?", (gateway_id,)).fetchone()
            view = self.gateway_view(row)
            self.audit(connection, actor, "gateway.create", "gateway", gateway_id, after=view,
                       gateway_id=gateway_id, request_id=request_id)
        return view, credential

    def rotate_gateway_credential(self, gateway_id, actor=None, request_id=None):
        credential = GATEWAY_CREDENTIAL_PREFIX + secrets.token_urlsafe(32)
        now = self.now()
        actor = actor or {"type": "cli", "id": "cli", "username": "cli"}
        with self.tx() as connection:
            row = connection.execute("SELECT * FROM gateways WHERE gateway_id = ?", (gateway_id,)).fetchone()
            if row is None:
                raise StoreError(404, "NOT_FOUND", "没有这个网关")
            connection.execute("UPDATE gateways SET credential_sha256 = ?, credential_rotated_us = ?, updated_us = ?"
                               " WHERE gateway_id = ?", (sha256_hex(credential), now, now, gateway_id))
            self.audit(connection, actor, "gateway.rotate_credential", "gateway", gateway_id,
                       gateway_id=gateway_id, request_id=request_id)
            row = connection.execute("SELECT * FROM gateways WHERE gateway_id = ?", (gateway_id,)).fetchone()
        return self.gateway_view(row), credential

    def gateway_for_credential(self, credential):
        if not credential or not credential.startswith(GATEWAY_CREDENTIAL_PREFIX) or len(credential) > 200:
            return None
        row = self.conn().execute("SELECT gateway_id FROM gateways WHERE credential_sha256 = ?",
                                  (sha256_hex(credential),)).fetchone()
        return row["gateway_id"] if row else None

    def snapshot(self, gateway_id):
        """同一个事务里读修订号和 Token 记录，保证两者一致。"""
        now = self.now()
        with self.tx() as connection:
            row = connection.execute("SELECT revision FROM gateways WHERE gateway_id = ?", (gateway_id,)).fetchone()
            if row is None:
                raise StoreError(404, "NOT_FOUND", "没有这个网关")
            tokens = connection.execute(
                "SELECT token_id, user_id, sha256, starts_us, expires_us, revoked_us FROM tokens"
                " WHERE gateway_id = ? AND MIN(COALESCE(revoked_us, expires_us), expires_us) >= ?"
                " ORDER BY token_id", (gateway_id, now - SNAPSHOT_HISTORY_US)).fetchall()
            connection.execute("UPDATE gateways SET snapshot_requests = snapshot_requests + 1, last_snapshot_us = ?"
                               " WHERE gateway_id = ?", (now, gateway_id))
        items = [{
            "token_id": token["token_id"],
            "user_id": token["user_id"],
            "sha256": token["sha256"],
            "starts_at": format_time(token["starts_us"]),
            "expires_at": format_time(token["expires_us"]),
            "revoked_at": format_time(token["revoked_us"]),
        } for token in tokens]
        content = json.dumps({"revision": row["revision"], "tokens": items}, sort_keys=True,
                             separators=(",", ":")).encode()
        etag = '"%s"' % hashlib.sha256(content).hexdigest()[:40]
        body = {
            "gateway_id": gateway_id,
            "revision": row["revision"],
            "generated_at": format_time(now),
            "digest_algorithm": "sha256",
            "tokens": items,
        }
        return body, etag

    @staticmethod
    def bump(connection, gateway_ids, now):
        # 修订号取 max(原值 + 1, 当前 Unix 秒)：从旧备份恢复后再提升一次，就一定高于网关已见过的值
        for gateway_id in sorted(set(gateway_ids)):
            connection.execute("UPDATE gateways SET revision = MAX(revision + 1, ?), updated_us = ? WHERE gateway_id = ?",
                               (now // 1000000, now, gateway_id))

    def bump_all(self):
        """服务启动时调用：数据库若是从旧备份恢复的，修订号也不会低于网关内存里的值。"""
        now = self.now()
        with self.tx() as connection:
            ids = [row["gateway_id"] for row in connection.execute("SELECT gateway_id FROM gateways")]
            self.bump(connection, ids, now)

    # ------------------------------------------------------------ 用户

    def user_view(self, row, connection=None):
        connection = connection or self.conn()
        now = self.now()
        counts = connection.execute(
            "SELECT COUNT(*) AS total,"
            " SUM(CASE WHEN revoked_us IS NULL AND starts_us <= ? AND expires_us > ? THEN 1 ELSE 0 END) AS active,"
            " SUM(CASE WHEN revoked_us IS NULL AND starts_us > ? THEN 1 ELSE 0 END) AS scheduled"
            " FROM tokens WHERE user_id = ?", (now, now, now, row["user_id"])).fetchone()
        return {
            "user_id": row["user_id"],
            "username": row["username"],
            "display_name": row["display_name"],
            "notes": row["notes"],
            "status": row["status"],
            "token_count": counts["total"] or 0,
            "active_token_count": counts["active"] or 0,
            "scheduled_token_count": counts["scheduled"] or 0,
            "created_at": format_time(row["created_us"]),
            "updated_at": format_time(row["updated_us"]),
            "disabled_at": format_time(row["disabled_us"]),
            "deleted_at": format_time(row["deleted_us"]),
        }

    def _user_row(self, connection, user_id):
        row = connection.execute("SELECT rowid AS seq, * FROM users WHERE user_id = ?", (user_id,)).fetchone()
        if row is None:
            raise StoreError(404, "NOT_FOUND", "没有这个用户")
        return row

    def list_users(self, search=None, status=None, limit=None, cursor=None):
        limit = parse_limit(limit)
        where, params = [], []
        if status in (None, ""):
            where.append("status <> 'deleted'")
        elif status == "all":
            pass
        elif status in USER_STATUSES:
            where.append("status = ?")
            params.append(status)
        else:
            raise invalid("status", "status 只能是 active、disabled、deleted 或 all")
        if search:
            pattern = "%" + search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            where.append("(username LIKE ? ESCAPE '\\' OR display_name LIKE ? ESCAPE '\\')")
            params += [pattern, pattern]
        seq = decode_cursor(cursor)
        if seq is not None:
            where.append("rowid < ?")
            params.append(seq)
        sql = "SELECT rowid AS seq, * FROM users"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY rowid DESC LIMIT ?"
        connection = self.conn()
        rows = connection.execute(sql, params + [limit + 1]).fetchall()
        items = [self.user_view(row, connection) for row in rows[:limit]]
        return {"items": items, "next_cursor": encode_cursor(rows[limit - 1]["seq"]) if len(rows) > limit else None}

    def get_user(self, user_id):
        connection = self.conn()
        return self.user_view(self._user_row(connection, user_id), connection)

    def _check_username(self, connection, username, exclude=None):
        if not isinstance(username, str) or not USERNAME_RE.match(username.strip()):
            raise invalid("username", "用户名只能用字母、数字和 _ . @ -，以字母或数字开头，最长 64 个字符")
        username = username.strip()
        row = connection.execute("SELECT user_id FROM users WHERE username_key = ? AND status <> 'deleted'",
                                 (username.lower(),)).fetchone()
        if row is not None and row["user_id"] != exclude:
            raise StoreError(409, "USERNAME_TAKEN", "用户名已存在", "username")
        return username

    def create_user(self, body, actor, request_id=None):
        check_fields(body, ("username", "display_name", "notes"))
        display_name = clean_text(body.get("display_name"), "display_name", 100)
        notes = clean_text(body.get("notes"), "notes", 2000)
        now = self.now()
        user_id = new_id("usr_")
        with self.tx() as connection:
            username = self._check_username(connection, body.get("username"))
            connection.execute("INSERT INTO users (user_id, username, username_key, display_name, notes, status,"
                               " created_us, updated_us) VALUES (?, ?, ?, ?, ?, 'active', ?, ?)",
                               (user_id, username, username.lower(), display_name, notes, now, now))
            view = self.user_view(self._user_row(connection, user_id), connection)
            self.audit(connection, actor, "user.create", "user", user_id, after=view, user_id=user_id,
                       request_id=request_id)
        return view

    def _revoke_user_tokens(self, connection, user_id, reason, now, actor, request_id):
        rows = connection.execute(
            "SELECT * FROM tokens WHERE user_id = ? AND revoked_us IS NULL AND expires_us > ?",
            (user_id, now)).fetchall()
        for row in rows:
            before = self.token_view(row)
            connection.execute("UPDATE tokens SET revoked_us = ?, revocation_reason = ?, updated_us = ?"
                               " WHERE token_id = ?", (now, reason, now, row["token_id"]))
            after = self.token_view(connection.execute("SELECT * FROM tokens WHERE token_id = ?",
                                                       (row["token_id"],)).fetchone())
            self.audit(connection, actor, "token.revoke", "token", row["token_id"], before, after,
                       user_id=user_id, token_id=row["token_id"], gateway_id=row["gateway_id"],
                       request_id=request_id)
        self.bump(connection, [row["gateway_id"] for row in rows], now)
        return len(rows)

    def update_user(self, user_id, body, actor, request_id=None):
        check_fields(body, ("username", "display_name", "notes", "status"))
        now = self.now()
        with self.tx() as connection:
            row = self._user_row(connection, user_id)
            if row["status"] == "deleted":
                raise StoreError(409, "USER_DELETED", "用户已删除，不能修改")
            before = self.user_view(row, connection)
            changes = {}
            if "username" in body:
                changes["username"] = self._check_username(connection, body["username"], exclude=user_id)
                changes["username_key"] = changes["username"].lower()
            if "display_name" in body:
                changes["display_name"] = clean_text(body["display_name"], "display_name", 100)
            if "notes" in body:
                changes["notes"] = clean_text(body["notes"], "notes", 2000)
            status = body.get("status")
            if "status" in body:
                if status not in ("active", "disabled"):
                    raise invalid("status", "status 只能是 active 或 disabled（删除请用 DELETE）")
                if status != row["status"]:
                    changes["status"] = status
                    changes["disabled_us"] = now if status == "disabled" else None
            if changes:
                changes["updated_us"] = now
                assignments = ", ".join("%s = ?" % column for column in changes)
                connection.execute("UPDATE users SET %s WHERE user_id = ?" % assignments,
                                   list(changes.values()) + [user_id])
                if changes.get("status") == "disabled":
                    self._revoke_user_tokens(connection, user_id, "user_disabled", now, actor, request_id)
                after = self.user_view(self._user_row(connection, user_id), connection)
                action = {"disabled": "user.disable", "active": "user.enable"}.get(changes.get("status"), "user.update")
                self.audit(connection, actor, action, "user", user_id, before, after, user_id=user_id,
                           request_id=request_id)
            else:
                after = before
        return after

    def delete_user(self, user_id, actor, request_id=None):
        now = self.now()
        with self.tx() as connection:
            row = self._user_row(connection, user_id)
            if row["status"] == "deleted":
                return
            before = self.user_view(row, connection)
            connection.execute("UPDATE users SET status = 'deleted', deleted_us = ?, updated_us = ? WHERE user_id = ?",
                               (now, now, user_id))
            self._revoke_user_tokens(connection, user_id, "user_deleted", now, actor, request_id)
            after = self.user_view(self._user_row(connection, user_id), connection)
            self.audit(connection, actor, "user.delete", "user", user_id, before, after, user_id=user_id,
                       request_id=request_id)

    # ------------------------------------------------------------ Token

    def token_view(self, row, now=None):
        now = self.now() if now is None else now
        state = describe({"starts_at": row["starts_us"], "expires_at": row["expires_us"],
                          "revoked_at": row["revoked_us"]}, now)
        return {
            "token_id": row["token_id"],
            "user_id": row["user_id"],
            "gateway_id": row["gateway_id"],
            "label": row["label"],
            "token_suffix": row["token_suffix"],
            "status": state["status"],
            "starts_at": state["starts_at"],
            "expires_at": state["expires_at"],
            "effective_expires_at": state["effective_expires_at"],
            "invalidated_at": state["invalidated_at"],
            "revocation_reason": row["revocation_reason"],
            "created_at": format_time(row["created_us"]),
            "updated_at": format_time(row["updated_us"]),
        }

    def _token_row(self, connection, token_id):
        row = connection.execute("SELECT rowid AS seq, * FROM tokens WHERE token_id = ?", (token_id,)).fetchone()
        if row is None:
            raise StoreError(404, "NOT_FOUND", "没有这个 Token")
        return row

    def get_token(self, token_id):
        return self.token_view(self._token_row(self.conn(), token_id))

    def list_user_tokens(self, user_id, status=None, limit=None, cursor=None):
        limit = parse_limit(limit)
        connection = self.conn()
        self._user_row(connection, user_id)
        now = self.now()
        where, params = ["user_id = ?"], [user_id]
        if status:
            conditions = {
                "scheduled": ("revoked_us IS NULL AND starts_us > ? AND expires_us > ?", [now, now]),
                "active": ("revoked_us IS NULL AND starts_us <= ? AND expires_us > ?", [now, now]),
                "expired": ("(revoked_us IS NULL OR revoked_us >= expires_us) AND expires_us <= ?", [now]),
                "revoked": ("revoked_us IS NOT NULL AND revoked_us < expires_us", []),
            }
            if status not in conditions:
                raise invalid("status", "status 只能是 scheduled、active、expired 或 revoked")
            condition, extra = conditions[status]
            where.append("(%s)" % condition)
            params += extra
        seq = decode_cursor(cursor)
        if seq is not None:
            where.append("rowid < ?")
            params.append(seq)
        rows = connection.execute("SELECT rowid AS seq, * FROM tokens WHERE %s ORDER BY rowid DESC LIMIT ?"
                                  % " AND ".join(where), params + [limit + 1]).fetchall()
        items = [self.token_view(row, now) for row in rows[:limit]]
        return {"items": items, "next_cursor": encode_cursor(rows[limit - 1]["seq"]) if len(rows) > limit else None}

    def _validity(self, body, starts_default, expires_default, now):
        starts = parse_api_time(body["starts_at"], "starts_at") if body.get("starts_at") is not None else starts_default
        if "expires_at" in body or expires_default is None:
            if body.get("expires_at") in (None, ""):
                raise invalid("expires_at", "expires_at 必填")
            expires = parse_api_time(body["expires_at"], "expires_at")
        else:
            expires = expires_default
        if expires <= starts:
            raise invalid("expires_at", "结束时间需要晚于开始时间")
        if expires <= now:
            raise invalid("expires_at", "结束时间需要晚于当前时间")
        return starts, expires

    def issue_token(self, user_id, body, actor, request_id=None, _allow_past=False):
        check_fields(body, ("label", "gateway_id", "starts_at", "expires_at"))
        label = clean_text(body.get("label"), "label", 100, required=True)
        gateway_id = body.get("gateway_id")
        if not isinstance(gateway_id, str) or not gateway_id:
            raise invalid("gateway_id", "gateway_id 必填")
        now = self.now()
        if _allow_past:
            starts = parse_api_time(body["starts_at"], "starts_at")
            expires = parse_api_time(body["expires_at"], "expires_at")
            if expires <= starts:
                raise invalid("expires_at", "结束时间需要晚于开始时间")
        else:
            starts, expires = self._validity(body, now, None, now)
        raw = TOKEN_PREFIX + secrets.token_urlsafe(32)  # 32 字节 = 256 位随机熵
        token_id = new_id("tok_")
        with self.tx() as connection:
            user = self._user_row(connection, user_id)
            if user["status"] != "active":
                raise StoreError(409, "USER_NOT_ACTIVE", "用户已停用或删除，不能签发 Token")
            if connection.execute("SELECT 1 FROM gateways WHERE gateway_id = ?", (gateway_id,)).fetchone() is None:
                raise invalid("gateway_id", "没有这个网关")
            connection.execute(
                "INSERT INTO tokens (token_id, user_id, gateway_id, label, sha256, token_suffix, starts_us,"
                " expires_us, created_us, updated_us, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (token_id, user_id, gateway_id, label, sha256_hex(raw), raw[-6:], starts, expires, now, now,
                 actor["id"]))
            self.bump(connection, [gateway_id], now)
            view = self.token_view(self._token_row(connection, token_id), now)
            self.audit(connection, actor, "token.issue", "token", token_id, after=view, user_id=user_id,
                       token_id=token_id, gateway_id=gateway_id, request_id=request_id)
        result = dict(view)
        result["token"] = raw
        return result

    def update_token(self, token_id, body, actor, request_id=None):
        check_fields(body, ("label", "starts_at", "expires_at"))
        now = self.now()
        with self.tx() as connection:
            row = self._token_row(connection, token_id)
            before = self.token_view(row, now)
            if before["status"] in ("expired", "revoked"):
                raise StoreError(409, "TOKEN_NOT_EDITABLE", "已失效的 Token 不能修改，请签发新 Token")
            changes = {}
            if "label" in body:
                changes["label"] = clean_text(body["label"], "label", 100, required=True)
            if "starts_at" in body or "expires_at" in body:
                if "starts_at" in body and body["starts_at"] is None:
                    raise invalid("starts_at", "starts_at 不能为空")
                starts, expires = self._validity(body, row["starts_us"], row["expires_us"], now)
                if starts != row["starts_us"]:
                    changes["starts_us"] = starts
                if expires != row["expires_us"]:
                    changes["expires_us"] = expires
            if not changes:
                return before
            changes["updated_us"] = now
            connection.execute("UPDATE tokens SET %s WHERE token_id = ?" % ", ".join("%s = ?" % c for c in changes),
                               list(changes.values()) + [token_id])
            if "starts_us" in changes or "expires_us" in changes:
                self.bump(connection, [row["gateway_id"]], now)
            after = self.token_view(self._token_row(connection, token_id), now)
            self.audit(connection, actor, "token.update", "token", token_id, before, after, user_id=row["user_id"],
                       token_id=token_id, gateway_id=row["gateway_id"], request_id=request_id)
        return after

    def revoke_token(self, token_id, reason, actor, request_id=None):
        reason = clean_text(reason, "reason", 200) or "admin_revoked"
        now = self.now()
        with self.tx() as connection:
            row = self._token_row(connection, token_id)
            before = self.token_view(row, now)
            if before["status"] in ("revoked", "expired"):
                return before  # 重复撤销或已到期：保持原状态，结果相同
            connection.execute("UPDATE tokens SET revoked_us = ?, revocation_reason = ?, updated_us = ?"
                               " WHERE token_id = ?", (now, reason, now, token_id))
            self.bump(connection, [row["gateway_id"]], now)
            after = self.token_view(self._token_row(connection, token_id), now)
            self.audit(connection, actor, "token.revoke", "token", token_id, before, after, user_id=row["user_id"],
                       token_id=token_id, gateway_id=row["gateway_id"], request_id=request_id)
        return after
