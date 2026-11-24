# -*- coding: utf-8 -*-
"""听见 Token 管理服务的数据层：SQLite 持久化、迁移和业务规则（只用标准库）。

所有让网关清单变化的操作（签发、改有效期、撤销、停用或删除用户）都在同一个
数据库事务里同时提升对应网关的修订号。
"""
import base64
import datetime
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
# 用量按 15 分钟一格累计：所有时区（含 +5:30、+5:45）的整点和半点都能对齐
USAGE_BUCKET_US = 15 * 60 * 1000000
USAGE_RETENTION_US = 400 * 86400 * 1000000
USAGE_BATCH_RETENTION_US = 2 * 86400 * 1000000
MAX_USAGE_ITEMS = 10000
MAX_USAGE_VALUE = 10 ** 12
BATCH_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
# Token 限流与额度：None 表示不限制
LIMIT_FIELDS = {
    "rate_per_minute": (1, 100000, "每分钟请求数"),
    "max_concurrent": (1, 256, "同时进行的请求数"),
    "daily_audio_minutes": (1, 1440, "每日识别时长（分钟）"),
    "monthly_audio_minutes": (1, 44640, "每月识别时长（分钟）"),
}

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
    # 2: Token 限流与额度、用量统计
    """
    ALTER TABLE tokens ADD COLUMN rate_per_minute INTEGER;
    ALTER TABLE tokens ADD COLUMN max_concurrent INTEGER;
    ALTER TABLE tokens ADD COLUMN daily_audio_minutes INTEGER;
    ALTER TABLE tokens ADD COLUMN monthly_audio_minutes INTEGER;
    ALTER TABLE tokens ADD COLUMN last_used_us INTEGER;
    CREATE TABLE token_usage (
        token_id       TEXT NOT NULL REFERENCES tokens(token_id),
        bucket_us      INTEGER NOT NULL,
        requests       INTEGER NOT NULL DEFAULT 0,
        asr_ms         INTEGER NOT NULL DEFAULT 0,
        mt_requests    INTEGER NOT NULL DEFAULT 0,
        clone_requests INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (token_id, bucket_us)
    );
    CREATE INDEX token_usage_bucket ON token_usage(bucket_us);
    CREATE TABLE usage_batches (
        gateway_id  TEXT NOT NULL,
        batch_id    TEXT NOT NULL,
        received_us INTEGER NOT NULL,
        PRIMARY KEY (gateway_id, batch_id)
    );
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
_DUMMY_HASH = hash_password(secrets.token_hex(8), PASSWORD_ITERATIONS)


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


def parse_limits(body):
    """取出请求体里的限流与额度字段：正整数或 null（不限制）。返回 {列名: 值}，只含出现过的字段。"""
    out = {}
    for field, (low, high, name) in LIMIT_FIELDS.items():
        if field not in body:
            continue
        value = body[field]
        if value is None or value == "":
            out[field] = None
            continue
        if isinstance(value, bool) or not isinstance(value, int):
            raise invalid(field, "%s需要是整数，留空表示不限制" % name)
        if not low <= value <= high:
            raise invalid(field, "%s需要在 %d 到 %d 之间" % (name, low, high))
        out[field] = value
    return out


def limits_view(row):
    keys = row.keys()
    return {field: (row[field] if field in keys else None) for field in LIMIT_FIELDS}


def _local_start_us(year, month, day):
    return int(time.mktime((year, month, day, 0, 0, 0, 0, 0, -1)) * 1000000)


def usage_window(now_us):
    """按管理服务所在电脑的本地时区算出「今天」和「本月」的起止（微秒）。夏令时由 mktime 处理。"""
    local = datetime.datetime.fromtimestamp(now_us / 1000000.0)
    day_start = _local_start_us(local.year, local.month, local.day)
    following = datetime.date(local.year, local.month, local.day) + datetime.timedelta(days=1)
    day_end = _local_start_us(following.year, following.month, following.day)
    month_start = _local_start_us(local.year, local.month, 1)
    year, month = (local.year + 1, 1) if local.month == 12 else (local.year, local.month + 1)
    month_end = _local_start_us(year, month, 1)
    return {"day_start": day_start, "day_end": day_end, "month_start": month_start, "month_end": month_end}


def window_view(window):
    return {key: format_time(value) for key, value in window.items()}


def _usage_counter(value, field):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= MAX_USAGE_VALUE:
        raise invalid(field, "%s 需要是非负整数" % field)
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
        self._snapshot_cache_lock = threading.Lock()
        self._snapshot_cache = {}  # gateway_id -> (revision, cutoff_bucket, items, etag)
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
            connection.execute("PRAGMA synchronous = NORMAL")
            self._local.connection = connection
        return connection

    @contextmanager
    def tx(self, write=True):
        connection = self.conn()
        connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
        try:
            yield connection
            connection.execute("COMMIT")
        except BaseException:
            if connection.in_transaction:
                try:
                    connection.execute("ROLLBACK")
                except sqlite3.Error:
                    pass
            raise

    def migrate(self):
        connection = self.conn()
        try:
            connection.execute("PRAGMA journal_mode = WAL")
        except sqlite3.OperationalError:
            pass
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
                if connection.in_transaction:
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
        """在线一致性备份（服务运行中也可以执行），使用最小权限临时文件原子落盘。"""
        if os.path.exists(destination):
            raise FileExistsError(destination)
        directory = os.path.dirname(os.path.abspath(destination))
        os.makedirs(directory, exist_ok=True)
        tmp = "%s.tmp.%s" % (destination, secrets.token_hex(6))
        if os.name != "nt":
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(fd)
        target = sqlite3.connect(tmp)
        try:
            self.conn().backup(target)
        except BaseException:
            target.close()
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        target.close()
        if os.name != "nt":
            try:
                os.chmod(tmp, 0o600)
            except OSError:
                pass
        os.replace(tmp, destination)
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
        """同一个事务里读修订号和 Token 记录，按 (gateway_id, revision) 缓存避免重复全表扫描。"""
        now = self.now()
        cutoff = now - SNAPSHOT_HISTORY_US
        # 每小时刷新一次历史窗口边界，兼顾过期记录清理与高命中缓存
        cutoff_bucket = cutoff // (3600 * 1000000)
        with self.tx() as connection:
            row = connection.execute("SELECT revision FROM gateways WHERE gateway_id = ?", (gateway_id,)).fetchone()
            if row is None:
                raise StoreError(404, "NOT_FOUND", "没有这个网关")
            revision = row["revision"]
            connection.execute("UPDATE gateways SET snapshot_requests = snapshot_requests + 1, last_snapshot_us = ?"
                               " WHERE gateway_id = ?", (now, gateway_id))
            with self._snapshot_cache_lock:
                cached = self._snapshot_cache.get(gateway_id)
            if cached and cached[0] == revision and cached[1] == cutoff_bucket:
                items, etag = cached[2], cached[3]
            else:
                tokens = connection.execute(
                    "SELECT token_id, user_id, sha256, starts_us, expires_us, revoked_us, rate_per_minute,"
                    " max_concurrent, daily_audio_minutes, monthly_audio_minutes FROM tokens"
                    " WHERE gateway_id = ? AND expires_us >= ?"
                    " AND (revoked_us IS NULL OR revoked_us >= ?)"
                    " ORDER BY token_id", (gateway_id, cutoff, cutoff)).fetchall()
                items = [{
                    "token_id": token["token_id"],
                    "user_id": token["user_id"],
                    "sha256": token["sha256"],
                    "starts_at": format_time(token["starts_us"]),
                    "expires_at": format_time(token["expires_us"]),
                    "revoked_at": format_time(token["revoked_us"]),
                    "limits": {key: value for key, value in limits_view(token).items() if value is not None},
                } for token in tokens]
                content = json.dumps({"revision": revision, "tokens": items}, sort_keys=True,
                                     separators=(",", ":")).encode()
                etag = '"%s"' % hashlib.sha256(content).hexdigest()[:40]
                with self._snapshot_cache_lock:
                    self._snapshot_cache[gateway_id] = (revision, cutoff_bucket, items, etag)
        body = {
            "gateway_id": gateway_id,
            "revision": revision,
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
        now = self.now()
        where, params = [], []
        if status in (None, ""):
            where.append("u.status <> 'deleted'")
        elif status == "all":
            pass
        elif status in USER_STATUSES:
            where.append("u.status = ?")
            params.append(status)
        else:
            raise invalid("status", "status 只能是 active、disabled、deleted 或 all")
        if search:
            pattern = "%" + search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            where.append("(u.username LIKE ? ESCAPE '\\' OR u.display_name LIKE ? ESCAPE '\\')")
            params += [pattern, pattern]
        seq = decode_cursor(cursor)
        if seq is not None:
            where.append("u.rowid < ?")
            params.append(seq)
        sql = (
            "SELECT u.rowid AS seq, u.*,"
            " COUNT(t.token_id) AS token_count,"
            " COALESCE(SUM(CASE WHEN t.token_id IS NOT NULL AND t.revoked_us IS NULL AND t.starts_us <= ? AND t.expires_us > ? THEN 1 ELSE 0 END), 0) AS active_token_count,"
            " COALESCE(SUM(CASE WHEN t.token_id IS NOT NULL AND t.revoked_us IS NULL AND t.starts_us > ? THEN 1 ELSE 0 END), 0) AS scheduled_token_count"
            " FROM users u LEFT JOIN tokens t ON t.user_id = u.user_id"
        )
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " GROUP BY u.user_id ORDER BY u.rowid DESC LIMIT ?"
        connection = self.conn()
        rows = connection.execute(sql, [now, now, now] + params + [limit + 1]).fetchall()
        items = [{
            "user_id": row["user_id"],
            "username": row["username"],
            "display_name": row["display_name"],
            "notes": row["notes"],
            "status": row["status"],
            "token_count": row["token_count"] or 0,
            "active_token_count": row["active_token_count"] or 0,
            "scheduled_token_count": row["scheduled_token_count"] or 0,
            "created_at": format_time(row["created_us"]),
            "updated_at": format_time(row["updated_us"]),
            "disabled_at": format_time(row["disabled_us"]),
            "deleted_at": format_time(row["deleted_us"]),
        } for row in rows[:limit]]
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
            "limits": limits_view(row),
            "created_at": format_time(row["created_us"]),
            "updated_at": format_time(row["updated_us"]),
        }

    def _token_row(self, connection, token_id):
        row = connection.execute("SELECT rowid AS seq, * FROM tokens WHERE token_id = ?", (token_id,)).fetchone()
        if row is None:
            raise StoreError(404, "NOT_FOUND", "没有这个 Token")
        return row

    def get_token(self, token_id):
        connection = self.conn()
        view = self.token_view(self._token_row(connection, token_id))
        view["usage"] = self.usage_summaries(connection, [token_id])[token_id]
        return view

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
        usage = self.usage_summaries(connection, [item["token_id"] for item in items], now)
        for item in items:
            item["usage"] = usage[item["token_id"]]
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
        check_fields(body, ("label", "gateway_id", "starts_at", "expires_at") + tuple(LIMIT_FIELDS))
        label = clean_text(body.get("label"), "label", 100, required=True)
        limits = parse_limits(body)
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
                " expires_us, created_us, updated_us, created_by, rate_per_minute, max_concurrent,"
                " daily_audio_minutes, monthly_audio_minutes) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (token_id, user_id, gateway_id, label, sha256_hex(raw), raw[-6:], starts, expires, now, now,
                 actor["id"]) + tuple(limits.get(field) for field in LIMIT_FIELDS))
            self.bump(connection, [gateway_id], now)
            view = self.token_view(self._token_row(connection, token_id), now)
            self.audit(connection, actor, "token.issue", "token", token_id, after=view, user_id=user_id,
                       token_id=token_id, gateway_id=gateway_id, request_id=request_id)
        result = dict(view)
        result["token"] = raw
        return result

    def update_token(self, token_id, body, actor, request_id=None):
        check_fields(body, ("label", "starts_at", "expires_at") + tuple(LIMIT_FIELDS))
        limits = parse_limits(body)
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
            for field, value in limits.items():
                if value != row[field]:
                    changes[field] = value
            if not changes:
                return before
            changes["updated_us"] = now
            connection.execute("UPDATE tokens SET %s WHERE token_id = ?" % ", ".join("%s = ?" % c for c in changes),
                               list(changes.values()) + [token_id])
            # 有效期、限流和额度都在网关清单里：变了就提升修订号
            if set(changes) & ({"starts_us", "expires_us"} | set(LIMIT_FIELDS)):
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

    # ------------------------------------------------------------ 用量与额度

    @staticmethod
    def _sum_usage(connection, token_ids, since=None, until=None):
        if not token_ids:
            return {}
        where = ["token_id IN (%s)" % ",".join("?" * len(token_ids))]
        params = list(token_ids)
        if since is not None:
            where.append("bucket_us >= ?")
            params.append(since)
        if until is not None:
            where.append("bucket_us < ?")
            params.append(until)
        rows = connection.execute(
            "SELECT token_id, SUM(requests) AS requests, SUM(asr_ms) AS asr_ms, SUM(mt_requests) AS mt_requests,"
            " SUM(clone_requests) AS clone_requests FROM token_usage WHERE %s GROUP BY token_id"
            % " AND ".join(where), params).fetchall()
        return {row["token_id"]: row for row in rows}

    @staticmethod
    def _usage_view(row):
        if row is None:
            return {"requests": 0, "audio_seconds": 0, "translations": 0, "clones": 0}
        return {"requests": row["requests"] or 0, "audio_seconds": round((row["asr_ms"] or 0) / 1000.0, 1),
                "translations": row["mt_requests"] or 0, "clones": row["clone_requests"] or 0}

    def usage_summaries(self, connection, token_ids, now=None):
        """每个 Token 的今日、本月、累计用量和最近使用时间（按管理服务本地时区划分日、月）。"""
        now = self.now() if now is None else now
        token_ids = list(dict.fromkeys(token_ids))
        out = {}
        if not token_ids:
            return out
        window = usage_window(now)
        today = self._sum_usage(connection, token_ids, window["day_start"], window["day_end"])
        month = self._sum_usage(connection, token_ids, window["month_start"], window["month_end"])
        total = self._sum_usage(connection, token_ids)
        last = {row["token_id"]: row["last_used_us"] for row in connection.execute(
            "SELECT token_id, last_used_us FROM tokens WHERE token_id IN (%s)" % ",".join("?" * len(token_ids)),
            token_ids)}
        for token_id in token_ids:
            out[token_id] = {
                "last_used_at": format_time(last.get(token_id)),
                "today": self._usage_view(today.get(token_id)),
                "month": self._usage_view(month.get(token_id)),
                "total": self._usage_view(total.get(token_id)),
            }
        return out

    def token_usage(self, token_id, days=30):
        """一个 Token 最近 N 天每天的用量（本地日期）。"""
        try:
            days = int(days)
        except (TypeError, ValueError):
            raise invalid("days", "days 需要是整数")
        days = max(1, min(days, 400))
        connection = self.conn()
        row = self._token_row(connection, token_id)
        now = self.now()
        window = usage_window(now)
        today = datetime.date.fromtimestamp(now / 1000000.0)
        first = today - datetime.timedelta(days=days - 1)
        since = _local_start_us(first.year, first.month, first.day)
        buckets = connection.execute(
            "SELECT bucket_us, requests, asr_ms, mt_requests, clone_requests FROM token_usage"
            " WHERE token_id = ? AND bucket_us >= ? AND bucket_us < ?",
            (token_id, since, window["day_end"])).fetchall()
        daily = {}
        for bucket in buckets:
            date = datetime.date.fromtimestamp(bucket["bucket_us"] / 1000000.0).isoformat()
            entry = daily.setdefault(date, [0, 0, 0, 0])
            entry[0] += bucket["requests"]
            entry[1] += bucket["asr_ms"]
            entry[2] += bucket["mt_requests"]
            entry[3] += bucket["clone_requests"]
        series = []
        for offset in range(days):
            date = (first + datetime.timedelta(days=offset)).isoformat()
            requests, asr_ms, mt, clone = daily.get(date, [0, 0, 0, 0])
            series.append({"date": date, "requests": requests, "audio_seconds": round(asr_ms / 1000.0, 1),
                           "translations": mt, "clones": clone})
        summary = self.usage_summaries(connection, [token_id], now)[token_id]
        return {"token_id": token_id, "limits": limits_view(row), "window": window_view(window),
                "timezone": time.strftime("%z"), "daily": series, **summary}

    def _quota_totals(self, connection, gateway_id, window):
        rows = connection.execute(
            "SELECT token_id FROM tokens WHERE gateway_id = ? AND expires_us > ?"
            " AND (revoked_us IS NULL OR revoked_us > ?)"
            " AND (daily_audio_minutes IS NOT NULL OR monthly_audio_minutes IS NOT NULL)",
            (gateway_id, window["month_start"], window["month_start"])).fetchall()
        ids = [row["token_id"] for row in rows]
        totals = []
        for start in range(0, len(ids), 500):
            chunk = ids[start:start + 500]
            day = self._sum_usage(connection, chunk, window["day_start"], window["day_end"])
            month = self._sum_usage(connection, chunk, window["month_start"], window["month_end"])
            for token_id in chunk:
                totals.append({"token_id": token_id,
                               "day_asr_ms": (day[token_id]["asr_ms"] or 0) if token_id in day else 0,
                               "month_asr_ms": (month[token_id]["asr_ms"] or 0) if token_id in month else 0})
        return totals

    def record_usage(self, gateway_id, body):
        """网关批量上报用量（幂等：同一个 batch_id 只记一次），返回本网关有额度限制的 Token 的已用量。"""
        if not isinstance(body, dict):
            raise invalid("body", "请求体需要是 JSON 对象")
        batch_id = body.get("batch_id")
        if not isinstance(batch_id, str) or not BATCH_ID_RE.match(batch_id):
            raise invalid("batch_id", "batch_id 不合法")
        items = body.get("items", [])
        if not isinstance(items, list) or len(items) > MAX_USAGE_ITEMS:
            raise invalid("items", "items 需要是列表，最多 %d 条" % MAX_USAGE_ITEMS)
        now = self.now()
        parsed = []
        for item in items:
            if not isinstance(item, dict) or not isinstance(item.get("token_id"), str):
                raise invalid("items", "用量记录格式不对")
            try:
                bucket = parse_time(item.get("bucket_start"))
            except (TypeError, ValueError):
                raise invalid("bucket_start", "bucket_start 不合法")
            if bucket % USAGE_BUCKET_US or not now - 40 * 86400 * 1000000 <= bucket <= now + 3600 * 1000000:
                raise invalid("bucket_start", "bucket_start 需要是最近 40 天内的 15 分钟整格")
            last_used = item.get("last_used_at")
            if last_used is not None:
                try:
                    last_used = min(parse_time(last_used), now)
                except (TypeError, ValueError):
                    raise invalid("last_used_at", "last_used_at 不合法")
            parsed.append((item["token_id"], bucket, _usage_counter(item.get("requests", 0), "requests"),
                           _usage_counter(item.get("asr_ms", 0), "asr_ms"),
                           _usage_counter(item.get("mt_requests", 0), "mt_requests"),
                           _usage_counter(item.get("clone_requests", 0), "clone_requests"), last_used))
        window = usage_window(now)
        with self.tx() as connection:
            if connection.execute("SELECT 1 FROM gateways WHERE gateway_id = ?", (gateway_id,)).fetchone() is None:
                raise StoreError(404, "NOT_FOUND", "没有这个网关")
            duplicate = connection.execute("SELECT 1 FROM usage_batches WHERE gateway_id = ? AND batch_id = ?",
                                           (gateway_id, batch_id)).fetchone() is not None
            accepted = 0
            if not duplicate:
                connection.execute("INSERT INTO usage_batches VALUES (?, ?, ?)", (gateway_id, batch_id, now))
                owned = set()
                ids = sorted({entry[0] for entry in parsed})
                for start in range(0, len(ids), 500):
                    chunk = ids[start:start + 500]
                    owned.update(row["token_id"] for row in connection.execute(
                        "SELECT token_id FROM tokens WHERE gateway_id = ? AND token_id IN (%s)"
                        % ",".join("?" * len(chunk)), [gateway_id] + chunk))
                for token_id, bucket, requests, asr_ms, mt, clone, last_used in parsed:
                    # 只认本网关签发的 Token：别的网关的记录直接丢弃
                    if token_id not in owned:
                        continue
                    accepted += 1
                    connection.execute(
                        "INSERT INTO token_usage (token_id, bucket_us, requests, asr_ms, mt_requests, clone_requests)"
                        " VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(token_id, bucket_us) DO UPDATE SET"
                        " requests = requests + excluded.requests, asr_ms = asr_ms + excluded.asr_ms,"
                        " mt_requests = mt_requests + excluded.mt_requests,"
                        " clone_requests = clone_requests + excluded.clone_requests",
                        (token_id, bucket, requests, asr_ms, mt, clone))
                    if last_used is not None:
                        connection.execute("UPDATE tokens SET last_used_us = MAX(COALESCE(last_used_us, 0), ?)"
                                           " WHERE token_id = ?", (last_used, token_id))
                connection.execute("DELETE FROM usage_batches WHERE received_us < ?",
                                   (now - USAGE_BATCH_RETENTION_US,))
                connection.execute("DELETE FROM token_usage WHERE bucket_us < ?", (now - USAGE_RETENTION_US,))
            totals = self._quota_totals(connection, gateway_id, window)
        return {"gateway_id": gateway_id, "batch_id": batch_id, "duplicate": duplicate, "accepted": accepted,
                "server_time": format_time(now), "window": window_view(window), "totals": totals}
