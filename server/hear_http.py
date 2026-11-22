"""HTTP request routing and admission for the Hear inference gateway."""
from contextlib import contextmanager
from hmac import compare_digest
from http.client import HTTPConnection, HTTPSConnection, HTTPException
from http.server import BaseHTTPRequestHandler
import re
import secrets
import socket
import ssl
import threading
import time
import traceback
import urllib.error
from urllib.parse import urlsplit

from hear_auth import AuthResult

LEGACY_DENIED = "访问口令不对，或请求未使用允许的连接方式"
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
ERROR_CODES = {
    400: "BAD_REQUEST", 401: "UNAUTHORIZED", 403: "FORBIDDEN", 404: "NOT_FOUND",
    408: "REQUEST_TIMEOUT", 413: "PAYLOAD_TOO_LARGE", 500: "INTERNAL_ERROR",
    502: "BAD_GATEWAY", 503: "SERVICE_BUSY", 504: "GATEWAY_TIMEOUT",
}


def clone_upstream(url, payload, deadline, max_bytes):
    """Bound the complete upstream response, including a backend trickling data."""
    target = urlsplit(url)
    if target.scheme not in ("http", "https") or target.hostname is None:
        raise ValueError("invalid clone backend URL")
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("clone deadline elapsed")
    factory = HTTPSConnection if target.scheme == "https" else HTTPConnection
    conn = factory(target.hostname, target.port, timeout=min(5, remaining))
    timer = None
    expired = threading.Event()
    try:
        conn.connect()
        sock = conn.sock
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("clone deadline elapsed")
        sock.settimeout(remaining)

        def stop_waiting():
            expired.set()
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        timer = threading.Timer(remaining, stop_waiting)
        timer.daemon = True
        timer.start()
        path = target.path or "/"
        if target.query:
            path += "?" + target.query
        conn.request("POST", path, body=payload, headers={"Content-Type": "application/json"})
        with conn.getresponse() as response:
            data = response.read(max_bytes + 1)
            if expired.is_set() or time.monotonic() >= deadline:
                raise TimeoutError("clone deadline elapsed")
            if not 200 <= response.status < 300:
                raise urllib.error.HTTPError(url, response.status, response.reason, response.headers, None)
            if len(data) > max_bytes:
                raise urllib.error.URLError("clone audio exceeds size limit")
            if response.length not in (None, 0):
                raise urllib.error.URLError("incomplete clone response")
            return data
    except TimeoutError:
        raise
    except (HTTPException, OSError) as error:
        if isinstance(error, urllib.error.URLError):
            raise
        if expired.is_set() or time.monotonic() >= deadline:
            raise TimeoutError("clone deadline elapsed") from error
        raise urllib.error.URLError(error) from error
    finally:
        if timer is not None:
            timer.cancel()
        conn.close()


class RequestPolicy:
    def __init__(self, max_body, max_inflight, access_token=None, *, allow_loopback_http=False,
                 authenticator=None):
        self.max_body = max_body
        self.access_token = access_token
        self.allow_loopback_http = allow_loopback_http
        # 管理模式：只认 Token 管理服务签发的口令，旧的共享口令不作为后备
        self.authenticator = authenticator
        self.max_inflight = max_inflight
        self.lock = threading.Lock()
        self.inflight = 0
        self.background_inflight = 0
        self.previews = set()

    @property
    def auth_mode(self):
        if self.authenticator is not None:
            return "managed"
        return "legacy" if self.access_token is not None else "off"

    def authorize(self, connection, peer_host, token):
        """推理接口和 /v1/auth/check 共用的鉴权。只看内存，不访问数据库或管理服务。"""
        # Use the real TCP peer. Forwarded headers cannot authorize plaintext.
        local_proxy = self.allow_loopback_http and peer_host in ("127.0.0.1", "::1")
        secure = isinstance(connection, ssl.SSLSocket) or local_proxy
        if self.authenticator is not None:
            if not secure:
                return AuthResult.deny("HTTPS_REQUIRED", 403)
            return self.authenticator.verify(token)
        if self.access_token is None:
            return AuthResult.allow()
        if not secure:
            return AuthResult.deny("HTTPS_REQUIRED", 401, message=LEGACY_DENIED)
        if not token:
            return AuthResult.deny("TOKEN_REQUIRED", 401, message=LEGACY_DENIED)
        if compare_digest(token.encode("utf-8"), self.access_token.encode("utf-8")):
            return AuthResult.allow()
        return AuthResult.deny("TOKEN_INVALID", 401, message=LEGACY_DENIED)

    def permits(self, connection, peer_host, token):
        return self.authorize(connection, peer_host, token).ok

    @contextmanager
    def reserve(self, *, background=False, preview=None):
        with self.lock:
            full = self.max_inflight > 0 and self.inflight >= self.max_inflight
            # Keep one slot free of background work even when a cancelled request
            # is still running on the model. A single-slot installation stays usable.
            background_full = (background and self.max_inflight > 1
                               and self.background_inflight >= self.max_inflight - 1)
            acquired = not (full or background_full or preview in self.previews)
            if acquired:
                self.inflight += 1
                self.background_inflight += int(background)
                if preview is not None:
                    self.previews.add(preview)
        try:
            yield acquired
        finally:
            if acquired:
                with self.lock:
                    self.inflight -= 1
                    self.background_inflight -= int(background)
                    if preview is not None:
                        self.previews.remove(preview)


class RequestHandler(BaseHTTPRequestHandler):
    def handle_one_request(self):
        self._request_id = None
        # Check the buffered reader so a reused TLS connection can go idle
        # without being reported as a failed request.
        try:
            has_request = bool(self.rfile.peek(1))
        except (TimeoutError, ConnectionError, ssl.SSLEOFError):
            has_request = False
        if not has_request:
            self.close_connection = True
            return
        super().handle_one_request()

    @property
    def request_id(self):
        if getattr(self, "_request_id", None) is None:
            headers = getattr(self, "headers", None)
            incoming = ((headers.get("X-Request-Id") if headers is not None else "") or "").strip()
            self._request_id = incoming if REQUEST_ID_RE.match(incoming) else "req_" + secrets.token_hex(8)
        return self._request_id

    def log_error(self, fmt, *args):
        if fmt == "Request timed out: %r" and args and isinstance(args[0], TimeoutError):
            self.log_notice("HTTP 请求行、请求头或响应传输超时，已关闭连接")
            return
        super().log_error(fmt, *args)

    def log_notice(self, message):
        self.log_message("%s", message)

    def do_GET(self):
        route = urlsplit(self.path).path
        try:
            if route == "/health":
                self._send_json(self.health())
            elif route == "/v1/pair":
                self._send_json(self.pairing_info())
            elif route == "/ping":
                self._send_json({"pong": True, "time": time.time()})
            elif route == "/v1/auth/check":
                self.auth_check()
            elif route.startswith("/v1/"):
                self._error("没有这个接口", 404)
            else:
                self._send_html(self.test_page())
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _auth_denied(self, result, route):
        body = {"code": result.code, "message": result.message, "error": result.message,
                "request_id": self.request_id}
        for key in ("status", "starts_at", "expires_at", "effective_expires_at", "invalidated_at", "server_time"):
            if key in result.details:
                body[key] = result.details[key]
        # 不记录口令本身，只记录结果和请求 ID
        self.log_notice("口令校验未通过（%s，%s，request_id=%s）" % (route, result.code, self.request_id))
        self._send_json(body, result.http_status)

    def auth_check(self):
        """用网关内存里的清单检查一串口令，不调用模型，也不访问管理服务。"""
        policy = self.server.request_policy
        if policy.authenticator is None:
            self._error("目标服务未接入托管鉴权", 404, "AUTH_NOT_MANAGED")
            return
        result = policy.authorize(self.connection, self.client_address[0],
                                  (self.headers.get("X-Hear-Token") or "").strip())
        if result.ok:
            self._send_json(dict(result.details))
        else:
            self._auth_denied(result, "/v1/auth/check")

    def _reject_without_reading(self, message, code):
        # The request body is unread. Do not reuse the connection for another request.
        self.close_connection = True
        self._error(message, code)

    def _read_body(self, route, length):
        try:
            body = self.rfile.read(length)
        except TimeoutError:
            self.log_notice("客户端上传请求体超时（%s）" % route)
            self._reject_without_reading("上传请求体超时", 408)
            return None
        if len(body) != length:
            self._reject_without_reading("请求体未传输完整", 400)
            return None
        return body

    def _backend_timeout(self, route):
        self.log_notice("等待推理后端响应超时（%s）" % route)
        self._error("推理后端响应超时", 504)

    def do_POST(self):
        route = urlsplit(self.path).path
        handlers = {
            "/v1/asr": self.asr,
            "/v1/speaker": self.speaker,
            "/v1/translate": self.translate,
            "/v1/clone/reference": self.clone_reference,
            "/v1/clone": self.clone,
        }
        handler = handlers.get(route)
        if handler is None:
            self._reject_without_reading("没有这个接口", 404)
            return

        policy = self.server.request_policy
        token = (self.headers.get("X-Hear-Token") or "").strip()
        auth = policy.authorize(self.connection, self.client_address[0], token)
        if not auth.ok:
            # The request body is unread. Do not reuse the connection for another request.
            self.close_connection = True
            self._auth_denied(auth, route)
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or self.headers.get("Transfer-Encoding"):
            self._reject_without_reading("无效的请求体长度或编码", 400)
            return
        max_body = min(policy.max_body, 512 * 1024) if route == "/v1/speaker" else policy.max_body
        if length > max_body:
            self._reject_without_reading("请求体超过服务上限", 413)
            return

        is_asr_preview = route == "/v1/asr" and self.headers.get("X-ASR-Preview", "").strip() == "1"
        is_mt_preview = route == "/v1/translate" and self.headers.get("X-MT-Preview", "").strip() == "1"
        preview = route if is_asr_preview or is_mt_preview else None
        correction = route == "/v1/asr" and self.headers.get("X-ASR-Stage", "").strip() == "correct"
        revision = route == "/v1/translate" and self.headers.get("X-MT-Stage", "").strip() == "revision"
        background = preview is not None or correction or revision or route not in ("/v1/asr", "/v1/translate")
        # One in-flight clone per gateway, independent of the live ASR/MT preview lanes.
        exclusive = route if route == "/v1/clone" else preview
        with policy.reserve(background=background, preview=exclusive) as admitted:
            if not admitted:
                self._reject_without_reading("推理服务正忙，请稍后重试", 503)
                return
            try:
                body = self._read_body(route, length)
                if body is not None:
                    handler(body)
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True
            except TimeoutError:
                self._backend_timeout(route)
            except urllib.error.HTTPError as error:
                detail = error.read(500).decode("utf-8", "replace") if error.fp else ""
                self._error("后端返回 %s：%s" % (error.code, detail), 502)
            except urllib.error.URLError as error:
                if isinstance(error.reason, TimeoutError):
                    self._backend_timeout(route)
                else:
                    self.log_notice("连接推理后端失败（%s，%s）" % (route, type(error.reason).__name__))
                    self._error("推理后端无法连接", 502)
            except Exception:
                traceback.print_exc()
                self._error("推理请求处理失败，请查看服务端日志", 500)
