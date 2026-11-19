#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
“听见”App 的云端模型服务。

一个服务，三个模型接口（每个模型都是独立的，手机上可以分别选本地或云端）：

    GET  /health         看三个模型的状态
    POST /v1/asr         语音识别：请求体是 16 kHz 单声道 wav
                         返回 {"lang": "en", "text": "..."}
    POST /v1/translate   文本翻译：{"prompt": "...", "src": "zh", "dst": "en"}
                         返回 {"text": "..."}
    POST /v1/clone       声音克隆：{"text": "...", "lang": "english",
                                     "reference_wav": "<base64 的 wav>",
                                     "reference_text": "..."}
                         返回 {"audio": "<base64 的 wav>", "sample_rate": 24000}

翻译和声音克隆都转发给 llama.cpp 的 llama-server（两个不同的实例，各跑各的模型）；
语音识别默认用 faster-whisper 在本进程里跑，也可以设 HEAR_ASR_URL 转发给别的
OpenAI 兼容的转写服务（例如 whisper.cpp 的 whisper-server）。

只用 Python 标准库就能跑起来（识别模型另需 faster-whisper）。
"""

import base64
import io
import json
import os
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("HEAR_HOST", "0.0.0.0")
PORT = int(os.environ.get("HEAR_PORT", "8000"))
MT_URL = os.environ.get("HEAR_MT_URL", "http://127.0.0.1:8081").rstrip("/")
CLONE_URL = os.environ.get("HEAR_CLONE_URL", "http://127.0.0.1:8082").rstrip("/")
ASR_URL = os.environ.get("HEAR_ASR_URL", "").rstrip("/")
ASR_MODEL = os.environ.get("HEAR_ASR_MODEL", "small")
ASR_DEVICE = os.environ.get("HEAR_ASR_DEVICE", "cpu")
ASR_COMPUTE = os.environ.get("HEAR_ASR_COMPUTE", "int8")
# 和 App 本地翻译用的采样参数保持一致（Hy-MT2 官方推荐）
TOP_K = int(os.environ.get("HEAR_TOP_K", "20"))
TOP_P = float(os.environ.get("HEAR_TOP_P", "0.6"))
TEMPERATURE = float(os.environ.get("HEAR_TEMPERATURE", "0.7"))

_whisper = None
_whisper_lock = threading.Lock()
# 识别模型的状态：未加载 / 加载中 / 就绪 / 失败
# 加载放在后台线程里，/health 不用等它（第一次要下载模型，要等好几分钟）
_whisper_state = {"status": "未加载", "detail": ""}


def log(*args):
    print("[听见]", *args, flush=True)


def local_ips():
    """这台电脑现在用的 IP（去掉 127 开头的回环地址）"""
    import socket
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.append(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    # getaddrinfo 有时候会卡好几秒（域名解析），放到后台线程里，最多等 1 秒
    found = []

    def work():
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                ip = info[4][0]
                if not ip.startswith("127.") and ip not in found:
                    found.append(ip)
        except Exception:
            pass

    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(1.0)
    for ip in found:
        if ip not in ips:
            ips.append(ip)
    return ips


# ---------------------------------------------------------------- 识别模型

def get_whisper():
    """懒加载 faster-whisper（第一次调用时才加载，模型也会在那时下载）"""
    global _whisper
    if _whisper is not None:
        return _whisper
    with _whisper_lock:
        if _whisper is None:
            try:
                from faster_whisper import WhisperModel
            except Exception as e:      # 没装 faster-whisper
                _whisper_state["status"] = "失败"
                _whisper_state["detail"] = "没有装 faster-whisper：%s" % e
                log(_whisper_state["detail"])
                raise
            _whisper_state["status"] = "加载中"
            log("正在加载识别模型", ASR_MODEL, "…（第一次要下载模型，等一会儿）")
            try:
                _whisper = WhisperModel(ASR_MODEL, device=ASR_DEVICE, compute_type=ASR_COMPUTE)
            except Exception as e:      # 下载失败 / 模型不对
                _whisper_state["status"] = "失败"
                _whisper_state["detail"] = "识别模型加载失败：%s" % e
                log(_whisper_state["detail"])
                raise
            _whisper_state["status"] = "就绪"
            log("识别模型好了")
    return _whisper


def whisper_status():
    """识别模型现在什么状态（不阻塞）。"""
    st = _whisper_state.get("status", "未加载")
    if st == "就绪":
        return "就绪（%s）" % ASR_MODEL
    if st == "加载中":
        return "加载中（第一次要下识别模型）"
    if st == "失败":
        return "未安装 faster-whisper"
    return "未加载"


def self_check():
    """后台自己连一下，通不通立刻就知道（不能挡住服务接收请求）"""
    time.sleep(2)
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/health" % PORT, timeout=20) as r:
            log("自检通过（%d）。在电脑浏览器打开上面第一个地址能打开，就说明服务没问题；"
                "打不开就是服务没起来。" % r.status)
    except Exception as e:
        log("自检失败：%s" % e)


def warm_backends():
    """后台先把翻译/克隆后端的状态查一遍，/health 第一次调用也不用等"""
    for u in (MT_URL, CLONE_URL):
        try:
            backend_alive(u)
        except Exception:
            pass


def preload_whisper():
    """后台把识别模型准备好（第一次要下模型），别让 /health 干等着。"""
    try:
        get_whisper()
    except Exception:
        pass



def decode_wav(data):
    """wav 字节 → (float32 列表, 采样率)，只取第一个声道"""
    with wave.open(io.BytesIO(data), "rb") as w:
        channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    if width == 2:
        import array
        a = array.array("h")
        a.frombytes(frames)
        samples = [x / 32768.0 for x in a]
    elif width == 4:
        import array
        a = array.array("f")
        a.frombytes(frames)
        samples = list(a)
    else:
        raise ValueError("只支持 16 位或 32 位浮点的 wav")
    if channels > 1:
        samples = samples[::channels]
    return samples, rate


def to_float32(samples, rate):
    """列表 -> numpy float32 数组（16 kHz 单声道），faster-whisper 直接吃这个"""
    try:
        import numpy as np
    except Exception:
        return samples
    try:
        a = np.asarray(samples, dtype=np.float32)
        # 不是 16 kHz 就先重采样（手机那边发过来的是 16 kHz）
        if rate and rate != 16000 and len(a) > 0:
            n = int(round(len(a) * 16000.0 / float(rate)))
            if n > 0:
                idx = np.linspace(0, len(a) - 1, n)
                a = np.interp(idx, np.arange(len(a)), a).astype(np.float32)
        return a
    except Exception as e:
        log("转成 numpy 失败：%s" % e)
        return samples


def wav_sample_rate(data):
    """从 wav 头里读采样率（读不出来就按 24 kHz 算）"""
    try:
        with wave.open(io.BytesIO(data), "rb") as w:
            return w.getframerate()
    except Exception:
        return 24000


# ---------------------------------------------------------------- 后端转发

def http_json(url, payload, timeout):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


# 后端（翻译 / 克隆）的存活状态缓存：最多两秒查一次。
# 不缓存的话，后端没起来时每次 /health 都要等 3 秒 + 3 秒，
# 手机那边 5 秒就超时了，会误报成"连不上"。
_backend_cache = {}


def backend_alive(url):
    key = url.rstrip("/")
    now = time.time()
    hit = _backend_cache.get(key)
    if hit and now - hit[0] < 2:
        return hit[1]
    ok = False
    try:
        with urllib.request.urlopen(key + "/health", timeout=1.5) as resp:
            ok = 200 <= resp.status < 300
    except Exception:
        ok = False
    _backend_cache[key] = (now, ok)
    return ok


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "HearCloud/1.0"

    def log_message(self, fmt, *args):
        log(fmt % args)

    # -- 工具 --

    def _send_json(self, obj, code=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _error(self, msg, code=400):
        self._send_json({"error": str(msg)}, code)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    # -- GET --

    def do_GET(self):
        try:
            if self.path.startswith("/health"):
                self._send_json(self.health())
            elif self.path.startswith("/ping"):
                self._send_json({"pong": True, "time": time.time()})
            elif self.path.startswith("/"):
                self._send_html(self.test_page())
            else:
                self._error("没有这个接口", 404)
        except (BrokenPipeError, ConnectionResetError):
            pass          # 手机那边超时断开了，不用刷报错

    def _send_html(self, html):
        data = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def test_page(self):
        """手机浏览器打开首页，能打开就说明手机到电脑的网络是通的（跟 App 无关）"""
        ips = local_ips()
        rows = "".join(
            "<tr><td>%s</td><td><a href=\"http://%s:%d/\">http://%s:%d/</a></td></tr>" % (ip, ip, PORT, ip, PORT)
            for ip in ips)
        return """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>听见 云端服务</title>
<style>
body{font:16px -apple-system,system-ui,sans-serif;margin:24px;background:#f6f6f7;color:#111}
h1{font-size:20px}
p{color:#555}
table{border-collapse:collapse;width:100%%;background:#fff;border-radius:12px;overflow:hidden}
td{padding:12px 14px;border-bottom:1px solid #eee}
a{color:#007aff;text-decoration:none}
.ok{color:#1a9e3c;font-weight:600}
</style></head><body>
<h1>听见 App 云端服务</h1>
<p class="ok">连上了！说明你的手机能访问这台电脑。</p>
<p>下面这些地址在手机浏览器里也能打开（不同手机显示的 IP 不一样，选能打开的那个）：</p>
<table>%s</table>
<p>服务端口：%d</p>
<p>如果这个页面能打开，但 App 里还提示连不上，去手机
设置 → 隐私与安全性 → 本地网络，把"听见"打开。</p>
</body></html>""" % (rows, PORT)

    def health(self):
        out = {}
        if ASR_URL:
            out["asr"] = "外部服务" if backend_alive(ASR_URL) else "外部服务连不上"
        else:
            out["asr"] = whisper_status()
        out["mt"] = "就绪" if backend_alive(MT_URL) else "连不上（%s）" % MT_URL
        out["clone"] = "就绪" if backend_alive(CLONE_URL) else "连不上（%s）" % CLONE_URL
        return out

    # -- POST --

    def do_POST(self):
        body = self._body()
        try:
            if self.path.startswith("/v1/asr"):
                self.asr(body)
            elif self.path.startswith("/v1/translate"):
                self.translate(body)
            elif self.path.startswith("/v1/clone"):
                self.clone(body)
            else:
                self._error("没有这个接口", 404)
        except (BrokenPipeError, ConnectionResetError):
            pass          # 手机那边超时断开了，不用刷报错
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:500]
            self._error("后端返回 %s：%s" % (e.code, detail), 502)
        except Exception as e:
            traceback.print_exc()
            self._error(str(e), 500)

    # -- 语音识别 --

    def asr(self, body):
        langs = [x.strip() for x in (self.headers.get("X-Languages") or "").split(",") if x.strip()]
        fallback = self.headers.get("X-Fallback-Language") or ""
        t0 = time.time()
        if ASR_URL:
            text, lang = self.asr_proxy(body, langs, fallback)
        else:
            samples, rate = decode_wav(body)
            model = get_whisper()
            language = langs[0] if len(langs) == 1 else None
            # 必须给 numpy 的 float32 数组：
            # faster-whisper 只有在拿到 ndarray 时才跳过重新解码，
            # 给普通 list 它会当成文件去 av.open()，老版本 av 会直接报
            # "open() got an unexpected keyword argument 'metadata_errors'"。
            audio = to_float32(samples, rate)
            segments, info = model.transcribe(audio, language=language, beam_size=1, vad_filter=False)
            text = "".join(s.text for s in segments).strip()
            lang = info.language or fallback
        log("识别 %.1fs：%s" % (time.time() - t0, text[:40]))
        self._send_json({"lang": lang or fallback, "text": text})

    def asr_proxy(self, body, langs, fallback):
        """转发给 OpenAI 兼容的转写接口（multipart/form-data）"""
        boundary = "----HearBoundary7MA4YWxkTrZu0gW"
        parts = []
        parts.append(("--%s\r\n" % boundary).encode())
        parts.append(b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n')
        parts.append(b"Content-Type: audio/wav\r\n\r\n")
        parts.append(body)
        parts.append(("\r\n--%s\r\n" % boundary).encode())
        parts.append(b'Content-Disposition: form-data; name="model"\r\n\r\n')
        parts.append(b"whisper-1\r\n")
        parts.append(("--%s--\r\n" % boundary).encode())
        data = b"".join(parts)
        req = urllib.request.Request(
            ASR_URL + "/v1/audio/transcriptions", data=data,
            headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary})
        with urllib.request.urlopen(req, timeout=300) as resp:
            obj = json.loads(resp.read().decode("utf-8"))
        return obj.get("text", ""), obj.get("language", fallback)

    # -- 文本翻译 --

    def translate(self, body):
        req = json.loads(body.decode("utf-8"))
        prompt = req.get("prompt", "")
        payload = {
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
            "max_tokens": int(req.get("max_tokens", 512)),
            "top_k": TOP_K,
            "top_p": TOP_P,
            "temperature": TEMPERATURE,
        }
        t0 = time.time()
        raw = http_json(MT_URL + "/v1/chat/completions", payload, timeout=300)
        obj = json.loads(raw.decode("utf-8"))
        text = obj["choices"][0]["message"]["content"]
        log("翻译 %.1fs：%s" % (time.time() - t0, text[:40]))
        self._send_json({"text": text})

    # -- 声音克隆 --

    def clone(self, body):
        req = json.loads(body.decode("utf-8"))
        payload = {
            "input": req.get("text", ""),
            "lang": req.get("lang", ""),
            "speaker_ref_b64": req.get("reference_wav", ""),
            "speaker_ref_text": req.get("reference_text", ""),
        }
        payload = {k: v for k, v in payload.items() if v}
        t0 = time.time()
        data = json.dumps(payload).encode("utf-8")
        r = urllib.request.Request(CLONE_URL + "/tts", data=data,
                                   headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=900) as resp:
            wav = resp.read()
        rate = wav_sample_rate(wav)
        log("克隆 %.1fs：%d 字节，%d Hz" % (time.time() - t0, len(wav), rate))
        self._send_json({
            "audio": base64.b64encode(wav).decode("ascii"),
            "sample_rate": rate,
        })


def main():
    # 先把端口占上（这样别人连过来不会报"拒绝连接"），再开始处理请求
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    log("服务起来了，监听 %s:%d" % (HOST, PORT))
    log("本机测试：http://127.0.0.1:%d/" % PORT)
    for ip in local_ips():
        log("手机访问：http://%s:%d/" % (ip, PORT))
    log("翻译后端：%s" % MT_URL)
    log("克隆后端：%s" % CLONE_URL)
    log("识别后端：%s" % (ASR_URL or "本机 faster-whisper（%s）" % ASR_MODEL))
    # 这些都在后台做，不要挡住服务接收请求
    if not ASR_URL:
        threading.Thread(target=preload_whisper, daemon=True).start()
    threading.Thread(target=warm_backends, daemon=True).start()
    threading.Thread(target=self_check, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("停了")
        srv.server_close()


if __name__ == "__main__":
    main()
