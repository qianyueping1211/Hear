#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""听见 Token 管理服务（B/S 管理后台 + 管理 API + 网关内部 API），只用 Python 标准库。

    python hear_token_service.py init
    python hear_token_service.py create-admin --username admin
    python hear_token_service.py create-gateway --id hear-home --name 家里 --credential-out gateway.cred
    python hear_token_service.py serve --host 127.0.0.1 --port 8443 --tls-cert cert.pem --tls-key key.pem

接口：
    /admin/                                    浏览器管理后台
    /admin/api/v1/...                          管理 API（管理员会话 + CSRF）
    /internal/v1/gateways/{id}/token-snapshot  网关清单（Bearer 网关凭据）
    /healthz                                   服务存活检查
"""
import argparse
import getpass
import ipaddress
import json
import os
import re
import secrets
import ssl
import sys
import threading
import time
from hmac import compare_digest
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from hear_token_store import Store, StoreError, SESSION_ABSOLUTE_US  # noqa: E402

DEFAULT_DB = os.environ.get("HEAR_TOKEN_DB", os.path.join(HERE, "token-data", "hear-tokens.db"))
COOKIE_NAME = "hear_admin_sid"
MAX_JSON_BODY = 64 * 1024
STATIC_FILES = {
    "/admin/": ("hear_token_admin.html", "text/html; charset=utf-8"),
    "/admin/app.js": ("hear_token_admin.js", "text/javascript; charset=utf-8"),
    "/admin/app.css": ("hear_token_admin.css", "text/css; charset=utf-8"),
}
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
       "form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def log(message):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        print("[%s] %s" % (stamp, message), flush=True)
    except (OSError, ValueError):
        pass


class LoginThrottle:
    """同一来源 + 用户名 15 分钟内失败 5 次，锁定 15 分钟。"""

    def __init__(self, limit=5, window=900.0, lock=900.0, clock=time.monotonic):
        self.limit, self.window, self.lock_seconds, self.clock = limit, window, lock, clock
        self.failures = {}
        self.guard = threading.Lock()

    def blocked(self, key):
        with self.guard:
            # 满额时拒绝新用户名，不能清空已有的锁定记录让攻击者重试。
            if key not in self.failures and len(self.failures) >= 10000:
                self._prune_expired()
                if len(self.failures) >= 10000:
                    return True
            entry = self.failures.get(key)
            return bool(entry and entry[2] and entry[2] > self.clock())

    def _prune_expired(self):
        now = self.clock()
        for key, (_, first, locked) in list(self.failures.items()):
            if now - first > self.window and locked <= now:
                del self.failures[key]

    def fail(self, key):
        now = self.clock()
        with self.guard:
            count, first, locked = self.failures.get(key, (0, now, 0))
            if now - first > self.window:
                count, first = 0, now
            count += 1
            locked = now + self.lock_seconds if count >= self.limit else 0
            if key not in self.failures and len(self.failures) >= 10000:
                self._prune_expired()
                if len(self.failures) >= 10000:
                    return
            self.failures[key] = (count, first, locked)

    def succeed(self, key):
        with self.guard:
            self.failures.pop(key, None)


class ApiError(Exception):
    def __init__(self, http_status, code, message, field=None, headers=None):
        super().__init__(message)
        self.http_status, self.code, self.message, self.field = http_status, code, message, field
        self.headers = headers or {}


ROUTES = []


def route(method, pattern, auth):
    """auth: public / login / read / write / gateway"""
    compiled = re.compile("^" + pattern + "$")

    def register(function):
        ROUTES.append((method, compiled, auth, function))
        return function
    return register


class Handler(BaseHTTPRequestHandler):
    server_version = "HearTokenService/1.0"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 30

    # ------------------------------------------------------------ 基础

    def setup(self):
        super().setup()
        self.request_id = None

    def log_message(self, fmt, *args):
        pass  # 不记录默认访问日志（里面有原始请求行）；用 _access_log 记录脱敏信息

    def _access_log(self, status):
        elapsed = (time.monotonic() - getattr(self, "_started", time.monotonic())) * 1000
        path = urlsplit(self.path).path
        log("%s %s %d %.0fms request_id=%s" % (self.command, path, status, elapsed, self.request_id))

    @property
    def store(self):
        return self.server.store

    def _new_request_id(self):
        incoming = (self.headers.get("X-Request-Id") or "").strip()
        self.request_id = incoming if REQUEST_ID_RE.match(incoming) else "req_" + secrets.token_hex(8)

    def _security_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Request-Id", self.request_id or "")
        if self.server.tls:
            self.send_header("Strict-Transport-Security", "max-age=31536000")

    def _send(self, status, body=b"", content_type="application/json; charset=utf-8", headers=None):
        if not getattr(self, "_body_read", True) and (self.headers.get("Content-Length") or "0") != "0":
            # 请求体没读：这条连接不能再复用
            self.close_connection = True
        try:
            self.send_response(status)
            self._security_headers()
            for name, value in (headers or {}).items():
                if isinstance(value, list):
                    for item in value:
                        self.send_header(name, item)
                else:
                    self.send_header(name, value)
            if status != 304 and status != 204:
                self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            if self.close_connection:
                self.send_header("Connection", "close")
            self.end_headers()
            if body and self.command != "HEAD":
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError):
            self.close_connection = True
        self._access_log(status)

    def _json(self, status, obj, headers=None):
        self._send(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"), headers=headers)

    def _api_error(self, error):
        body = {"code": error.code, "message": error.message, "request_id": self.request_id}
        if error.field:
            body["field"] = error.field
        self._json(error.http_status, body, headers=error.headers)

    def _read_json(self):
        content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if self.headers.get("Transfer-Encoding"):
            self.close_connection = True
            raise ApiError(400, "BAD_REQUEST", "不支持分块请求体")
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            raise ApiError(400, "BAD_REQUEST", "Content-Length 不合法")
        if length < 0:
            self.close_connection = True
            raise ApiError(400, "BAD_REQUEST", "Content-Length 不合法")
        if length > MAX_JSON_BODY:
            self.close_connection = True
            raise ApiError(413, "PAYLOAD_TOO_LARGE", "请求体过大")
        try:
            raw = self.rfile.read(length) if length else b""
        except TimeoutError:
            self.close_connection = True
            raise ApiError(408, "REQUEST_TIMEOUT", "请求体接收超时")
        if len(raw) != length:
            self.close_connection = True
            raise ApiError(400, "BAD_REQUEST", "请求体未传输完整")
        self._body_read = True
        if not raw:
            return {}
        if content_type != "application/json":
            raise ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "请求体需要是 application/json")
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise ApiError(400, "BAD_REQUEST", "请求体不是有效的 JSON")

    def _cookie(self):
        header = self.headers.get("Cookie")
        if not header:
            return None
        try:
            jar = SimpleCookie()
            jar.load(header)
        except Exception:
            return None
        morsel = jar.get(COOKIE_NAME)
        return morsel.value if morsel else None

    def _session_cookie(self, value, max_age):
        parts = ["%s=%s" % (COOKIE_NAME, value), "Path=/admin", "HttpOnly", "SameSite=Strict",
                 "Max-Age=%d" % max_age]
        if self.server.tls or self.server.secure_cookie:
            parts.append("Secure")
        return "; ".join(parts)

    def _same_origin(self):
        """写操作的同源检查：浏览器带了 Origin / Sec-Fetch-Site 就必须是同源。"""
        site = (self.headers.get("Sec-Fetch-Site") or "").lower()
        if site and site not in ("same-origin", "none"):
            return False
        origin = self.headers.get("Origin")
        if not origin:
            return True
        host = self.headers.get("Host") or ""
        try:
            netloc = urlsplit(origin).netloc
        except ValueError:
            return False
        return netloc.lower() == host.lower() or origin in self.server.allowed_origins

    # ------------------------------------------------------------ 分发

    def do_HEAD(self):
        self._dispatch("GET")

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def do_PUT(self):
        self._dispatch("PUT")

    def _dispatch(self, method):
        self._started = time.monotonic()
        self._body_read = False
        self._new_request_id()
        parts = urlsplit(self.path)
        path = parts.path
        try:
            if method == "GET" and path == "/favicon.ico":
                self._send(204)
                return
            if method == "GET" and path in ("/", "/admin"):
                self._send(302, headers={"Location": "/admin/"})
                return
            if method == "GET" and path in STATIC_FILES:
                self._static(path)
                return
            matched_path = False
            for route_method, pattern, auth, function in ROUTES:
                match = pattern.match(path)
                if not match:
                    continue
                matched_path = True
                if route_method != method:
                    continue
                self.query = {key: values[-1] for key, values in parse_qs(parts.query).items()}
                self.admin = None
                params = [unquote(value) for value in match.groups()]
                self._authorize(auth)
                function(self, *params)
                return
            if matched_path:
                raise ApiError(405, "METHOD_NOT_ALLOWED", "不支持这个方法")
            raise ApiError(404, "NOT_FOUND", "没有这个接口")
        except ApiError as error:
            self._api_error(error)
        except StoreError as error:
            self._api_error(ApiError(error.http_status, error.code, error.message, error.field))
        except Exception as error:  # noqa: BLE001
            log("内部错误 request_id=%s：%s" % (self.request_id, type(error).__name__))
            import traceback
            traceback.print_exc()
            self._api_error(ApiError(500, "INTERNAL_ERROR", "服务内部错误"))

    def _authorize(self, auth):
        if auth in ("public", "gateway"):
            return
        if auth == "login":
            if not self._same_origin():
                raise ApiError(403, "CSRF_FAILED", "跨站请求被拒绝")
            return
        session = self.store.session(self._cookie())
        if session is None:
            raise ApiError(401, "UNAUTHENTICATED", "请先登录管理后台")
        self.admin = session
        if auth == "write":
            token = self.headers.get("X-CSRF-Token") or ""
            if not self._same_origin() or not compare_digest(token.encode(), session["csrf_token"].encode()):
                raise ApiError(403, "CSRF_FAILED", "CSRF 校验失败，请刷新页面后重试")
            if session["role"] != "admin":
                raise ApiError(403, "FORBIDDEN", "当前管理员是只读角色")

    def _static(self, path):
        name, content_type = STATIC_FILES[path]
        try:
            with open(os.path.join(HERE, name), "rb") as file:
                body = file.read()
        except OSError:
            raise ApiError(404, "NOT_FOUND", "管理后台页面文件缺失：%s" % name)
        self._send(200, body, content_type)

    @property
    def actor(self):
        return Store.actor(self.admin)

    def client_ip(self):
        return self.client_address[0] if self.client_address else "-"


# ------------------------------------------------------------------ 公共

@route("GET", r"/healthz", "public")
def healthz(handler):
    handler._json(200, {"ok": True, "schema_version": handler.store.schema_version()})


# ------------------------------------------------------------------ 会话

@route("POST", r"/admin/api/v1/session", "login")
def login(handler):
    body = handler._read_json()
    username = body.get("username") if isinstance(body, dict) else None
    password = body.get("password") if isinstance(body, dict) else None
    if not isinstance(username, str) or not isinstance(password, str):
        raise ApiError(422, "VALIDATION_FAILED", "请输入用户名和密码")
    key = (handler.client_ip(), username.lower())
    if handler.server.throttle.blocked(key):
        raise ApiError(429, "RATE_LIMITED", "登录失败次数过多，请 15 分钟后再试", headers={"Retry-After": "900"})
    admin = handler.store.authenticate(username, password)
    if admin is None:
        handler.server.throttle.fail(key)
        log("管理员登录失败 ip=%s request_id=%s" % (handler.client_ip(), handler.request_id))
        raise ApiError(401, "INVALID_CREDENTIALS", "用户名或密码不对")
    handler.server.throttle.succeed(key)
    raw, csrf = handler.store.create_session(admin)
    handler._json(201, {"admin": admin, "csrf_token": csrf},
                  headers={"Set-Cookie": handler._session_cookie(raw, SESSION_ABSOLUTE_US // 1000000)})


@route("GET", r"/admin/api/v1/session", "read")
def current_session(handler):
    admin = {key: handler.admin[key] for key in ("admin_id", "username", "role")}
    handler._json(200, {"admin": admin, "csrf_token": handler.admin["csrf_token"],
                        "expires_at": handler.admin["expires_at"]})


@route("DELETE", r"/admin/api/v1/session", "read")
def logout(handler):
    token = handler.headers.get("X-CSRF-Token") or ""
    if not handler._same_origin() or not compare_digest(token.encode(), handler.admin["csrf_token"].encode()):
        raise ApiError(403, "CSRF_FAILED", "CSRF 校验失败，请刷新页面后重试")
    handler.store.delete_session(handler._cookie(), handler.admin)
    handler._send(204, headers={"Set-Cookie": handler._session_cookie("", 0)})


# ------------------------------------------------------------------ 用户

@route("GET", r"/admin/api/v1/users", "read")
def list_users(handler):
    q = handler.query
    handler._json(200, handler.store.list_users(q.get("search"), q.get("status"), q.get("limit"), q.get("cursor")))


@route("POST", r"/admin/api/v1/users", "write")
def create_user(handler):
    handler._json(201, handler.store.create_user(handler._read_json(), handler.actor, handler.request_id))


@route("GET", r"/admin/api/v1/users/([^/]+)", "read")
def get_user(handler, user_id):
    handler._json(200, handler.store.get_user(user_id))


@route("PATCH", r"/admin/api/v1/users/([^/]+)", "write")
def update_user(handler, user_id):
    handler._json(200, handler.store.update_user(user_id, handler._read_json(), handler.actor, handler.request_id))


@route("DELETE", r"/admin/api/v1/users/([^/]+)", "write")
def delete_user(handler, user_id):
    handler.store.delete_user(user_id, handler.actor, handler.request_id)
    handler._send(204)


@route("GET", r"/admin/api/v1/users/([^/]+)/tokens", "read")
def list_tokens(handler, user_id):
    q = handler.query
    handler._json(200, handler.store.list_user_tokens(user_id, q.get("status"), q.get("limit"), q.get("cursor")))


@route("POST", r"/admin/api/v1/users/([^/]+)/tokens", "write")
def issue_token(handler, user_id):
    result = handler.store.issue_token(user_id, handler._read_json(), handler.actor, handler.request_id)
    log("签发 Token token_id=%s user_id=%s request_id=%s" % (result["token_id"], user_id, handler.request_id))
    handler._json(201, result)


# ------------------------------------------------------------------ Token

@route("GET", r"/admin/api/v1/tokens/([^/]+)", "read")
def get_token(handler, token_id):
    handler._json(200, handler.store.get_token(token_id))


@route("PATCH", r"/admin/api/v1/tokens/([^/]+)", "write")
def update_token(handler, token_id):
    handler._json(200, handler.store.update_token(token_id, handler._read_json(), handler.actor, handler.request_id))


@route("POST", r"/admin/api/v1/tokens/([^/]+)/revoke", "write")
def revoke_token(handler, token_id):
    body = handler._read_json()
    if not isinstance(body, dict):
        raise ApiError(422, "VALIDATION_FAILED", "请求体需要是 JSON 对象")
    handler.store.revoke_token(token_id, body.get("reason"), handler.actor, handler.request_id)
    handler._send(204)


# ------------------------------------------------------------------ 审计与网关

@route("GET", r"/admin/api/v1/audit-events", "read")
def audit_events(handler):
    q = handler.query
    handler._json(200, handler.store.list_audit(q.get("action"), q.get("user_id"), q.get("token_id"),
                                                q.get("actor_id"), q.get("since"), q.get("until"),
                                                q.get("limit"), q.get("cursor")))


@route("GET", r"/admin/api/v1/gateways", "read")
def list_gateways(handler):
    handler._json(200, handler.store.list_gateways())


@route("POST", r"/admin/api/v1/gateways", "write")
def create_gateway(handler):
    body = handler._read_json()
    if not isinstance(body, dict):
        raise ApiError(422, "VALIDATION_FAILED", "请求体需要是 JSON 对象")
    view, credential = handler.store.create_gateway(body.get("gateway_id"), body.get("name"), handler.actor,
                                                    handler.request_id)
    view["credential"] = credential
    handler._json(201, view)


@route("POST", r"/admin/api/v1/gateways/([^/]+)/rotate-credential", "write")
def rotate_gateway(handler, gateway_id):
    view, credential = handler.store.rotate_gateway_credential(gateway_id, handler.actor, handler.request_id)
    view["credential"] = credential
    handler._json(200, view)


# ------------------------------------------------------------------ 网关内部 API

@route("GET", r"/internal/v1/gateways/([^/]+)/token-snapshot", "gateway")
def token_snapshot(handler, gateway_id):
    header = handler.headers.get("Authorization") or ""
    scheme, _, credential = header.partition(" ")
    owner = handler.store.gateway_for_credential(credential.strip()) if scheme.lower() == "bearer" else None
    if owner is None:
        raise ApiError(401, "GATEWAY_UNAUTHORIZED", "网关凭据无效",
                       headers={"WWW-Authenticate": 'Bearer realm="hear-gateway"'})
    if not compare_digest(owner.encode(), gateway_id.encode()):
        raise ApiError(403, "GATEWAY_FORBIDDEN", "网关凭据无权读取这个网关的清单")
    body, etag = handler.store.snapshot(gateway_id)
    tags = [tag.strip() for tag in (handler.headers.get("If-None-Match") or "").split(",") if tag.strip()]
    if etag in tags:
        handler._send(304, headers={"ETag": etag})
        return
    handler._json(200, body, headers={"ETag": etag})


# ------------------------------------------------------------------ 服务器

class TokenServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, store, ssl_context=None, secure_cookie=False, allowed_origins=()):
        super().__init__(address, Handler)
        self.store = store
        self.tls = ssl_context is not None
        self.secure_cookie = secure_cookie
        self.allowed_origins = set(allowed_origins)
        self.throttle = LoginThrottle()
        if ssl_context is not None:
            # 握手放到各自的处理线程里做，慢客户端不会挡住 accept
            self.socket = ssl_context.wrap_socket(self.socket, server_side=True, do_handshake_on_connect=False)

    def handle_error(self, request, client_address):
        error = sys.exc_info()[1]
        if isinstance(error, (ssl.SSLError, ConnectionError, TimeoutError)):
            return
        super().handle_error(request, client_address)


def make_tls_context(cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return context


def is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


# ------------------------------------------------------------------ 命令行

def read_new_password(args):
    if args.password_stdin:
        password = sys.stdin.readline().rstrip("\r\n")
    else:
        password = getpass.getpass("新密码（至少 12 个字符，不回显）：")
        if password != getpass.getpass("再输入一次："):
            raise SystemExit("两次输入不一致")
    return password


def write_secret_file(path, secret):
    """凭据写进只有当前用户能读的新文件（不覆盖已有文件）。"""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write(secret + "\n")
    if os.name == "nt":
        log("Windows 上请再收紧文件权限：icacls \"%s\" /inheritance:r /grant:r \"%%USERNAME%%:R\"" % path)


def deliver_secret(path, secret, what):
    if path:
        write_secret_file(path, secret)
        print("%s已写入 %s（只显示这一次，请妥善保管）" % (what, path))
    else:
        print("%s（只显示这一次，请立即保存到受保护的文件）：" % what)
        print(secret)


def cmd_init(store, args):
    applied = store.migrate()
    print("数据库：%s（schema 版本 %d%s）" % (store.path, store.schema_version(),
                                           "，本次应用 %s" % applied if applied else ""))


def cmd_create_admin(store, args):
    store.migrate()
    admin = store.create_admin(args.username, read_new_password(args), args.role)
    print("已创建管理员 %s（%s）" % (admin["username"], admin["role"]))


def cmd_reset_password(store, args):
    store.migrate()
    store.set_admin_password(args.username, read_new_password(args))
    print("密码已更新，该管理员原有会话已全部失效")


def cmd_create_gateway(store, args):
    store.migrate()
    view, credential = store.create_gateway(args.id, args.name or "")
    deliver_secret(args.credential_out, credential, "网关 %s 的凭据" % view["gateway_id"])


def cmd_rotate_gateway(store, args):
    store.migrate()
    view, credential = store.rotate_gateway_credential(args.id)
    deliver_secret(args.credential_out, credential, "网关 %s 的新凭据" % view["gateway_id"])
    print("旧凭据已立即失效，请更新网关的 HEAR_GATEWAY_CREDENTIAL_FILE 并重启网关")


def cmd_list_gateways(store, args):
    store.migrate()
    for gateway in store.list_gateways()["items"]:
        print("%-24s 修订号 %-6d 清单请求 %-8d 最近 %s  %s" % (
            gateway["gateway_id"], gateway["revision"], gateway["snapshot_requests"],
            gateway["last_snapshot_at"] or "-", gateway["name"]))


def cmd_backup(store, args):
    store.migrate()
    target = args.out or os.path.join(os.path.dirname(store.path),
                                      "hear-tokens-%s.db" % time.strftime("%Y%m%d-%H%M%S"))
    store.backup(target)
    print("已备份到 %s" % target)


def cmd_seed_test_data(store, args):
    """生成验收用的测试用户和 5 种状态的 Token。Token 原文写入一个新文件。"""
    store.migrate()
    from hear_auth import format_time
    actor = {"type": "cli", "id": "cli-seed", "username": "seed-test-data"}
    if not store.conn().execute("SELECT 1 FROM gateways WHERE gateway_id = ?", (args.gateway,)).fetchone():
        raise SystemExit("网关 %s 不存在，请先 create-gateway" % args.gateway)
    suffix = secrets.token_hex(3)
    user = store.create_user({"username": "test-%s" % suffix, "display_name": "验收测试用户 %s" % suffix,
                              "notes": "seed-test-data 生成，验收后删除"}, actor)
    now = store.now()
    hour, day = 3600 * 1000000, 86400 * 1000000
    plans = [
        ("active", now - hour, now + 30 * day, False),
        ("scheduled", now + day, now + 31 * day, False),
        ("short-lived-2min", now - hour, now + 120 * 1000000, False),
        ("expired", now - 3 * day, now - day, True),
        ("revoked", now - hour, now + 30 * day, False),
    ]
    tokens = {}
    for label, starts, expires, past in plans:
        issued = store.issue_token(user["user_id"], {"label": label, "gateway_id": args.gateway,
                                                     "starts_at": format_time(starts),
                                                     "expires_at": format_time(expires)},
                                   actor, _allow_past=past)
        tokens[label] = {"token_id": issued["token_id"], "token": issued["token"]}
        if label == "revoked":
            store.revoke_token(issued["token_id"], "seed-test-data", actor)
    payload = json.dumps({"user_id": user["user_id"], "gateway_id": args.gateway, "tokens": tokens},
                         ensure_ascii=False, indent=2)
    write_secret_file(args.out, payload)
    print("测试用户 %s（%s）和 5 个 Token 已生成；原文只写入 %s，验收后请删除该文件"
          % (user["username"], user["user_id"], args.out))


def cmd_gen_cert(store, args):
    """给管理服务生成自签证书（需要 cryptography）。网关用 HEAR_AUTH_CA_FILE 信任它。"""
    try:
        import datetime
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
    except ImportError:
        raise SystemExit("需要 cryptography：python -m pip install cryptography")
    key = ec.generate_private_key(ec.SECP256R1())
    names = []
    for host in args.host or ["127.0.0.1", "localhost"]:
        try:
            names.append(x509.IPAddress(ipaddress.ip_address(host)))
        except ValueError:
            names.append(x509.DNSName(host))
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Hear Token Service")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(minutes=5))
            .not_valid_after(now + datetime.timedelta(days=825))
            .add_extension(x509.SubjectAlternativeName(names), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .sign(key, hashes.SHA256()))
    for path in (args.cert, args.key):
        if os.path.exists(path):
            raise SystemExit("%s 已存在，不覆盖" % path)
    with open(args.cert, "wb") as file:
        file.write(cert.public_bytes(serialization.Encoding.PEM))
    write_secret_file(args.key, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                  serialization.NoEncryption()).decode().strip())
    print("证书：%s  私钥：%s  主机：%s" % (args.cert, args.key, ", ".join(args.host or ["127.0.0.1", "localhost"])))


def cmd_serve(store, args):
    store.migrate()
    store.bump_all()
    context = None
    if args.tls_cert or args.tls_key:
        if not (args.tls_cert and args.tls_key):
            raise SystemExit("--tls-cert 和 --tls-key 需要一起给")
        context = make_tls_context(args.tls_cert, args.tls_key)
    elif not is_loopback(args.host) and not args.allow_plain_http:
        raise SystemExit("监听非本机地址时必须启用 HTTPS（--tls-cert/--tls-key）。"
                         "如果前面有可信 HTTPS 反向代理，加 --allow-plain-http 并只让代理访问本端口")
    origins = [item.strip() for item in (args.allowed_origin or []) if item.strip()]
    server = TokenServer((args.host, args.port), store, context, secure_cookie=args.secure_cookie,
                         allowed_origins=origins)
    scheme = "https" if context else "http"
    if store.conn().execute("SELECT COUNT(*) FROM admins").fetchone()[0] == 0:
        log("还没有管理员：先运行 python hear_token_service.py create-admin --username admin")
    log("Token 管理服务已启动：%s://%s:%d/admin/  数据库 %s" % (scheme, args.host, args.port, store.path))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("已停止")
    finally:
        server.server_close()


def build_parser():
    parser = argparse.ArgumentParser(description="听见 Token 管理服务")
    parser.add_argument("--db", default=DEFAULT_DB, help="SQLite 数据库路径（默认 %(default)s，或 HEAR_TOKEN_DB）")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init", help="创建或迁移数据库").set_defaults(func=cmd_init)
    for name, func, text in (("create-admin", cmd_create_admin, "创建管理员"),
                             ("reset-password", cmd_reset_password, "重置管理员密码")):
        item = sub.add_parser(name, help=text)
        item.add_argument("--username", required=True)
        item.add_argument("--password-stdin", action="store_true", help="从标准输入读一行密码（自动化用）")
        if name == "create-admin":
            item.add_argument("--role", choices=("admin", "viewer"), default="admin")
        item.set_defaults(func=func)
    for name, func, text in (("create-gateway", cmd_create_gateway, "登记网关并生成凭据"),
                             ("rotate-gateway-credential", cmd_rotate_gateway, "轮换网关凭据")):
        item = sub.add_parser(name, help=text)
        item.add_argument("--id", required=True)
        if name == "create-gateway":
            item.add_argument("--name", default="")
        item.add_argument("--credential-out", help="把凭据写进这个新文件（推荐），不写则打印一次")
        item.set_defaults(func=func)
    sub.add_parser("list-gateways", help="列出网关、修订号和清单请求计数").set_defaults(func=cmd_list_gateways)
    item = sub.add_parser("backup", help="在线备份数据库")
    item.add_argument("--out")
    item.set_defaults(func=cmd_backup)
    item = sub.add_parser("seed-test-data", help="生成验收测试用户和 Token")
    item.add_argument("--gateway", required=True)
    item.add_argument("--out", required=True, help="Token 原文写入的新文件")
    item.set_defaults(func=cmd_seed_test_data)
    item = sub.add_parser("gen-cert", help="生成管理服务自签证书")
    item.add_argument("--cert", required=True)
    item.add_argument("--key", required=True)
    item.add_argument("--host", action="append", help="证书里的主机名或 IP，可重复")
    item.set_defaults(func=cmd_gen_cert)
    item = sub.add_parser("serve", help="启动管理服务")
    item.add_argument("--host", default=os.environ.get("HEAR_TOKEN_SERVICE_HOST", "127.0.0.1"))
    item.add_argument("--port", type=int, default=int(os.environ.get("HEAR_TOKEN_SERVICE_PORT", "8443")))
    item.add_argument("--tls-cert", default=os.environ.get("HEAR_TOKEN_SERVICE_CERT"))
    item.add_argument("--tls-key", default=os.environ.get("HEAR_TOKEN_SERVICE_KEY"))
    item.add_argument("--allow-plain-http", action="store_true")
    item.add_argument("--secure-cookie", action="store_true", help="TLS 由反向代理终止时仍给 Cookie 加 Secure")
    item.add_argument("--allowed-origin", action="append", help="反向代理对外的 Origin，例如 https://admin.example.com")
    item.set_defaults(func=cmd_serve)
    return parser


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    args = build_parser().parse_args(argv)
    store = Store(args.db)
    try:
        args.func(store, args)
    except StoreError as error:
        raise SystemExit("%s：%s" % (error.code, error.message))
    except FileExistsError as error:
        raise SystemExit("文件已存在，不覆盖：%s" % error)
    return 0


if __name__ == "__main__":
    sys.exit(main())
