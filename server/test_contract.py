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


def start_service(tmp, port, asr_url=""):
    env = dict(os.environ)
    env["HEAR_PORT"] = str(port)
    env["HEAR_TLS_CERT"] = os.path.join(tmp, "cert.pem")
    env["HEAR_TLS_KEY"] = os.path.join(tmp, "key.pem")
    env["HEAR_ROOT_CERT"] = os.path.join(tmp, "root.pem")
    env["HEAR_ROOT_KEY"] = os.path.join(tmp, "root.key")
    env["HEAR_SENSEVOICE_DIR"] = os.path.join(tmp, "sensevoice")
    env["PYTHONUTF8"] = "1"
    if asr_url:
        env["HEAR_ASR_URL"] = asr_url
    else:
        env.pop("HEAR_ASR_URL", None)
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

    shutil.rmtree(tmp, ignore_errors=True)

    print("\npassed %d, failed %d" % (len(PASSED), len(FAILED)))
    if FAILED:
        for f in FAILED:
            print("  failed: %s" % f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
