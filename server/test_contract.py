# -*- coding: utf-8 -*-
"""云端服务的"接口契约"自测。

目的：保证 App 和服务之间的约定不会悄悄变。
每次改完 server/ 都要跑一遍（CI 里也会跑）。

测的是"约定"，不是模型效果：这里不真的跑识别/翻译/克隆，
只检查接口的形状、错误处理和边界情况。

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
import time
import urllib.error
import urllib.request
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("HEAR_CONTRACT_PORT", "8199"))
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


def main():
    tmp = tempfile.mkdtemp(prefix="hear-contract-")
    env = dict(os.environ)
    env["HEAR_PORT"] = str(PORT)
    env["HEAR_TLS_CERT"] = os.path.join(tmp, "cert.pem")
    env["HEAR_TLS_KEY"] = os.path.join(tmp, "key.pem")
    env["HEAR_ROOT_CERT"] = os.path.join(tmp, "root.pem")
    env["HEAR_ROOT_KEY"] = os.path.join(tmp, "root.key")
    env["HEAR_SENSEVOICE_DIR"] = os.path.join(tmp, "sensevoice")
    env["PYTHONUTF8"] = "1"

    print("start service (port %d, tmp %s) ..." % (PORT, tmp))
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "hear_cloud.py")],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
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

        print("\n== /health ==")
        code, data = req("/health")
        check("/health returns 200", code == 200, "got %d" % code)
        try:
            h = json.loads(data.decode("utf-8"))
            check("/health has asr/mt/clone", all(k in h for k in ("asr", "mt", "clone")),
                  "got %s" % list(h.keys()))
            check("/health has asr_schemes (App builds the scheme list from it)",
                  "asr_schemes" in h, "(older servers do not have it)")
        except Exception as e:
            check("/health returns JSON", False, str(e))

        print("\n== /v1/pair ==")
        code, data = req("/v1/pair")
        check("/v1/pair returns 200", code == 200, "got %d" % code)
        try:
            p = json.loads(data.decode("utf-8"))
            check("has root_fingerprint", bool(p.get("root_fingerprint")))
            check("has root_der", bool(p.get("root_der")))
        except Exception as e:
            check("/v1/pair returns JSON", False, str(e))

        print("\n== /v1/asr ==")
        wav = make_wav()
        code, data = req("/v1/asr", method="POST", body=wav, ctype="audio/wav",
                         headers={"X-Languages": "zh,en"})
        check("posting wav does not crash the service", code in (200, 400, 500), "got %d" % code)
        try:
            j = json.loads(data.decode("utf-8"))
            check("response is JSON (text or error)", ("text" in j) or ("error" in j),
                  "got %s" % list(j.keys()))
        except Exception as e:
            check("response is JSON", False, str(e))

        code, data = req("/v1/asr", method="POST",
                         body=json.dumps({"audio": "AAAA"}).encode("utf-8"))
        check("posting JSON (wrong format) does not break it", code in (200, 400, 500),
              "got %d" % code)

        print("\n== /v1/clone/reference ==")
        code, data = req("/v1/clone/reference", method="POST", body=wav, ctype="audio/wav")
        check("storing a reference returns 200", code == 200, "got %d" % code)
        try:
            j = json.loads(data.decode("utf-8"))
            check("returns a reference id", bool(j.get("id")))
        except Exception as e:
            check("response is JSON", False, str(e))

        print("\n== limits ==")
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
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        shutil.rmtree(tmp, ignore_errors=True)

    print("\npassed %d, failed %d" % (len(PASSED), len(FAILED)))
    if FAILED:
        for f in FAILED:
            print("  failed: %s" % f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
