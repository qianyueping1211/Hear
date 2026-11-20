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
import datetime
import io
import ipaddress
import json
import os
import select
import socket
import ssl
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
# 自签证书（make_cert.py 生成）。有的话同一个端口上 http 和 https 都能用
_HERE = os.path.dirname(os.path.abspath(__file__))
TLS_CERT = os.environ.get("HEAR_TLS_CERT", os.path.join(_HERE, "certs", "cert.pem"))
TLS_KEY = os.environ.get("HEAR_TLS_KEY", os.path.join(_HERE, "certs", "key.pem"))
# 识别用哪个方案：
#   whisper         只用 faster-whisper（准，但慢一点）
#   sensevoice      只用 SenseVoice（快，擅长中英日韩粤）
#   sensevoice+whisper  SenseVoice 先出初步结果，Whisper 再修正（推荐）
ASR_SCHEME = os.environ.get("HEAR_ASR_SCHEME", "sensevoice+whisper")
SENSEVOICE_DIR = os.environ.get(
    "HEAR_SENSEVOICE_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "models", "sensevoice"))
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


_sense = None
_sense_lock = threading.Lock()


def get_sensevoice():
    """懒加载 sherpa-onnx 的 SenseVoice（ONNX，CPU 也能跑）"""
    global _sense
    if _sense is not None:
        return _sense
    with _sense_lock:
        if _sense is not None:
            return _sense
        try:
            import sherpa_onnx
        except Exception as e:
            log("没装 sherpa-onnx，SenseVoice 方案用不了：%s" % e)
            return None
        model = os.path.join(SENSEVOICE_DIR, "model.int8.onnx")
        tokens = os.path.join(SENSEVOICE_DIR, "tokens.txt")
        if not (os.path.isfile(model) and os.path.isfile(tokens)):
            log("SenseVoice 模型没下好（%s）" % SENSEVOICE_DIR)
            return None
        try:
            log("正在加载 SenseVoice…")
            _sense = sherpa_onnx.OfflineRecognizer.from_sense_voice(
                model=model, tokens=tokens, num_threads=2, use_itn=True)
            log("SenseVoice 加载完成")
            return _sense
        except Exception as e:
            log("SenseVoice 加载失败：%s" % e)
            return None


def sensevoice_transcribe(samples, rate):
    """用 SenseVoice 识别。返回 (语言代码, 文字)"""
    rec = get_sensevoice()
    if rec is None:
        return ("", "")
    try:
        import numpy as np
        audio = np.asarray(samples, dtype=np.float32)
        if rate and rate != 16000 and len(audio) > 0:
            n = int(round(len(audio) * 16000.0 / float(rate)))
            if n > 0:
                idx = np.linspace(0, len(audio) - 1, n)
                audio = np.interp(idx, np.arange(len(audio)), audio).astype(np.float32)
        stream = rec.create_stream()
        stream.accept_waveform(16000, audio)
        rec.decode_stream(stream)
        text = (stream.result.text or "").strip()
        # SenseVoice 的结果里带语言和情绪标记，例如 <|zh|><|NEUTRAL|><|zh|><|withitn|>你好
        lang = ""
        if "<|zh|>" in text or "<|yue|>" in text:
            lang = "zh"
        elif "<|en|>" in text:
            lang = "en"
        elif "<|ja|>" in text:
            lang = "ja"
        elif "<|ko|>" in text:
            lang = "ko"
        for tag in ("<|zh|>", "<|en|>", "<|ja|>", "<|ko|>", "<|yue|>",
                    "<|NEUTRAL|>", "<|HAPPY|>", "<|SAD|>", "<|ANGRY|>", "<|FEARFUL|>",
                    "<|DISGUSTED|>", "<|SURPRISED|>", "<|withitn|>", "<|woitn|>"):
            text = text.replace(tag, "")
        text = text.strip()
        if "<|nospeech|>" in text or not text:
            return (lang, "")
        return (lang, text)
    except Exception as e:
        log("SenseVoice 识别失败：%s" % e)
        return ("", "")


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


def recognize(samples, rate, language, fallback, scheme=None, preview=False):
    """按方案选识别：
       whisper              只用 Whisper
       sensevoice           只用 SenseVoice
       sensevoice+whisper   SenseVoice 先出，Whisper 再修正
    preview = True 时只要快，不要跑 Whisper 修正（实时预览用）
    返回 (语言, 文字)"""
    scheme = (scheme or ASR_SCHEME or "whisper").strip().lower()
    # 注意：这里统一返回 (文字, 语言)

    if scheme == "sensevoice":
        sv_lang, sv_text = sensevoice_transcribe(samples, rate)
        if not sv_text:                     # SenseVoice 没听出来，退回 Whisper
            return whisper_transcribe(samples, rate, language, fallback)
        return (sv_text, sv_lang or fallback)

    if scheme == "sensevoice+whisper":
        # 先用 SenseVoice 快速出结果（快）
        fast_lang, fast_text = sensevoice_transcribe(samples, rate)
        # 实时预览只要快，不跑 Whisper 修正
        if preview:
            return (fast_text, fast_lang or fallback)
        # 再用 Whisper 修正（准）
        slow_text, slow_lang = whisper_transcribe(samples, rate, language, fallback)
        if not slow_text:
            return (fast_text, fast_lang or fallback)
        if not fast_text:
            return (slow_text, slow_lang or fallback)
        # 两个结果不一样就以 Whisper 为准，一样就用 SenseVoice 的（更快）
        if fast_text != slow_text:
            log("Whisper 修正：「%s」→「%s」" % (fast_text[:30], slow_text[:30]))
            return (slow_text, slow_lang or fast_lang or fallback)
        return (fast_text, fast_lang or slow_lang or fallback)

    # 默认：只用 Whisper
    return whisper_transcribe(samples, rate, language, fallback)


def whisper_transcribe(samples, rate, language, fallback):
    """只用 faster-whisper 识别"""
    model = get_whisper()
    # 必须给 numpy 的 float32 数组：
    # faster-whisper 只有在拿到 ndarray 时才跳过重新解码，
    # 给普通 list 它会当成文件去 av.open()，老版本 av 会直接报
    # "open() got an unexpected keyword argument 'metadata_errors'"。
    audio = to_float32(samples, rate)
    segments, info = model.transcribe(audio, language=language, beam_size=1, vad_filter=False)
    text = "".join(s.text for s in segments).strip()
    return (text, info.language or fallback)


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


def backend_state(url):
    """后端（llama-server）的状态：
       "就绪"   —— 服务在跑，模型也加载好了
       "加载中" —— 服务在跑，但模型还在加载（llama-server 回 503 loading model）
       "连不上" —— 服务没起来
    """
    key = url.rstrip("/")
    now = time.time()
    hit = _backend_cache.get(key)
    if hit and now - hit[0] < 2:
        return hit[1]
    state = "连不上"
    try:
        with urllib.request.urlopen(key + "/health", timeout=1.5) as resp:
            if 200 <= resp.status < 300:
                state = "就绪"
            else:
                state = "加载中"
    except urllib.error.HTTPError as e:
        # llama-server 加载模型时回 503 {"status":"loading model"}：
        # 服务是活的，只是还没准备好，不算连不上
        try:
            body = e.read().decode("utf-8", "ignore")
        except Exception:
            body = ""
        state = "加载中" if "loading" in body.lower() else "连不上"
    except Exception:
        state = "连不上"
    _backend_cache[key] = (now, state)
    return state


def backend_alive(url):
    """后端进程活着没有（加载中也算活着）"""
    return backend_state(url) != "连不上"


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "HearCloud/1.0"

    def log_message(self, fmt, *args):
        # 请求行里可能有二进制（TLS 握手打到 http 端口时就是一堆乱码），
        # 直接打进日志会看不清。这里判断一下：不是正常的 ASCII 请求行就整条换成提示。
        text = fmt % args
        if all((32 <= ord(c) < 127) or c in "\r\n\t" for c in text):
            log(text)
        else:
            log("收到一段二进制内容（不是 HTTP 请求），已忽略")

    # -- 工具 --

    def _send_json(self, obj, code=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_wav(self, wav, code=200):
        """直接发 wav 原始数据（手机端要原始音频时用，省掉 base64，内存小很多）"""
        self.send_response(code)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.end_headers()
        self.wfile.write(wav)

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
            out["asr_scheme"] = ASR_SCHEME
        out["mt"] = backend_state(MT_URL)
        if out["mt"] == "连不上":
            out["mt"] = "连不上（%s）" % MT_URL
        out["clone"] = backend_state(CLONE_URL)
        if out["clone"] == "连不上":
            out["clone"] = "连不上（%s）" % CLONE_URL
        return out

    def send_error(self, code, message=None, explain=None):
        # 400 多半是 https 的 TLS 握手打到了 http 的解析器（服务没生成证书），
        # 说清楚一点，不然日志里一堆乱码看不懂
        if code == 400 and message and "Bad request version" in str(message):
            message = ("这个不是 HTTP 请求：多半是 https 的 TLS 握手打到了这里。"
                       "服务没有证书（server/certs/cert.pem），"
                       "跑一次 python server/make_cert.py 生成，再重启服务")
        super().send_error(code, message, explain)

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
        # 手机可以临时指定用哪个方案（不带就用服务默认的）
        scheme = (self.headers.get("X-ASR-Scheme") or "").strip().lower()
        if scheme not in ("whisper", "sensevoice", "sensevoice+whisper"):
            scheme = ASR_SCHEME
        t0 = time.time()
        if ASR_URL:
            text, lang = self.asr_proxy(body, langs, fallback)
        else:
            samples, rate = decode_wav(body)
            language = langs[0] if len(langs) == 1 else None
            # 预览只要快：组合方案下只用 SenseVoice，不跑 Whisper 修正
            preview = (self.headers.get("X-ASR-Preview") or "").strip() == "1"
            text, lang = recognize(samples, rate, language, fallback, scheme, preview)
        log("识别（%s）%.1fs：%s" % (scheme, time.time() - t0, text[:40]))
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
        log("克隆 开始：%d 字，参考音频 %d 字节"
            % (len(payload.get("input", "")), len(payload.get("speaker_ref_b64", "")) * 3 // 4))
        data = json.dumps(payload).encode("utf-8")
        r = urllib.request.Request(CLONE_URL + "/tts", data=data,
                                   headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=900) as resp:
            wav = resp.read()
        rate = wav_sample_rate(wav)
        log("克隆 结束 %.1fs：%d 字节，%d Hz" % (time.time() - t0, len(wav), rate))
        # 手机端在请求头里说明要原始 wav：直接发 wav（不用 base64，手机那边省内存）
        if (self.headers.get("X-Hear-Audio") or "").strip().lower() == "wav":
            self._send_wav(wav)
            return
        self._send_json({
            "audio": base64.b64encode(wav).decode("ascii"),
            "sample_rate": rate,
        })


def ensure_cert():
    """确保有自签证书；没有就自己生成一份。

    App 只走 https，所以证书必须有。放在这里自己生成，
    就不会因为"某个文件没下载下来"而没有证书。
    """
    if os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        return True
    try:
        from cryptography import x509
        from cryptography.x509.oid import NameOID
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
    except ImportError:
        log("没有 cryptography 这个包，生成不了证书")
        log("   装一下：pip install cryptography")
        return False
    try:
        os.makedirs(os.path.dirname(TLS_CERT), exist_ok=True)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "hear-cloud")])
        ips = []
        for ip in local_ips():
            try:
                ips.append(ipaddress.ip_address(ip))
            except ValueError:
                pass
        ips.append(ipaddress.ip_address("127.0.0.1"))
        san = [x509.DNSName("localhost"), x509.DNSName("hear-cloud.local")]
        san += [x509.IPAddress(i) for i in ips]
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(name).issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=3650))
            .add_extension(x509.SubjectAlternativeName(san), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(key, hashes.SHA256())
        )
        with open(TLS_CERT, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))
        with open(TLS_KEY, "wb") as f:
            f.write(key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption()))
        log("自签证书生成好了：%s" % TLS_CERT)
        return True
    except Exception as e:
        log("证书生成失败：%s" % e)
        return False


def make_ssl_context():
    """有自签证书就返回 TLS 上下文，没有就返回 None（只用 http）"""
    if not ensure_cert():
        return None
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        return ctx
    except Exception as e:
        log("证书用不了（%s），这次只用 http" % e)
        return None


class MixedServer(ThreadingHTTPServer):
    """同一个端口上 http 和 https 都能用。

    办法：接到连接先偷看一眼第一个字节。
    TLS 握手的第一个字节固定是 0x16，是 TLS 就套上 TLS，否则按普通 http 处理。
    这样手机里填 http://192.168.x.x:8000 或者 https://192.168.x.x:8000 都能连，
    不用来回改。
    """

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, ssl_context=None):
        super().__init__(addr, handler)
        self.ssl_context = ssl_context

    def process_request(self, request, client_address):
        # 握手在起线程之前做，这样一个慢连接不会挡住别人
        if self.ssl_context is not None:
            sock = request
            try:
                ready, _, _ = select.select([sock], [], [], 5)
            except (OSError, ValueError):
                ready = []
            if ready:
                try:
                    first = sock.recv(1, socket.MSG_PEEK)
                except OSError:
                    first = b""
                if first == b"\x16":
                    try:
                        request = self.ssl_context.wrap_socket(sock, server_side=True)
                    except Exception as e:
                        log("TLS 握手失败：%s" % e)
                        try:
                            sock.close()
                        except Exception:
                            pass
                        return
        super().process_request(request, client_address)


def main():
    # 先把端口占上（这样别人连过来不会报"拒绝连接"），再开始处理请求
    ctx = make_ssl_context()
    srv = MixedServer((HOST, PORT), Handler, ctx)
    log("服务起来了，监听 %s:%d" % (HOST, PORT))
    log("本机测试：https://127.0.0.1:%d/" % PORT)
    for ip in local_ips():
        if ctx is not None:
            log("手机访问：https://%s:%d/" % (ip, PORT))
        else:
            log("手机访问：http://%s:%d/" % (ip, PORT))
    if ctx is not None:
        log("App 里填上面那个 https:// 地址就行（同一个端口 http 也能用，浏览器自检页面用）")
    else:
        log("！！没有证书（server/certs/cert.pem），App 只走 https，现在手机连不上")
        log("   跑一次 python server/make_cert.py 生成证书，再重启服务")
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
