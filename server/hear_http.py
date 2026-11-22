"""HTTP request routing and admission for the Hear inference gateway."""
from contextlib import contextmanager
from hmac import compare_digest
from http.server import BaseHTTPRequestHandler
import ssl
import threading
import time
import traceback
import urllib.error
from urllib.parse import urlsplit


class RequestPolicy:
    def __init__(self, max_body, max_inflight, access_token=None):
        self.max_body = max_body
        self.access_token = access_token
        self.max_inflight = max_inflight
        self.lock = threading.Lock()
        self.inflight = 0
        self.background_inflight = 0
        self.previews = set()

    def permits(self, connection, token):
        if self.access_token is None:
            return True
        return (isinstance(connection, ssl.SSLSocket)
                and compare_digest(token.encode("utf-8"), self.access_token.encode("utf-8")))

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
    def do_GET(self):
        route = urlsplit(self.path).path
        try:
            if route == "/health":
                self._send_json(self.health())
            elif route == "/v1/pair":
                self._send_json(self.pairing_info())
            elif route == "/ping":
                self._send_json({"pong": True, "time": time.time()})
            elif route.startswith("/v1/"):
                self._error("没有这个接口", 404)
            else:
                self._send_html(self.test_page())
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _reject_without_reading(self, message, code):
        # The request body is unread. Do not reuse the connection for another request.
        self.close_connection = True
        self._error(message, code)

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
        if not policy.permits(self.connection, (self.headers.get("X-Hear-Token") or "").strip()):
            self._reject_without_reading("访问口令不对，或请求未使用 HTTPS", 401)
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
        with policy.reserve(background=background, preview=preview) as admitted:
            if not admitted:
                self._reject_without_reading("推理服务正忙，请稍后重试", 503)
                return
            try:
                body = self.rfile.read(length)
                if len(body) != length:
                    self._reject_without_reading("请求体未传输完整", 400)
                    return
                handler(body)
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True
            except TimeoutError:
                self._reject_without_reading("请求读取超时", 408)
            except urllib.error.HTTPError as error:
                detail = error.read().decode("utf-8", "replace")[:500]
                self._error("后端返回 %s：%s" % (error.code, detail), 502)
            except Exception:
                traceback.print_exc()
                self._error("推理请求处理失败，请查看服务端日志", 500)
