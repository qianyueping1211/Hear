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


def log(*args):
    print("[听见]", *args, flush=True)


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
                log("没有装 faster-whisper，语音识别用不了：", e)
                raise
            log("正在加载识别模型", ASR_MODEL, "…")
            _whisper = WhisperModel(ASR_MODEL, device=ASR_DEVICE, compute_type=ASR_COMPUTE)
            log("识别模型好了")
    return _whisper


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


def backend_alive(url):
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/health", timeout=3) as resp:
            return 200 <= resp.status < 300
    except Exception:
        return False


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
        if self.path.startswith("/health"):
            self._send_json(self.health())
        else:
            self._error("没有这个接口", 404)

    def health(self):
        out = {}
        if ASR_URL:
            out["asr"] = "外部服务" if backend_alive(ASR_URL) else "外部服务连不上"
        else:
            try:
                get_whisper()
                out["asr"] = "就绪（%s）" % ASR_MODEL
            except Exception:
                out["asr"] = "未安装 faster-whisper"
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
            segments, info = model.transcribe(samples, language=language, beam_size=1, vad_filter=False)
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
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    log("服务起来了，监听 %s:%d" % (HOST, PORT))
    log("翻译后端：%s" % MT_URL)
    log("克隆后端：%s" % CLONE_URL)
    log("识别后端：%s" % (ASR_URL or "本机 faster-whisper（%s）" % ASR_MODEL))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("停了")
        srv.server_close()


if __name__ == "__main__":
    main()
