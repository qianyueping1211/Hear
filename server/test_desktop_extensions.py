#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Desktop v2.0 服务端兼容性与安全/并发增强回归测试。"""

import http.client
import io
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import hear_auth
import hear_cloud
import hear_http
import hear_token_service
import hear_token_store

passed = 0
failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print("  ok %s" % name)
    else:
        failed += 1
        print("  FAIL %s%s" % (name, (" -> " + str(detail)) if detail else ""))


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def make_pcm_wav(samples_int, sampwidth, rate=16000, channels=1):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(sampwidth)
        w.setframerate(rate)
        fmt = "<h" if sampwidth == 2 else "<i"
        w.writeframes(b"".join(struct.pack(fmt, v) for v in samples_int))
    return buf.getvalue()


def test_decode_wav_16_and_32():
    print("== decode_wav 16-bit & 32-bit PCM ==")
    wav16 = make_pcm_wav([0, 16384, -16384, 32767], 2)
    arr16, rate16 = hear_cloud.decode_wav(wav16)
    check("16-bit wav sample rate", rate16 == 16000)
    check("16-bit wav values accurate", abs(float(arr16[1]) - 0.5) < 1e-4 and abs(float(arr16[2]) + 0.5) < 1e-4)

    wav32 = make_pcm_wav([0, 1073741824, -1073741824], 4)
    arr32, rate32 = hear_cloud.decode_wav(wav32)
    check("32-bit int32 PCM decoded cleanly (not float32 garbage)",
          rate32 == 16000 and abs(float(arr32[1]) - 0.5) < 1e-4 and abs(float(arr32[2]) + 0.5) < 1e-4,
          list(arr32[:3]))


def test_auth_http_exception_survival():
    print("== hear_auth HTTPException survival ==")

    class FlakyOpener:
        def open(self, request, timeout=None):
            raise http.client.IncompleteRead(b"partial")

    auth = hear_auth.ManagedAuthenticator(
        "https://127.0.0.1:8443", "gw-1", "cred-123", opener=FlakyOpener()
    )
    ok = auth.sync_once()
    check("sync_once catches http.client.IncompleteRead without crashing", ok is False)
    check("sync_once records failure reason", "IncompleteRead" in (auth._last_error or "") or "partial" in (auth._last_error or ""))


def test_login_throttle_and_negative_content_length():
    print("== token service LoginThrottle & negative Content-Length ==")
    now = [1000.0]
    throttle = hear_token_service.LoginThrottle(limit=5, window=900.0, lock=900.0, clock=lambda: now[0])
    for _ in range(5):
        throttle.fail(("127.0.0.1", "admin"))
    check("admin locked after 5 failures", throttle.blocked(("127.0.0.1", "admin")))
    for i in range(10010):
        throttle.fail(("127.0.0.1", "dummy_%d" % i))
    check("active admin lock survives 10010 dummy floods", throttle.blocked(("127.0.0.1", "admin")))

    check("_DUMMY_HASH uses full PASSWORD_ITERATIONS",
          hear_token_store._DUMMY_HASH.startswith("pbkdf2_sha256$%d$" % hear_token_store.PASSWORD_ITERATIONS))

    with tempfile.TemporaryDirectory(prefix="hear-desk-ts-", ignore_cleanup_errors=True) as tmp:
        store = hear_token_store.Store(os.path.join(tmp, "tokens.db"))
        store.migrate()
        port = free_port()
        srv = hear_token_service.TokenServer(
            ("127.0.0.1", port), store, ssl_context=None, secure_cookie=False,
        )
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                raw_req = (
                    b"POST /admin/api/v1/session HTTP/1.1\r\n"
                    b"Host: 127.0.0.1\r\n"
                    b"Content-Type: application/json\r\n"
                    b"Content-Length: -1\r\n"
                    b"Connection: close\r\n\r\n"
                )
                sock.sendall(raw_req)
                resp = sock.recv(4096).decode("utf-8", "replace")
            check("negative Content-Length rejected with 400", resp.startswith("HTTP/1.1 400"), resp.splitlines()[0] if resp else "")
        finally:
            srv.shutdown()
            srv.server_close()
            try:
                store.conn().close()
            except Exception:
                pass


def test_local_secret_and_per_device_preview_and_sse():
    print("== local_secret, per-device preview isolation, and SSE streaming ==")

    # 1. Policy unit check: local_secret allows loopback with secret, blocks missing secret
    policy = hear_http.RequestPolicy(1024 * 1024, 3, access_token=None, local_secret="desk-secret-xyz")
    check("local_secret denies missing secret on loopback",
          not policy.authorize(None, "127.0.0.1", "", local_secret="").ok)
    check("local_secret denies wrong secret on loopback",
          not policy.authorize(None, "127.0.0.1", "", local_secret="wrong").ok)
    check("local_secret denies valid secret from non-loopback peer",
          not policy.authorize(None, "192.168.1.50", "", local_secret="desk-secret-xyz").ok)
    check("local_secret admits valid secret on 127.0.0.1",
          policy.authorize(None, "127.0.0.1", "", local_secret="desk-secret-xyz").ok)

    # 2. Stub llama-server supporting both JSON and SSE streaming
    mt_port = free_port()

    class StubMT(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def do_GET(self):
            if self.path == "/health":
                body = b'{"status":"ok"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/props":
                body = b'{"model_path":"Hy-MT2-1.8B-Q4_K_M.gguf"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(length).decode("utf-8"))
            if req.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                for piece in ("你好", "，", "世界"):
                    chunk = {"choices": [{"delta": {"content": piece}}]}
                    self.wfile.write(("data: %s\n\n" % json.dumps(chunk, ensure_ascii=False)).encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(0.02)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            else:
                time.sleep(0.15)
                body = json.dumps({"choices": [{"message": {"content": "Hello translated"}}]}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

    mt_srv = ThreadingHTTPServer(("127.0.0.1", mt_port), StubMT)
    threading.Thread(target=mt_srv.serve_forever, daemon=True).start()

    # 3. Start hear_cloud MixedServer in local-only mode with local_secret
    gw_port = free_port()
    old_mt = hear_cloud.MT_URL
    old_host = hear_cloud.HOST
    old_secret = hear_cloud.LOCAL_SECRET
    hear_cloud.MT_URL = "http://127.0.0.1:%d" % mt_port
    hear_cloud.HOST = "127.0.0.1"
    hear_cloud.LOCAL_SECRET = "desk-secret-xyz"
    hear_cloud._backend_cache.clear()
    hear_cloud._backend_model_cache.clear()

    gw_srv = hear_cloud.MixedServer(("127.0.0.1", gw_port), hear_cloud.Handler, None)
    gw_srv.request_policy = hear_http.RequestPolicy(
        hear_cloud.MAX_BODY, 4, None, local_secret="desk-secret-xyz"
    )
    threading.Thread(target=gw_srv.serve_forever, daemon=True).start()

    try:
        # /health reports bind_host, lan_shared=False, capabilities
        with hear_cloud._DIRECT_OPENER.open("http://127.0.0.1:%d/health" % gw_port, timeout=5) as r:
            health = json.loads(r.read().decode("utf-8"))
        check("/health reports bind_host=127.0.0.1 and lan_shared=False",
              health.get("bind_host") == "127.0.0.1" and health.get("lan_shared") is False, health)
        check("/health reports streaming_mt and per_device_preview capabilities",
              health.get("capabilities", {}).get("streaming_mt") is True
              and health.get("capabilities", {}).get("per_device_preview") is True, health)

        # Invalid JSON returns 400 (not 500)
        req_bad = urllib.request.Request(
            "http://127.0.0.1:%d/v1/translate" % gw_port,
            data=b"{broken",
            headers={"Content-Type": "application/json", "X-Hear-Local-Secret": "desk-secret-xyz"},
        )
        try:
            hear_cloud._DIRECT_OPENER.open(req_bad, timeout=5)
            check("invalid JSON on /v1/translate returns 400", False, "unexpected 200")
        except urllib.error.HTTPError as e:
            check("invalid JSON on /v1/translate returns 400", e.code == 400, e.code)

        # Streaming SSE translate
        req_sse = urllib.request.Request(
            "http://127.0.0.1:%d/v1/translate" % gw_port,
            data=json.dumps({"prompt": "Hello world", "stream": True}).encode("utf-8"),
            headers={"Content-Type": "application/json", "X-Hear-Local-Secret": "desk-secret-xyz"},
        )
        with hear_cloud._DIRECT_OPENER.open(req_sse, timeout=10) as r:
            ctype = r.headers.get("Content-Type", "")
            raw_sse = r.read().decode("utf-8")
        events = [json.loads(line[5:].strip()) for line in raw_sse.splitlines() if line.startswith("data:")]
        deltas = "".join(ev.get("delta", "") for ev in events if not ev.get("done"))
        final_ev = [ev for ev in events if ev.get("done")]
        check("SSE /v1/translate streams deltas and final text",
              "text/event-stream" in ctype and deltas == "你好，世界" and final_ev and final_ev[-1].get("text") == "你好，世界",
              (ctype, events))

        # Per-device preview isolation: two distinct X-Hear-Device-Id succeed concurrently
        results = {}

        def call_preview(dev_id):
            req = urllib.request.Request(
                "http://127.0.0.1:%d/v1/translate" % gw_port,
                data=json.dumps({"prompt": "Hi"}).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "X-Hear-Local-Secret": "desk-secret-xyz",
                    "X-MT-Preview": "1",
                    "X-Hear-Device-Id": dev_id,
                },
            )
            try:
                with hear_cloud._DIRECT_OPENER.open(req, timeout=5) as r:
                    results[dev_id] = r.status
            except urllib.error.HTTPError as e:
                results[dev_id] = e.code

        t1 = threading.Thread(target=call_preview, args=("win-desktop-1",))
        t2 = threading.Thread(target=call_preview, args=("iphone-1",))
        t1.start()
        t2.start()
        t1.join(5)
        t2.join(5)
        check("distinct X-Hear-Device-Id previews run concurrently without 503",
              results.get("win-desktop-1") == 200 and results.get("iphone-1") == 200, results)
    finally:
        gw_srv.shutdown()
        gw_srv.server_close()
        mt_srv.shutdown()
        mt_srv.server_close()
        hear_cloud.MT_URL = old_mt
        hear_cloud.HOST = old_host
        hear_cloud.LOCAL_SECRET = old_secret


def main():
    test_decode_wav_16_and_32()
    test_auth_http_exception_survival()
    test_login_throttle_and_negative_content_length()
    test_local_secret_and_per_device_preview_and_sse()
    print("\npassed %d, failed %d" % (passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
