# -*- coding: utf-8 -*-
"""云端服务的"接口契约"自测。

测的是"约定"，不是模型效果：
合法的 WAV 必须能拿到 200 + text + lang（用替身识别，不装模型也能测），
格式不对的必须给约定的错误码，边界情况不能把服务搞崩。

    python3 server/test_contract.py
"""
import io
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.client import HTTPConnection
from types import SimpleNamespace
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("HEAR_CONTRACT_PORT", "8199"))
STUB_PORT = PORT + 1
BASE = "https://127.0.0.1:%d" % PORT

FAILED = []
PASSED = []


def check(name, ok, detail=""):
    if ok:
        PASSED.append(name)
        print("  ok %s" % name)
    else:
        FAILED.append(name)
        print("  FAIL %s %s" % (name, detail))


def ctx():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def req(path, method="GET", body=None, ctype="application/json", headers=None, timeout=20):
    r = urllib.request.Request(BASE + path, data=body, method=method)
    r.add_header("Content-Type", ctype)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=ctx()) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode("utf-8")


def make_wav(seconds=1.0, rate=16000):
    n = int(seconds * rate)
    raw = struct.pack("<%dh" % n, *([1200] * n))
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(raw)
    return buf.getvalue()


class StubASR(BaseHTTPRequestHandler):
    """替身识别服务：假装自己会识别（这样 CI 里不用装模型也能测）"""

    def log_message(self, *a):
        pass

    def do_GET(self):
        body = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        body = json.dumps({"text": "这是替身识别出来的文字", "language": "zh"}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start_service(tmp, port, asr_url="", require_token=False):
    env = dict(os.environ)
    env["HEAR_PORT"] = str(port)
    env["HEAR_TLS_CERT"] = os.path.join(tmp, "cert.pem")
    env["HEAR_TLS_KEY"] = os.path.join(tmp, "key.pem")
    env["HEAR_ROOT_CERT"] = os.path.join(tmp, "root.pem")
    env["HEAR_ROOT_KEY"] = os.path.join(tmp, "root.key")
    env["HEAR_SENSEVOICE_DIR"] = os.path.join(tmp, "sensevoice")
    env["HEAR_TOKEN_FILE"] = os.path.join(tmp, "access-token.txt")
    env["PYTHONUTF8"] = "1"
    if asr_url:
        env["HEAR_ASR_URL"] = asr_url
    else:
        env.pop("HEAR_ASR_URL", None)
    if require_token:
        env["HEAR_REQUIRE_TOKEN"] = "1"
    else:
        env.pop("HEAR_REQUIRE_TOKEN", None)
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "hear_cloud.py")],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for _ in range(60):
        code, _ = req("/health", timeout=3) if port == PORT else (0, b"")
        if port == PORT:
            if code == 200:
                return proc
        else:
            # 换个端口就换个 BASE：直接看进程活没活
            if proc.poll() is None:
                time.sleep(0.5)
                if proc.poll() is None:
                    return proc
        time.sleep(0.5)
    return proc


def stop_service(proc):
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass



def check_hybrid_asr(wav):
    import hear_cloud

    calls = []
    replies = []

    def whisper(*args):
        calls.append(args)
        return "corrected", "en"

    request = SimpleNamespace(
        headers={"X-ASR-Scheme": "sensevoice+whisper", "X-ASR-Stage": "first",
                 "X-Fallback-Language": "en"},
        _send_json=replies.append,
    )
    with patch.multiple(hear_cloud, ASR_URL="", whisper_transcribe=whisper,
                        sensevoice_transcribe=lambda *args: ("en", "first")):
        hear_cloud.Handler.asr(request, wav)
        check("staged hybrid ASR delivers SenseVoice before invoking Whisper",
              replies[-1]["text"] == "first" and replies[-1]["can_correct"] and not calls)
        request.headers["X-ASR-Stage"] = "correct"
        hear_cloud.Handler.asr(request, wav)
        check("deferred Whisper sends the corrected result",
              replies[-1]["text"] == "corrected" and not replies[-1]["can_correct"] and len(calls) == 1)

    unblock = threading.Event()
    finished = threading.Event()

    def blocked():
        try:
            unblock.wait(2)
        finally:
            finished.set()

    try:
        try:
            hear_cloud.run_with_timeout(blocked, 0.01)
        except TimeoutError:
            pass
        try:
            hear_cloud.run_with_timeout(lambda: "unexpected", 0.1)
        except TimeoutError:
            check("timed-out correction keeps the single worker slot", True)
        else:
            check("timed-out correction keeps the single worker slot", False)
    finally:
        unblock.set()
        finished.wait(2)


def check_speaker_endpoint(wav):
    import hear_cloud
    replies = []
    errors = []
    request = SimpleNamespace(_send_json=replies.append, _error=lambda message, code: errors.append(code))
    with patch.object(hear_cloud.SPEAKER, "embedding", return_value=[0.25, -0.5]) as detector:
        hear_cloud.Handler.speaker(request, wav)
        check("speaker endpoint decodes PCM and returns a vector", replies == [{"embedding": [0.25, -0.5]}])
        check("speaker endpoint supplies the WAV sample rate", detector.call_args.args[1] == 16000)
        hear_cloud.Handler.speaker(request, b"not a wave")
        check("speaker endpoint rejects malformed audio", errors == [400])


def check_clone_readiness():
    import hear_cloud
    with patch.object(hear_cloud, "backend_state", return_value="就绪"):
        with patch.object(hear_cloud, "backend_model", return_value="Hy-MT2-example.gguf"):
            health = hear_cloud.Handler.health(None)
            check("a translation model is not ready for voice cloning",
                  health["clone_ready"] is False and "模型不匹配" in health["clone"])
        with patch.object(hear_cloud, "backend_model", return_value="Qwen3-TTS-example.gguf"):
            health = hear_cloud.Handler.health(None)
            check("an available Qwen3-TTS backend is ready for voice cloning", health["clone_ready"] is True)


def check_connection_recovery():
    import hear_cloud

    for error in (ssl.SSLError("certificate unknown"), ConnectionResetError()):
        with patch.object(hear_cloud, "log") as log:
            sock = SimpleNamespace(settimeout=lambda _: None, recv=lambda *_: b"\x16",
                                   close=lambda: None)
            server = SimpleNamespace(
                ssl_context=SimpleNamespace(wrap_socket=lambda *args, **kwargs: None),
                _close=hear_cloud.MixedServer._close,
                tls_hint=hear_cloud.MixedServer.tls_hint,
            )
            with patch.object(server.ssl_context, "wrap_socket", side_effect=error), \
                 patch.object(sock, "close") as close:
                result = hear_cloud.MixedServer._wrap_tls(server, sock)
                check("failed TLS handshake closes the socket (%s)" % type(error).__name__,
                      result is None and close.call_count == 1 and log.call_count == 1)

    blocked = threading.Event()
    release = threading.Event()

    def stalled_console(*args, **kwargs):
        blocked.set()
        release.wait(5)

    with patch.object(hear_cloud, "print", stalled_console, create=True), \
         patch.object(hear_cloud, "_console_log", hear_cloud.ConsoleLog()), \
         hear_cloud.MixedServer(("127.0.0.1", 0), hear_cloud.Handler) as server:
        hear_cloud._console_log.start()
        hear_cloud.log("simulate a blocked console")
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        client = HTTPConnection("127.0.0.1", server.server_port, timeout=2)
        try:
            assert blocked.wait(2), "console writer did not reach the test sink"
            client.request("GET", "/ping")
            response = client.getresponse()
            check("HTTP responds while the console logger is blocked",
                  response.status == 200 and json.loads(response.read())["pong"])
        except (OSError, AssertionError, ValueError) as error:
            check("HTTP responds while the console logger is blocked", False, str(error))
        finally:
            client.close()
            release.set()
            server.shutdown()
            worker.join(2)


def check_inference_admission():
    import hear_cloud
    from hear_http import RequestPolicy

    asr_started = threading.Event()
    mt_started = threading.Event()
    release = threading.Event()

    class Handler(hear_cloud.Handler):
        def asr(self, body):
            if self.headers.get("X-ASR-Preview") == "1":
                asr_started.set()
                release.wait(5)
            self._send_json({"text": "asr"})

        def translate(self, body):
            if self.headers.get("X-MT-Preview") == "1":
                mt_started.set()
                release.wait(5)
            self._send_json({"text": "translation"})

    with hear_cloud.MixedServer(("127.0.0.1", 0), Handler) as server:
        server.request_policy = RequestPolicy(max_body=1024, max_inflight=3)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()

        def post(path, headers=None):
            client = HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            try:
                client.request("POST", path, body=b"{}", headers=headers or {})
                response = client.getresponse()
                return response.status, response.getheader("Retry-After"), json.loads(response.read())
            finally:
                client.close()

        asr_preview = ("/v1/asr", {"X-ASR-Preview": "1"})
        mt_preview = ("/v1/translate", {"X-MT-Preview": "1"})
        asr_result = []
        mt_result = []
        asr = threading.Thread(target=lambda: asr_result.append(post(*asr_preview)))
        mt = threading.Thread(target=lambda: mt_result.append(post(*mt_preview)))
        asr.start()
        try:
            assert asr_started.wait(1), "ASR preview did not start"
            check("a second ASR preview is rejected while the first is still working",
                  post(*asr_preview)[:2] == (503, "1"))
            mt.start()
            assert mt_started.wait(1), "MT preview did not start"
            check("Whisper correction cannot take the reserved inference slot",
                  post("/v1/asr", {"X-ASR-Stage": "correct"})[:2] == (503, "1"))
            check("a corrected translation cannot take the reserved inference slot",
                  post("/v1/translate", {"X-MT-Stage": "revision"})[:2] == (503, "1"))
            check("speaker recognition cannot take the reserved inference slot",
                  post("/v1/speaker")[:2] == (503, "1"))
            check("final speech recognition works while both previews are busy",
                  post("/v1/asr", {"X-ASR-Stage": "first"})[0] == 200)
            check("final translation works while both previews are busy",
                  post("/v1/translate")[0] == 200)
        except (OSError, AssertionError, ValueError) as error:
            check("inference admission under load", False, str(error))
        finally:
            release.set()
            asr.join(3)
            if mt.ident is not None:
                mt.join(3)
            try:
                check("preview admission recovers after the original work finishes",
                      bool(asr_result and mt_result) and post(*asr_preview)[0] == 200
                      and post(*mt_preview)[0] == 200)
            finally:
                server.shutdown()
                worker.join(2)

    single = RequestPolicy(max_body=1024, max_inflight=1)
    with single.reserve(background=True, preview="/v1/asr") as preview, single.reserve() as final:
        check("single-slot servers can still run preview work", preview and not final)
    with single.reserve() as final:
        check("single-slot servers admit a final after a preview releases the slot", final)


def main():
    global BASE
    tmp = tempfile.mkdtemp(prefix="hear-contract-")
    wav = make_wav()

    # ============================================================ 第一轮：本机识别（没装模型）
    print("== round 1: service without an external recognizer ==")
    proc = start_service(tmp, PORT)
    try:
        ready = False
        for _ in range(60):
            code, _ = req("/health", timeout=3)
            if code == 200:
                ready = True
                break
            time.sleep(0.5)
        if not ready:
            print("service did not start:")
            try:
                proc.terminate()
                print(proc.stdout.read().decode("utf-8", "replace")[-2000:])
            except Exception:
                pass
            return 1

        print("\n-- /health --")
        code, data = req("/health")
        check("/health returns 200", code == 200, "got %d" % code)
        try:
            h = json.loads(data.decode("utf-8"))
            check("/health has asr/mt/clone", all(k in h for k in ("asr", "mt", "clone")),
                  "got %s" % list(h.keys()))
            check("/health has asr_schemes (App builds the scheme list from it)",
                  "asr_schemes" in h, "(older servers do not have it)")
            check("/health has machine-readable readiness flags",
                  all(k in h for k in ("asr_ready", "mt_ready", "clone_ready")),
                  "got %s" % list(h.keys()))
        except Exception as e:
            check("/health returns JSON", False, str(e))

        print("\n-- /v1/pair --")
        code, data = req("/v1/pair")
        check("/v1/pair returns 200", code == 200, "got %d" % code)
        try:
            p = json.loads(data.decode("utf-8"))
            check("has root_fingerprint", bool(p.get("root_fingerprint")))
            check("has root_der", bool(p.get("root_der")))
        except Exception as e:
            check("/v1/pair returns JSON", False, str(e))

        print("\n-- /v1/asr with a broken body --")
        code, data = req("/v1/asr", method="POST", body=b"this is not a wav file",
                         ctype="audio/wav")
        check("a broken body returns 400 (not a 500)", code == 400, "got %d" % code)

        print("\n-- /v1/clone/reference --")
        code, data = req("/v1/clone/reference", method="POST", body=wav, ctype="audio/wav")
        check("storing a reference returns 200", code == 200, "got %d" % code)
        try:
            j = json.loads(data.decode("utf-8"))
            check("returns a reference id", bool(j.get("id")))
        except Exception as e:
            check("response is JSON", False, str(e))

        print("\n-- limits --")
        try:
            c = ssl.create_default_context()
            c.check_hostname = False
            c.verify_mode = ssl.CERT_NONE
            sk = c.wrap_socket(socket.create_connection(("127.0.0.1", PORT), timeout=10),
                               server_hostname="127.0.0.1")
            sk.sendall(b"POST /v1/translate HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                       b"Content-Type: application/json\r\nContent-Length: 209715200\r\n\r\n")
            resp = sk.recv(200).decode("utf-8", "replace")
            check("oversized body is rejected (413)", "413" in resp, "got: %s" % resp[:60])
            sk.close()
        except Exception as e:
            check("oversized body is rejected (413)", False, str(e))

        code, data = req("/v1/nothing")
        check("unknown GET /v1/... returns 404", code == 404, "got %d" % code)

        code, data = req("/v1/nothing", method="POST", body=b"{}")
        check("unknown POST endpoint returns 404", code == 404, "got %d" % code)

        code, data = req("/")
        check("built-in console (GET /) returns 200", code == 200, "got %d" % code)
    finally:
        stop_service(proc)

    # ============================================================ 第二轮：替身识别
    print("\n== round 2: service with a stub recognizer ==")
    stub = ThreadingHTTPServer(("127.0.0.1", STUB_PORT), StubASR)
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    tmp2 = tempfile.mkdtemp(prefix="hear-contract-stub-")
    proc2 = start_service(tmp2, PORT, asr_url="http://127.0.0.1:%d" % STUB_PORT)
    try:
        ready = False
        for _ in range(60):
            code, _ = req("/health", timeout=3)
            if code == 200:
                ready = True
                break
            time.sleep(0.5)
        if not ready:
            print("service (stub) did not start")
            return 1

        code, data = req("/health")
        try:
            h = json.loads(data.decode("utf-8"))
            check("asr_ready is true (the stub recognizer is up)", h.get("asr_ready") is True,
                  "got %r" % h.get("asr_ready"))
        except Exception as e:
            check("/health returns JSON", False, str(e))

        print("\n-- /v1/asr with a valid wav --")
        code, data = req("/v1/asr", method="POST", body=wav, ctype="audio/wav",
                         headers={"X-Languages": "zh,en"})
        check("a valid wav returns 200", code == 200, "got %d: %s" % (code, data[:120]))
        try:
            j = json.loads(data.decode("utf-8"))
            check("the response has text", isinstance(j.get("text"), str), "got %s" % list(j.keys()))
            check("the response has lang", isinstance(j.get("lang"), str), "got %s" % list(j.keys()))
            check("the text is what the recognizer returned",
                  j.get("text") == "这是替身识别出来的文字", "got %r" % j.get("text"))
        except Exception as e:
            check("the response is JSON", False, str(e))
    finally:
        stop_service(proc2)
        try:
            stub.shutdown()
        except Exception:
            pass
        shutil.rmtree(tmp2, ignore_errors=True)

    # ============================================================ 第三轮：访问口令
    print("\n== round 3: service that requires an access token ==")
    tmp3 = tempfile.mkdtemp(prefix="hear-contract-token-")
    # 第二轮结束时替身已经关掉了，这里再起一个
    stub3_port = STUB_PORT + 1
    stub3 = ThreadingHTTPServer(("127.0.0.1", stub3_port), StubASR)
    threading.Thread(target=stub3.serve_forever, daemon=True).start()
    proc3 = start_service(tmp3, PORT, asr_url="http://127.0.0.1:%d" % stub3_port,
                          require_token=True)
    try:
        ready = False
        for _ in range(60):
            code, _ = req("/health", timeout=3)
            if code == 200:
                ready = True
                break
            time.sleep(0.5)
        if not ready:
            print("service (token) did not start")
            return 1

        code, data = req("/v1/asr", method="POST", body=wav, ctype="audio/wav")
        check("without a token the service refuses (401)", code == 401, "got %d" % code)

        # 口令文件是服务自己生成的：读出来带上再试
        token = ""
        try:
            with open(os.path.join(tmp3, "access-token.txt"), "r", encoding="utf-8") as f:
                token = f.read().strip()
        except Exception:
            pass
        check("the service generated an access token", bool(token))

        code, data = req("/v1/asr", method="POST", body=wav, ctype="audio/wav",
                         headers={"X-Hear-Token": token})
        check("with the right token it works (200)", code == 200,
              "got %d: %s" % (code, data[:120]))

        code, data = req("/v1/asr", method="POST", body=wav, ctype="audio/wav",
                         headers={"X-Hear-Token": "wrong-token"})
        check("with a wrong token it refuses (401)", code == 401, "got %d" % code)
    finally:
        stop_service(proc3)
        try:
            stub3.shutdown()
        except Exception:
            pass
        shutil.rmtree(tmp3, ignore_errors=True)

    shutil.rmtree(tmp, ignore_errors=True)

    check_hybrid_asr(wav)
    check_speaker_endpoint(wav)
    check_clone_readiness()
    check_connection_recovery()
    check_inference_admission()

    print("\npassed %d, failed %d" % (len(PASSED), len(FAILED)))
    if FAILED:
        for f in FAILED:
            print("  failed: %s" % f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
