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
    POST /v1/clone/reference
                         存一次参考音频（请求体是 wav 二进制），返回 {"id": "..."};
                         后面的克隆请求带 "reference_id" 就行，
                         不用每句话都把参考音频重传一遍

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
import queue
import secrets
import signal
import socket
import ssl
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
import wave
import struct
from contextlib import contextmanager
from http.client import HTTPConnection, HTTPSConnection
from http.server import ThreadingHTTPServer
from urllib.parse import urlsplit

import hear_auth
from hear_http import ERROR_CODES, RequestHandler, RequestPolicy, clone_upstream
from hear_speaker import SpeakerDetector

HOST = (os.environ.get("HEAR_BIND_HOST") or os.environ.get("HEAR_HOST", "0.0.0.0")).strip() or "0.0.0.0"
PORT = int(os.environ.get("HEAR_PORT", "8000"))
MT_URL = os.environ.get("HEAR_MT_URL", "http://127.0.0.1:8081").rstrip("/")
CLONE_URL = os.environ.get("HEAR_CLONE_URL", "http://127.0.0.1:8082").rstrip("/")
ASR_URL = os.environ.get("HEAR_ASR_URL", "").rstrip("/")
ASR_MODEL = os.environ.get("HEAR_ASR_MODEL", "small")
LOCAL_SECRET = os.environ.get("HEAR_LOCAL_SECRET", "").strip()
# 本机后端回环调用统一绕过 Windows/系统代理，避免代理软件劫持 127.0.0.1
_DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
MAX_BACKEND_JSON_BYTES = 8 * 1024 * 1024
# 自签证书（make_cert.py 生成）。有的话同一个端口上 http 和 https 都能用
_HERE = os.path.dirname(os.path.abspath(__file__))
TLS_CERT = os.environ.get("HEAR_TLS_CERT", os.path.join(_HERE, "certs", "cert.pem"))
TLS_KEY = os.environ.get("HEAR_TLS_KEY", os.path.join(_HERE, "certs", "key.pem"))
# 这台电脑自己的"签发根"：长期不变的一份根证书。
# 换网络、换 IP 的时候用它重签服务器证书就行，
# 手机上配对过一次就一直认（不用每次重新配对）。
ROOT_CERT = os.environ.get("HEAR_ROOT_CERT", os.path.join(_HERE, "certs", "root.pem"))
ROOT_KEY = os.environ.get("HEAR_ROOT_KEY", os.path.join(_HERE, "certs", "root.key"))
# 接到连接后偷看第一个字节，最多等这么久（等太久就当这个连接没用了）
TLS_PEEK_TIMEOUT = float(os.environ.get("HEAR_TLS_PEEK_TIMEOUT", "8"))
# 识别用哪个方案：
#   whisper         只用 faster-whisper（准，但慢一点）
#   sensevoice      只用 SenseVoice（快，擅长中英日韩粤）
#   sensevoice+whisper  SenseVoice 先出初步结果，Whisper 再修正（推荐）
ASR_SCHEME = os.environ.get("HEAR_ASR_SCHEME", "sensevoice+whisper")
SENSEVOICE_DIR = os.environ.get(
    "HEAR_SENSEVOICE_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "models", "sensevoice"))
SPEAKER_MODEL = "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
SPEAKER = SpeakerDetector(os.environ.get("HEAR_SPEAKER_MODEL", "") or
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "models", SPEAKER_MODEL))
# 单个请求最大允许多少（正常请求几 MB 就够）
MAX_BODY = int(os.environ.get("HEAR_MAX_BODY", str(64 * 1024 * 1024)))
ASR_DEVICE = os.environ.get("HEAR_ASR_DEVICE", "cpu")
ASR_COMPUTE = os.environ.get("HEAR_ASR_COMPUTE", "int8")
# 和 App 本地翻译用的采样参数保持一致（Hy-MT2 官方推荐）：
# - Hy-MT2-1.8B / 7B：temperature=0.7, top_p=0.6, top_k=20, repeat_penalty=1.05
# - Hy-MT2-30B-A3B：  temperature=0.7, top_p=1.0, top_k=-1, repeat_penalty=1.0
TOP_K = int(os.environ.get("HEAR_TOP_K", "20"))
TOP_P = float(os.environ.get("HEAR_TOP_P", "0.6"))
TEMPERATURE = float(os.environ.get("HEAR_TEMPERATURE", "0.7"))
REPEAT_PENALTY = float(os.environ.get("HEAR_REPEAT_PENALTY", "1.05"))
_MT_MODEL_HINT_CACHE = {"url": "", "model": "", "checked_at": 0.0}


def _detect_mt_model_hint():
    tier = os.environ.get("HEAR_MT_TIER", "").strip().lower()
    if tier:
        return tier
    now = time.time()
    if _MT_MODEL_HINT_CACHE["url"] == MT_URL and (now - _MT_MODEL_HINT_CACHE["checked_at"]) < 120:
        return _MT_MODEL_HINT_CACHE["model"]
    hint = ""
    try:
        props = http_json(MT_URL + "/props", timeout=1.5)
        if isinstance(props, dict):
            hint = str(props.get("model_path") or props.get("model_alias") or "").lower()
    except Exception:
        hint = ""
    _MT_MODEL_HINT_CACHE.update({"url": MT_URL, "model": hint, "checked_at": now})
    return hint


def resolve_mt_sampling_params():
    """按 Hy-MT2 模型规格选择官方推荐采样参数，环境变量显式指定时优先生效。"""
    hint = _detect_mt_model_hint()
    is_30b = "30b" in hint
    default_top_k = -1 if is_30b else TOP_K
    default_top_p = 1.0 if is_30b else TOP_P
    default_temp = 0.7 if is_30b else TEMPERATURE
    default_rep = 1.0 if is_30b else REPEAT_PENALTY
    top_k = int(os.environ["HEAR_TOP_K"]) if "HEAR_TOP_K" in os.environ else default_top_k
    top_p = float(os.environ["HEAR_TOP_P"]) if "HEAR_TOP_P" in os.environ else default_top_p
    temp = float(os.environ["HEAR_TEMPERATURE"]) if "HEAR_TEMPERATURE" in os.environ else default_temp
    rep = float(os.environ["HEAR_REPEAT_PENALTY"]) if "HEAR_REPEAT_PENALTY" in os.environ else default_rep
    return {
        "top_k": top_k,
        "top_p": top_p,
        "temperature": temp,
        "repeat_penalty": rep,
    }

_whisper = None
_whisper_lock = threading.Lock()
# 识别模型的状态：未加载 / 加载中 / 就绪 / 失败
# 加载放在后台线程里，/health 不用等它（第一次要下载模型，要等好几分钟）
_whisper_state = {"status": "未加载", "detail": ""}


# 日志里要不要记用户说的话（识别出来的原文、译文）。
# 内测期间默认记录，便于从这里直接排查识别和翻译问题。
# 正式环境默认关闭。HEAR_LOG_CONTENT 仍可显式覆盖该默认值。
DEPLOYMENT = os.environ.get("HEAR_DEPLOYMENT", "internal").strip().lower()
LOG_CONTENT = os.environ.get("HEAR_LOG_CONTENT", "0" if DEPLOYMENT == "production" else "1").strip().lower() in ("1", "true", "yes", "on")


# 访问口令：开了以后，客户端必须带上 X-Hear-Token 才能用推理接口。
# 默认不开（自己家里用不影响）；想挡住局域网里别的设备就设 HEAR_REQUIRE_TOKEN=1。
ACCESS_TOKEN_FILE = os.environ.get("HEAR_TOKEN_FILE",
                                   os.path.join(_HERE, "certs", "access-token.txt"))
REQUIRE_TOKEN = os.environ.get("HEAR_REQUIRE_TOKEN", "").strip().lower() in ("1", "true", "yes", "on")
ALLOW_LOOPBACK_HTTP = os.environ.get("HEAR_ALLOW_LOOPBACK_HTTP", "").strip().lower() in ("1", "true", "yes", "on")
# 管理模式（HEAR_AUTH_MODE=managed）：口令由 Token 管理服务签发，网关定时同步清单（见 hear_auth.py）。
# 这时 HEAR_REQUIRE_TOKEN 和 access-token.txt 都不再使用。
AUTH = None
AUTH_MODE = "legacy" if REQUIRE_TOKEN else "off"


def _write_private_bytes(path, data):
    """使用最小权限（0o600）临时文件原子写入敏感文件（私钥、口令等）。"""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    tmp = "%s.tmp.%s" % (path, secrets.token_hex(6))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    fd = os.open(tmp, flags, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        if os.name != "nt":
            try:
                os.chmod(tmp, 0o600)
            except OSError:
                pass
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _sanitize_log_value(value, limit=64):
    """清洗外部传入用于日志的字符串，防止换行/控制符日志注入。"""
    text = str(value or "")
    cleaned = "".join(ch if 32 <= ord(ch) < 127 else "?" for ch in text)
    return cleaned[:limit]


def access_token():
    """这个服务的访问口令（第一次用的时候生成一个，存下来）。"""
    try:
        os.makedirs(os.path.dirname(ACCESS_TOKEN_FILE), exist_ok=True)
        if os.path.exists(ACCESS_TOKEN_FILE):
            with open(ACCESS_TOKEN_FILE, "r", encoding="utf-8") as f:
                t = f.read().strip()
            if t:
                return t
        t = secrets.token_hex(16)
        _write_private_bytes(ACCESS_TOKEN_FILE, t.encode("utf-8"))
        return t
    except Exception as e:
        log("访问口令生成不了：%s" % e)
        return ""


class ConsoleLog:
    def __init__(self):
        self.pending = queue.Queue(maxsize=512)

    def start(self):
        threading.Thread(target=self.write, name="hear-console-log", daemon=True).start()

    def submit(self, *args):
        # A selected Windows console or an unread pipe can block writes indefinitely.
        # Keep serving requests even when the logging backlog is full.
        try:
            self.pending.put_nowait(args)
        except queue.Full:
            pass

    def write(self):
        while True:
            args = self.pending.get()
            try:
                print("[听见]", *args, flush=True)
            except OSError:
                pass


_console_log = ConsoleLog()


def log(*args):
    _console_log.submit(*args)


@contextmanager
def console_without_quick_edit():
    if os.name != "nt":
        yield
        return

    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32")
    get_handle = kernel32.GetStdHandle
    get_handle.argtypes = [wintypes.DWORD]
    get_handle.restype = wintypes.HANDLE
    get_mode = kernel32.GetConsoleMode
    get_mode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    get_mode.restype = wintypes.BOOL
    set_mode = kernel32.SetConsoleMode
    set_mode.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    set_mode.restype = wintypes.BOOL

    std_input_handle = -10
    quick_edit = 0x0040
    extended_flags = 0x0080
    handle = get_handle(std_input_handle)
    mode = wintypes.DWORD()
    changed = (get_mode(handle, ctypes.byref(mode)) and mode.value & quick_edit
               and set_mode(handle, (mode.value | extended_flags) & ~quick_edit))
    try:
        yield
    finally:
        if changed:
            set_mode(handle, mode.value | extended_flags)


def request_logs_content(headers):
    """App 明确打开“记录对话内容”时，本次请求允许记录文字。"""
    # 正式环境默认禁止，运维明确设置 0 时也不允许客户端覆盖。
    if DEPLOYMENT == "production" and not LOG_CONTENT:
        return False
    if "HEAR_LOG_CONTENT" in os.environ:
        return LOG_CONTENT
    value = (headers.get("X-Hear-Log-Content") or "").strip().lower()
    return LOG_CONTENT or value in ("1", "true", "yes", "on")


def log_text(prefix, content, enabled=False):
    """记一条带内容的话：默认把内容藏起来。"""
    if enabled:
        log("%s%s" % (prefix, content))
    else:
        log("%s（内容没记：在 App 的“日志”里打开“记录对话内容”才记）" % prefix)


def primary_ip():
    """这台电脑对外的那个 IP（手机要连的就是它；连不出去就返回空）"""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return ""


_local_ips_lock = threading.Lock()
_local_ips_cache = (0.0, None)


def local_ips(force=False):
    """这台电脑上所有网卡的 IPv4 地址（去掉 127 开头的回环地址，带 30s TTL 缓存）。"""
    global _local_ips_cache
    now = time.monotonic()
    with _local_ips_lock:
        if not force and _local_ips_cache[1] is not None and now - _local_ips_cache[0] < 30.0:
            return list(_local_ips_cache[1])
    import re
    import socket
    import subprocess
    ips = []

    def add(ip):
        ip = (ip or "").strip()
        if not ip or ip.startswith("127."):
            return
        if not re.match(r"^\d{1,3}(\.\d{1,3}){3}$", ip):
            return
        if ip not in ips:
            ips.append(ip)

    # 每张网卡上的地址：Windows 用 ipconfig，Mac/Linux 用 ifconfig / ip
    for cmd in (["ipconfig"], ["ifconfig", "-a"], ["ip", "-4", "-o", "addr"]):
        try:
            out = subprocess.run(cmd, capture_output=True, timeout=5).stdout.decode("utf-8", "ignore")
        except Exception:
            continue
        if not out:
            continue
        if cmd[0] == "ipconfig":
            # 中文："IPv4 地址. . . . . . . . . . . : 192.168.1.5"
            # 英文："IPv4 Address. . . . . . . . . . . : 192.168.1.5"
            for m in re.finditer(r"IPv4[^\n:]*[:：]\s*(\d{1,3}(?:\.\d{1,3}){3})", out, re.I):
                add(m.group(1))
        else:
            for m in re.finditer(r"inet (?:addr:)?(\d{1,3}(?:\.\d{1,3}){3})", out):
                add(m.group(1))
        if ips:
            break

    # 走默认路由出去用的那个地址（开了 VPN 的话就是 VPN 的地址）
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        add(s.getsockname()[0])
        s.close()
    except Exception:
        pass

    # 主机名解析出来的地址（getaddrinfo 有时候会卡好几秒，最多等 1 秒）
    def work():
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                add(info[4][0])
        except Exception:
            pass

    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(1.0)
    with _local_ips_lock:
        _local_ips_cache = (time.monotonic(), list(ips))
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
_sense_inference_slots = threading.BoundedSemaphore(2)
_whisper_inference_lock = threading.Lock()


def get_sensevoice():
    """懒加载 sherpa-onnx 的 SenseVoice（ONNX，CPU 也能跑）"""
    global _sense
    if os.environ.get("HEAR_SENSEVOICE", "1").strip().lower() in ("0", "off", "false", "no"):
        return None
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


def sensevoice_available():
    """SenseVoice 能不能用。
    启动时选了"不装 SenseVoice"（HEAR_SENSEVOICE=0）的话就不能用；
    模型文件不在也不能用（App 的识别方案里就不该给用户选它）。"""
    if os.environ.get("HEAR_SENSEVOICE", "1").strip().lower() in ("0", "off", "false", "no"):
        return False
    model = os.path.join(SENSEVOICE_DIR, "model.int8.onnx")
    tokens = os.path.join(SENSEVOICE_DIR, "tokens.txt")
    return os.path.isfile(model) and os.path.isfile(tokens)


# ── Edge-TTS 微软神经语音（0 本机 CPU 占用，~0.3-0.6s 出声，支持多语种拟真男女声） ──
_edge_tts_lock = threading.Lock()
_edge_tts_install_attempted = False


def edge_tts_available():
    try:
        import edge_tts  # noqa: F401
        return True
    except Exception:
        return False


def _ensure_edge_tts():
    global _edge_tts_install_attempted
    try:
        import edge_tts
        return edge_tts
    except ImportError:
        pass
    with _edge_tts_lock:
        try:
            import edge_tts
            return edge_tts
        except ImportError:
            pass
        if not _edge_tts_install_attempted:
            _edge_tts_install_attempted = True
            log("正在自动安装 edge-tts（微软神经语音组件，无需下载本地模型）…")
            import subprocess
            res = subprocess.run(
                [sys.executable, "-m", "pip", "install", "-q", "edge-tts"],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if res.returncode != 0:
                detail = (res.stderr or res.stdout or "").strip()[:200]
                raise RuntimeError("自动安装 edge-tts 失败：%s（可手动运行 pip install edge-tts）" % detail)
            log("edge-tts 安装完成")
        import edge_tts
        return edge_tts


def preload_edge_tts():
    """后台确保 edge-tts 已安装，避免首次调用时才安装。"""
    try:
        _ensure_edge_tts()
    except Exception as e:
        log("后台准备 edge-tts 未完成：%s" % e)


def _pick_edge_tts_voice(text, lang="", gender=""):
    ll = (lang or "").strip().lower()
    gl = (gender or "").strip().lower()
    is_male = gl == "male"
    if ll.startswith("zh") or "chinese" in ll:
        return "zh-CN-YunxiNeural" if is_male else "zh-CN-XiaoxiaoNeural"
    if ll.startswith("en") or "english" in ll:
        return "en-US-GuyNeural" if is_male else "en-US-JennyNeural"
    if ll.startswith("ja") or "japanese" in ll:
        return "ja-JP-KeitaNeural" if is_male else "ja-JP-NanamiNeural"
    if ll.startswith("ko") or "korean" in ll:
        return "ko-KR-InJoonNeural" if is_male else "ko-KR-SunHiNeural"
    if ll.startswith("fr") or "french" in ll:
        return "fr-FR-HenriNeural" if is_male else "fr-FR-DeniseNeural"
    if ll.startswith("de") or "german" in ll:
        return "de-DE-ConradNeural" if is_male else "de-DE-KatjaNeural"
    if ll.startswith("es") or "spanish" in ll:
        return "es-ES-AlvaroNeural" if is_male else "es-ES-ElviraNeural"
    has_cjk = any("\u4e00" <= ch <= "\u9fff" for ch in (text or ""))
    if has_cjk:
        return "zh-CN-YunxiNeural" if is_male else "zh-CN-XiaoxiaoNeural"
    return "en-US-GuyNeural" if is_male else "en-US-JennyNeural"


def _mp3_bytes_to_wav(mp3_bytes, target_sr=24000):
    """将 Edge-TTS 返回的 MP3 字节在内存中快速解码为 16-bit 单声道 PCM WAV。"""
    if not mp3_bytes:
        raise RuntimeError("Edge-TTS 未返回音频数据")
    try:
        import av
        container = av.open(io.BytesIO(mp3_bytes), format="mp3")
        resampler = av.AudioResampler(format="s16", layout="mono", rate=target_sr)
        chunks = []
        for frame in container.decode(audio=0):
            for out_frame in resampler.resample(frame):
                chunks.append(bytes(out_frame.planes[0]))
        for out_frame in resampler.resample(None):
            chunks.append(bytes(out_frame.planes[0]))
        container.close()
        pcm = b"".join(chunks)
        if not pcm:
            raise RuntimeError("MP3 解码结果为空")
        data_len = len(pcm)
        header = struct.pack(
            "<4sI4s4sIHHIIHH4sI",
            b"RIFF", 36 + data_len, b"WAVE",
            b"fmt ", 16, 1, 1, target_sr, target_sr * 2, 2, 16,
            b"data", data_len,
        )
        return header + pcm, target_sr
    except ImportError:
        import subprocess
        ffmpeg_bin = "ffmpeg"
        try:
            import imageio_ffmpeg
            ffmpeg_bin = imageio_ffmpeg.get_ffmpeg_exe()
        except Exception:
            pass
        proc = subprocess.run(
            [
                ffmpeg_bin, "-hide_banner", "-loglevel", "error",
                "-f", "mp3", "-i", "pipe:0",
                "-ac", "1", "-ar", str(target_sr), "-f", "wav", "pipe:1",
            ],
            input=mp3_bytes,
            capture_output=True,
            timeout=15,
        )
        if proc.returncode != 0 or len(proc.stdout) <= 44:
            raise RuntimeError("MP3 转 WAV 失败：%s" % (proc.stderr.decode("utf-8", "ignore")[:160]))
        return proc.stdout, target_sr


def edge_tts_synthesize_wav(text, lang="", gender=""):
    edge_tts = _ensure_edge_tts()
    clean_text = (text or "").strip()
    if not clean_text:
        raise ValueError("待合成文本为空")
    voice = _pick_edge_tts_voice(clean_text, lang, gender)
    import asyncio

    async def _run():
        comm = edge_tts.Communicate(clean_text, voice=voice)
        buf = bytearray()
        async for chunk in comm.stream():
            if chunk.get("type") == "audio":
                buf.extend(chunk.get("data") or b"")
        return bytes(buf)

    mp3_bytes = asyncio.run(_run())
    wav_bytes, sr = _mp3_bytes_to_wav(mp3_bytes, target_sr=24000)
    return wav_bytes, sr, voice


def whisper_available():
    """faster-whisper 装没装（装了 Whisper 方案就能用）"""
    try:
        import faster_whisper  # noqa: F401
        return True
    except Exception:
        return False


def asr_capabilities():
    """这台电脑上识别方面到底有什么：给 App 生成识别方案的候选项。

    App 的「在线模型 → 语音识别 → 配置 → 识别方案」就是照着这个列表给的，
    所以电脑上没装的方案不会出现在手机上。
    """
    sv = sensevoice_available()
    wh = whisper_available()
    schemes = []
    if sv:
        schemes.append("sensevoice")
    if wh:
        schemes.append("whisper")
    if sv and wh:
        schemes.append("sensevoice+whisper")
    return {
        "whisper_model": ASR_MODEL,
        "sensevoice": "就绪" if sv else "没装",
        "whisper": "就绪" if wh else "没装",
        # 逗号分隔：App 那边的 health 只收字符串
        "schemes": ",".join(schemes),
    }


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
        with _sense_inference_slots:
            stream = rec.create_stream()
            stream.accept_waveform(16000, audio)
            rec.decode_stream(stream)
            result = stream.result
        text = (result.text or "").strip()
        # Newer bindings expose language separately; older ones can embed it in text.
        language_tag = (getattr(result, "lang", "") or "").strip("<|>").lower()
        lang = {"yue": "zh"}.get(language_tag, language_tag)
        if lang not in ("zh", "en", "ja", "ko"):
            lang = ""
        # SenseVoice 的结果里带语言和情绪标记，例如 <|zh|><|NEUTRAL|><|zh|><|withitn|>你好
        if not lang:
            for code in ("zh", "yue", "en", "ja", "ko"):
                if f"<|{code}|>" in text:
                    lang = "zh" if code == "yue" else code
                    break
        for tag in ("<|zh|>", "<|en|>", "<|ja|>", "<|ko|>", "<|yue|>",
                    "<|NEUTRAL|>", "<|HAPPY|>", "<|SAD|>", "<|ANGRY|>", "<|FEARFUL|>",
                    "<|DISGUSTED|>", "<|SURPRISED|>", "<|withitn|>", "<|woitn|>"):
            text = text.replace(tag, "")
        text = text.strip()
        if language_tag == "nospeech" or "<|nospeech|>" in text or not text:
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
        detail = (_whisper_state.get("detail") or "").strip()
        return ("加载失败：%s" % detail[:80]) if detail else "未安装 faster-whisper"
    return "未加载"


def asr_status_text():
    """语音识别模块对外展示状态（综合 SenseVoice 与 faster-whisper）。"""
    ws = whisper_status()
    sv = sensevoice_available()
    wh_status = _whisper_state.get("status", "未加载")
    if ASR_SCHEME == "sensevoice":
        return "就绪（SenseVoice）" if sv else "SenseVoice 模型未就绪"
    if ASR_SCHEME == "sensevoice+whisper":
        if sv and wh_status == "就绪":
            return "就绪（SenseVoice + Whisper %s）" % ASR_MODEL
        if sv:
            if wh_status == "加载中":
                return "就绪（SenseVoice；Whisper 加载中）"
            if wh_status == "失败":
                return "就绪（SenseVoice；Whisper 不可用）"
            return "就绪（SenseVoice；Whisper %s）" % ws
    return ws


def self_check():
    """后台自己连一下，通不通立刻就知道（不能挡住服务接收请求）"""
    time.sleep(2)
    try:
        with _DIRECT_OPENER.open("http://127.0.0.1:%d/health" % PORT, timeout=20) as r:
            r.read(65536)
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
    """wav 字节 → (float32 ndarray 或列表, 采样率)，只取第一个声道"""
    with wave.open(io.BytesIO(data), "rb") as w:
        channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    if width not in (2, 4):
        raise ValueError("只支持 16 位或 32 位整型 PCM 的 wav")
    try:
        import numpy as np
        if width == 2:
            arr = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
        else:
            # Python wave 模块只读整型 PCM（WAVE_FORMAT_PCM），32 位即 int32
            arr = np.frombuffer(frames, dtype="<i4").astype(np.float32) / 2147483648.0
        if channels > 1:
            arr = np.ascontiguousarray(arr[::channels])
        return arr, rate
    except ImportError:
        import array
        if width == 2:
            a = array.array("h")
            a.frombytes(frames)
            samples = [x / 32768.0 for x in a]
        else:
            a = array.array("i")
            a.frombytes(frames)
            samples = [x / 2147483648.0 for x in a]
        if channels > 1:
            samples = samples[::channels]
        return samples, rate


# Whisper 修正最多等这么久（秒）。
# 慢引擎卡住不能把整句话拖死：超时就先用 SenseVoice 的快结果。
CORRECT_TIMEOUT = float(os.environ.get("HEAR_CORRECT_TIMEOUT", "8"))


# A timed-out correction still owns the slot until the underlying model returns.
_correction_slot = threading.Lock()


def run_with_timeout(fn, seconds):
    from concurrent.futures import Future
    if not _correction_slot.acquire(blocking=False):
        raise TimeoutError("已有校正正在运行")
    result = Future()

    def correct():
        try:
            value = fn()
        except BaseException as error:
            _correction_slot.release()
            result.set_exception(error)
        else:
            _correction_slot.release()
            result.set_result(value)

    worker = threading.Thread(target=correct, daemon=True, name="hear-asr-correction")
    try:
        worker.start()
    except RuntimeError:
        _correction_slot.release()
        raise
    return result.result(timeout=max(0, seconds))


def parse_asr_hotwords(raw):
    """解析客户端通过 X-ASR-Hotwords 传入的术语表热词（支持 URL 编码的 UTF-8 中文/英文专有名词）。"""
    if not raw:
        return None
    import re
    try:
        decoded = urllib.parse.unquote(str(raw))
    except Exception:
        decoded = str(raw)
    seen = set()
    terms = []
    total_len = 0
    for part in re.split(r"[,;\n|，；]+", decoded):
        term = part.strip()
        if not term:
            continue
        key = term.lower()
        if key in seen:
            continue
        if len(terms) >= 32 or total_len + len(term) > 512:
            break
        seen.add(key)
        terms.append(term)
        total_len += len(term) + 2
    return ", ".join(terms) if terms else None


def deferred_whisper(samples, rate, language, fallback, hotwords=None):
    def _run():
        # 后台精修阶段（X-ASR-Stage: correct）使用 beam_size=5 + 术语表热词提升准确率；
        # 兼容外部测试桩按旧 4 参数签名 monkeypatch whisper_transcribe 的场景
        try:
            return whisper_transcribe(samples, rate, language, fallback, beam_size=5, hotwords=hotwords)
        except TypeError:
            try:
                return whisper_transcribe(samples, rate, language, fallback, beam_size=5)
            except TypeError:
                return whisper_transcribe(samples, rate, language, fallback)
    try:
        return run_with_timeout(_run, CORRECT_TIMEOUT)
    except TimeoutError:
        return "", fallback


def recognize(samples, rate, language, fallback, scheme=None, preview=False,
              log_content=False, hotwords=None):
    """按方案选识别：
       whisper              只用 Whisper
       sensevoice           只用 SenseVoice
       sensevoice+whisper   SenseVoice 先出，Whisper 再修正
    preview = True 时只要快，不要跑 Whisper 修正（实时预览用）
    返回 (语言, 文字)"""
    scheme = (scheme or ASR_SCHEME or "whisper").strip().lower()
    # 注意：这里统一返回 (文字, 语言)

    if scheme == "sensevoice":
        # 用户选的就是"只用 SenseVoice"：不要偷偷去调 Whisper。
        # （要两个都用是另一个选项：sensevoice+whisper）
        # 以前这里"没听出来就退回去试 Whisper"，
        # 结果是：用户明明选了只用 SenseVoice，机器上却还在跑 Whisper——
        # 既慢，又让人以为选项没生效。
        sv_lang, sv_text = sensevoice_transcribe(samples, rate)
        return (sv_text, sv_lang or fallback)

    if scheme == "sensevoice+whisper":
        # 先用 SenseVoice 快速出结果（快）
        fast_lang, fast_text = sensevoice_transcribe(samples, rate)
        # 实时预览只要快，不跑 Whisper 修正
        if preview:
            return (fast_text, fast_lang or fallback)
        # 再用 Whisper 修正（准）
        # 修正失败也要保住已经有的结果：慢引擎出错不能把整句话弄丢
        try:
            def _run_whisper():
                try:
                    return whisper_transcribe(samples, rate, language, fallback, hotwords=hotwords)
                except TypeError:
                    return whisper_transcribe(samples, rate, language, fallback)
            slow_text, slow_lang = run_with_timeout(
                _run_whisper,
                CORRECT_TIMEOUT)
        except TimeoutError:
            # 修正太慢：先用快结果，别把这一句拖死
            log("Whisper 修正超过 %.0f 秒，先用 SenseVoice 的结果" % CORRECT_TIMEOUT)
            return (fast_text, fast_lang or fallback)
        except Exception as e:
            log("Whisper 修正失败，先用 SenseVoice 的结果：%s" % e)
            return (fast_text, fast_lang or fallback)
        if not slow_text:
            return (fast_text, fast_lang or fallback)
        if not fast_text:
            return (slow_text, slow_lang or fallback)
        # 两个结果不一样就以 Whisper 为准，一样就用 SenseVoice 的（更快）
        if fast_text != slow_text:
            log_text("Whisper 修正：「", "%s」→「%s」" % (fast_text[:30], slow_text[:30]),
                     enabled=log_content)
            return (slow_text, slow_lang or fast_lang or fallback)
        return (fast_text, fast_lang or slow_lang or fallback)

    # 默认：只用 Whisper
    try:
        return whisper_transcribe(samples, rate, language, fallback, hotwords=hotwords)
    except TypeError:
        return whisper_transcribe(samples, rate, language, fallback)


def whisper_transcribe(samples, rate, language, fallback, beam_size=1, hotwords=None):
    """只用 faster-whisper 识别"""
    model = get_whisper()
    # 必须给 numpy 的 float32 数组：
    # faster-whisper 只有在拿到 ndarray 时才跳过重新解码，
    # 给普通 list 它会当成文件去 av.open()，老版本 av 会直接报
    # "open() got an unexpected keyword argument 'metadata_errors'"。
    audio = to_float32(samples, rate)
    kwargs = {
        "language": language,
        "beam_size": beam_size,
        "vad_filter": True,
        "vad_parameters": {"min_speech_duration_ms": 100, "min_silence_duration_ms": 300},
        "condition_on_previous_text": False,
    }
    if hotwords:
        kwargs["hotwords"] = hotwords
    # faster-whisper 的 segments 是惰性迭代器；锁必须覆盖迭代全过程。
    with _whisper_inference_lock:
        try:
            segments, info = model.transcribe(audio, **kwargs)
        except TypeError:
            kwargs.pop("hotwords", None)
            segments, info = model.transcribe(audio, **kwargs)
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
    with _DIRECT_OPENER.open(req, timeout=timeout) as resp:
        raw = resp.read(MAX_BACKEND_JSON_BYTES + 1)
        if len(raw) > MAX_BACKEND_JSON_BYTES:
            raise urllib.error.URLError("backend response exceeds size limit")
        return raw


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
        with _DIRECT_OPENER.open(key + "/health", timeout=1.5) as resp:
            resp.read(65536)
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


_backend_model_cache = {}


def backend_model(url):
    """后端跑的是哪个模型（从 llama-server 的 /props 里拿，结果缓存 10 秒）

    这个很要紧：Windows 上如果上一个窗口没关干净，
    127.0.0.1:8082 上可能还留着旧的 llama-server。
    总服务走 127.0.0.1，手机走局域网地址，两边连到的不是同一个实例，
    表现就会对不上（克隆出来是乱的，还慢十倍）。
    把模型名报出来，一眼就能看出连的是哪个。
    """
    key = url.rstrip("/")
    now = time.time()
    hit = _backend_model_cache.get(key)
    if hit and now - hit[0] < 10:
        return hit[1]
    name = ""
    try:
        with _DIRECT_OPENER.open(key + "/props", timeout=3) as resp:
            obj = json.loads(resp.read(262144).decode("utf-8"))
        path = obj.get("model_path") or ""
        name = path.replace("\\", "/").split("/")[-1]
    except Exception:
        name = ""
    _backend_model_cache[key] = (now, name)
    return name


# ---------------------------------------------------------------- HTTP

# 参考音频缓存：同一段参考音频只从客户端传一次，后面每句话只带一个 id。
# 按调用方隔离归属、限制单条最大 8 MB、采用 LRU 最多缓存 32 条并缓存 base64 避免重复编码。
MAX_REF_WAV_BYTES = 8 * 1024 * 1024
MAX_REF_CACHE_ITEMS = 32
_REF_CACHE = {}   # rid -> {"owner": str, "b64": str, "size": int}
_REF_ORDER = []
_REF_LOCK = threading.Lock()


def ref_put(wav_bytes, owner=""):
    rid = os.urandom(8).hex()
    b64 = base64.b64encode(wav_bytes).decode("ascii")
    with _REF_LOCK:
        _REF_CACHE[rid] = {"owner": owner, "b64": b64, "size": len(wav_bytes)}
        _REF_ORDER.append(rid)
        while len(_REF_ORDER) > MAX_REF_CACHE_ITEMS:
            old = _REF_ORDER.pop(0)
            _REF_CACHE.pop(old, None)
    return rid


def ref_get(rid, owner=""):
    with _REF_LOCK:
        entry = _REF_CACHE.get(rid)
        if not entry:
            return None
        if entry["owner"] and owner and entry["owner"] != owner:
            return None
        if rid in _REF_ORDER:
            _REF_ORDER.remove(rid)
            _REF_ORDER.append(rid)
        return entry["b64"]


class Handler(RequestHandler):
    pairing_info = staticmethod(lambda: pair_info())

    server_version = "HearCloud/1.0"
    # 用 HTTP/1.1：手机那边能复用同一个连接，
    # 不用每发一个请求就重新做一次 TLS 握手（握手多最容易出"卡住"）
    protocol_version = "HTTP/1.1"
    timeout = 65            # 空闲连接挂 65 秒就收掉

    def log_message(self, fmt, *args):
        # 请求行里可能有二进制（TLS 握手打到 http 端口时就是一堆乱码），
        # 直接打进日志会看不清。这里判断一下：不是正常的 ASCII 请求行就整条换成提示。
        text = fmt % args
        if all((32 <= ord(c) < 127) or c in "\r\n\t" for c in text):
            log(text)
        else:
            log("收到一段二进制内容（不是 HTTP 请求），已忽略")

    @staticmethod
    def log_notice(message):
        log(message)

    # -- 工具 --

    def _send_json(self, obj, code=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            # 响应里可能有口令状态和到期时间：任何一层都不缓存
            self.send_header("Cache-Control", "no-store")
            if self.close_connection:
                self.send_header("Connection", "close")
            if code == 503:
                busy_auth = isinstance(obj, dict) and obj.get("code") == "AUTH_SERVICE_UNAVAILABLE"
                self.send_header("Retry-After", "5" if busy_auth else "1")
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError) as e:
            # 手机那边断开了（等太久放弃、App 被切走、网断了）：
            # 这种时候回什么都送不到，记一笔就行，别刷一屏堆栈
            log("客户端已断开（%s）：%s" % (type(e).__name__, e))

    def _send_wav(self, wav, code=200):
        """直接发 wav 原始数据（手机端要原始音频时用，省掉 base64，内存小很多）"""
        try:
            self.send_response(code)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(wav)))
            self.end_headers()
            self.wfile.write(wav)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError) as e:
            # 手机等不及先断了（见 _send_json 的说明）
            log("客户端已断开（%s）：%s" % (type(e).__name__, e))

    def _error(self, msg, code=400, error_code=None):
        # error 是现有 App 读的字段；code / message / request_id 是统一错误体
        message = str(msg)
        self._send_json({"error": message, "code": error_code or ERROR_CODES.get(code, "ERROR"),
                         "message": message, "request_id": self.request_id}, code)

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
        revision = os.environ.get("HEAR_SERVER_REVISION", "")
        if revision:
            out["server_revision"] = revision
        if ASR_URL:
            out["asr"] = "外部服务" if backend_alive(ASR_URL) else "外部服务连不上"
        else:
            out["asr"] = asr_status_text()
            out["asr_scheme"] = ASR_SCHEME
        mt_state = backend_state(MT_URL)
        out["mt"] = mt_state
        if mt_state == "连不上":
            out["mt"] = "连不上（%s）" % MT_URL
        # 把后端跑的是哪个模型报出来：启动时可以让用户按类型选大模型，
        # 手机上要能一眼看出"电脑上现在跑的是哪个"
        if not ASR_URL:
            # 这台电脑上识别方面有什么（Whisper 型号、SenseVoice 装没装、能选哪些方案）
            # App 的识别方案列表就是照着这个来的
            cap = asr_capabilities()
            out["asr_model"] = cap["whisper_model"]
            out["sensevoice"] = cap["sensevoice"]
            out["asr_whisper"] = cap["whisper"]
            out["asr_schemes"] = cap["schemes"]
        if mt_state != "连不上":
            mt_model = backend_model(MT_URL)
            if mt_model:
                out["mt_model"] = mt_model
        clone_state = backend_state(CLONE_URL)
        clone_model_valid = True
        out["clone"] = clone_state
        if out["clone"] == "连不上":
            out["clone"] = "连不上（%s）" % CLONE_URL
        else:
            # 把后端跑的是哪个模型报出来
            m = backend_model(CLONE_URL)
            if m:
                out["clone"] += "（%s）" % m
                out["clone_model"] = m
                if "tts" not in m.lower():
                    clone_model_valid = False
                    out["clone"] = "模型不匹配（%s，需要 Qwen3-TTS）" % m
        # 机器能判定的就绪状态（启动脚本、App 都看这个）：
        # 别去猜"就绪""外部服务"这些字——
        # "外部服务连不上"开头也是"外部服务"，按字面判就会把连不上的当成能用。
        out["speaker_ready"] = SPEAKER.available
        if ASR_URL:
            out["asr_ready"] = backend_alive(ASR_URL)
        else:
            whisper_ready = _whisper_state.get("status", "") == "就绪"
            if ASR_SCHEME == "sensevoice":
                out["asr_ready"] = sensevoice_available()
            elif ASR_SCHEME == "sensevoice+whisper":
                out["asr_ready"] = sensevoice_available() or whisper_ready
            else:
                out["asr_ready"] = whisper_ready
        out["mt_ready"] = (mt_state == "就绪")
        out["clone_ready"] = (clone_state == "就绪" and clone_model_valid)
        out["edge_tts_ready"] = edge_tts_available()
        out["clone_engines"] = ["qwen3", "edge_tts"]
        # 桌面端与多端共享能力元信息（向后兼容旧版 iOS）
        out["bind_host"] = HOST
        out["lan_shared"] = HOST not in ("127.0.0.1", "::1", "localhost")
        out["capabilities"] = {
            "streaming_mt": True,
            "per_device_preview": True,
            "local_secret": bool(LOCAL_SECRET),
        }
        # 口令服务是否就绪：auth_ready=false 时网关可达，但需要鉴权的请求会返回 503
        if AUTH is not None:
            out.update(AUTH.health())
        else:
            out["auth_mode"] = AUTH_MODE
            out["auth_ready"] = True
        return out

    def send_error(self, code, message=None, explain=None):
        # 400 多半是 https 的 TLS 握手打到了 http 的解析器（服务没生成证书），
        # 说清楚一点，不然日志里一堆乱码看不懂
        if code == 400 and message and "Bad request version" in str(message):
            message = ("这个不是 HTTP 请求：多半是 https 的 TLS 握手打到了这里。"
                       "服务没有证书（server/certs/cert.pem），"
                       "跑一次 python server/make_cert.py 生成，再重启服务")
        super().send_error(code, message, explain)

    # -- 语音识别 --

    def asr(self, body):
        langs = [x.strip() for x in (self.headers.get("X-Languages") or "").split(",") if x.strip()]
        fallback = self.headers.get("X-Fallback-Language") or ""
        log_content = request_logs_content(self.headers)
        # 手机可以临时指定用哪个方案（不带就用服务默认的）
        scheme = (self.headers.get("X-ASR-Scheme") or "").strip().lower()
        if scheme not in ("whisper", "sensevoice", "sensevoice+whisper"):
            scheme = ASR_SCHEME
        t0 = time.time()
        can_correct = False
        if ASR_URL:
            text, lang = self.asr_proxy(body, langs, fallback)
        else:
            try:
                samples, rate = decode_wav(body)
            except Exception as e:
                # 音频格式不对：这是请求的问题（400），不是服务崩了（500）。
                # 手机发错了格式的时候，要能一眼看出是哪边的问题。
                self._error("音频格式不对：%s（要 16 位 wav）" % e, 400)
                return
            language = langs[0] if len(langs) == 1 else None
            # 预览只要快：组合方案下只用 SenseVoice，不跑 Whisper 修正
            preview = (self.headers.get("X-ASR-Preview") or "").strip() == "1"
            stage = self.headers.get("X-ASR-Stage", "")
            hotwords = parse_asr_hotwords(self.headers.get("X-ASR-Hotwords", ""))
            if not preview and scheme == "sensevoice+whisper" and stage == "correct":
                text, lang = deferred_whisper(samples, rate, language, fallback, hotwords=hotwords)
            elif not preview and scheme == "sensevoice+whisper" and stage == "first":
                lang, text = sensevoice_transcribe(samples, rate)
                can_correct = bool(text)
                if not text:
                    text, lang = deferred_whisper(samples, rate, language, fallback, hotwords=hotwords)
            else:
                text, lang = recognize(samples, rate, language, fallback, scheme, preview,
                                       log_content=log_content, hotwords=hotwords)
        log_text("识别（%s）%.1fs：" % (scheme, time.time() - t0), text[:40],
                 enabled=log_content)
        self._send_json({"lang": lang or fallback, "text": text, "can_correct": can_correct,
                         "speaker_available": SPEAKER.available})

    def speaker(self, body):
        try:
            samples, rate = decode_wav(body)
        except (EOFError, ValueError, wave.Error, struct.error):
            self._error("无效的说话人识别音频", 400)
            return
        try:
            embedding = SPEAKER.embedding(samples, rate)
        except Exception as error:
            log("说话人模型暂不可用：%s" % type(error).__name__)
            embedding = None
        self._send_json({"embedding": embedding})

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
        with _DIRECT_OPENER.open(req, timeout=300) as resp:
            obj = json.loads(resp.read(MAX_BACKEND_JSON_BYTES).decode("utf-8"))
        return obj.get("text", ""), obj.get("language", fallback)

    # -- 文本翻译 --

    def _translate_stream(self, payload, timeout, log_content):
        target = urlsplit(MT_URL + "/v1/chat/completions")
        if target.scheme not in ("http", "https") or not target.hostname:
            self._error("翻译后端地址不合法", 502)
            return
        factory = HTTPSConnection if target.scheme == "https" else HTTPConnection
        conn = factory(target.hostname, target.port, timeout=timeout)
        t0 = time.time()
        collected = []
        headers_sent = False
        try:
            body_bytes = json.dumps(payload).encode("utf-8")
            path = target.path or "/v1/chat/completions"
            if target.query:
                path += "?" + target.query
            conn.request("POST", path, body=body_bytes,
                         headers={"Content-Type": "application/json", "Accept": "text/event-stream"})
            resp = conn.getresponse()
            if not 200 <= resp.status < 300:
                detail = resp.read(500).decode("utf-8", "replace")
                self._error("后端返回 %s：%s" % (resp.status, detail), 502)
                return
            self.close_connection = True
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            headers_sent = True

            while True:
                raw_line = resp.readline(65536)
                if not raw_line:
                    break
                line = raw_line.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data_str = line[5:].strip()
                if not data_str:
                    continue
                if data_str == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                except ValueError:
                    continue
                choices = chunk.get("choices") or []
                if not choices or not isinstance(choices[0], dict):
                    continue
                delta_obj = choices[0].get("delta") or choices[0].get("message") or {}
                piece = delta_obj.get("content") if isinstance(delta_obj, dict) else None
                if isinstance(piece, str) and piece:
                    collected.append(piece)
                    event = ("data: %s\n\n" % json.dumps({"delta": piece, "done": False}, ensure_ascii=False)).encode("utf-8")
                    self.wfile.write(event)
                    self.wfile.flush()

            full_text = "".join(collected)
            done_event = ("data: %s\n\n" % json.dumps({"text": full_text, "done": True}, ensure_ascii=False)).encode("utf-8")
            self.wfile.write(done_event)
            self.wfile.flush()
            log_text("流式翻译 %.1fs：" % (time.time() - t0), full_text[:40], enabled=log_content)
        except TimeoutError:
            if not headers_sent:
                raise
            try:
                err_ev = ("data: %s\n\n" % json.dumps({"error": "翻译响应超时", "done": True}, ensure_ascii=False)).encode("utf-8")
                self.wfile.write(err_ev)
                self.wfile.flush()
            except OSError:
                pass
        finally:
            conn.close()

    def translate(self, body):
        log_content = request_logs_content(self.headers)
        try:
            req = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            self._error("翻译请求不是有效的 JSON", 400)
            return
        if not isinstance(req, dict):
            self._error("翻译请求体必须是 JSON 对象", 400)
            return
        prompt = req.get("prompt", "")
        if not isinstance(prompt, str):
            self._error("prompt 必须是字符串", 400)
            return
        preview = self.headers.get("X-MT-Preview", "").strip() == "1"
        accept_sse = "text/event-stream" in (self.headers.get("Accept") or "").lower()
        want_stream = bool(req.get("stream") is True or accept_sse)
        raw_max = req.get("max_tokens", 256 if preview else 512)
        try:
            max_tokens = int(raw_max)
        except (TypeError, ValueError):
            self._error("max_tokens 必须是整数", 400)
            return
        max_tokens = max(1, min(max_tokens, 256 if preview else 2048))
        sampling = resolve_mt_sampling_params()
        payload = {
            "messages": [{"role": "user", "content": prompt}],
            "stream": want_stream,
            "max_tokens": max_tokens,
            "top_k": sampling["top_k"],
            "top_p": sampling["top_p"],
            "temperature": sampling["temperature"],
            "repeat_penalty": sampling["repeat_penalty"],
        }
        if want_stream:
            try:
                self._translate_stream(payload, timeout=6 if preview else 300, log_content=log_content)
            except TimeoutError:
                if not preview:
                    raise
                self._error("翻译预览暂不可用，请稍后重试", 503)
            return
        t0 = time.time()
        try:
            raw = http_json(MT_URL + "/v1/chat/completions", payload, timeout=6 if preview else 300)
        except TimeoutError:
            if not preview:
                raise
            self._error("翻译预览暂不可用，请稍后重试", 503)
            return
        except urllib.error.URLError as err:
            if preview and isinstance(err.reason, TimeoutError):
                self._error("翻译预览暂不可用，请稍后重试", 503)
                return
            raise
        try:
            obj = json.loads(raw.decode("utf-8"))
            choices = obj.get("choices") or []
            msg = choices[0].get("message") if choices and isinstance(choices[0], dict) else None
            text = msg.get("content") if isinstance(msg, dict) else None
            if not isinstance(text, str):
                raise ValueError("missing content")
        except (UnicodeDecodeError, ValueError, KeyError, IndexError, TypeError):
            self._error("翻译后端返回格式异常", 502)
            return
        log_text("翻译 %.1fs：" % (time.time() - t0), text[:40], enabled=log_content)
        self._send_json({"text": text})

    # -- 声音克隆 --

    def _caller_owner(self):
        """用于隔离参考音频缓存的调用方标识（口令哈希优先，否则客户端 IP）。"""
        import hashlib
        tok = (self.headers.get("X-Hear-Token") or "").strip()
        if tok:
            return "tok:" + hashlib.sha256(tok.encode("utf-8")).hexdigest()[:16]
        return "ip:" + (self.client_address[0] if self.client_address else "")

    def clone_reference(self, body):
        """存一段参考音频，返回一个 id；后面的克隆请求只带 id 就行。"""
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype == "audio/wav":
            wav = body
        else:
            try:
                req = json.loads(body.decode("utf-8"))
            except Exception:
                self._error("参考音频格式不对", 400)
                return
            if not isinstance(req, dict):
                self._error("参考音频请求体必须是 JSON 对象", 400)
                return
            b64 = req.get("reference_wav", "")
            if not isinstance(b64, str):
                self._error("reference_wav 必须是字符串", 400)
                return
            try:
                wav = base64.b64decode(b64) if b64 else b""
            except Exception:
                self._error("参考音频不是合法的 base64", 400)
                return
        if not wav:
            self._error("参考音频是空的", 400)
            return
        if len(wav) > MAX_REF_WAV_BYTES:
            self._error("参考音频超过 8 MB 上限", 413)
            return
        rid = ref_put(wav, owner=self._caller_owner())
        log("参考音频已存：%s（%d 字节）" % (rid, len(wav)))
        self._send_json({"id": rid})

    def clone(self, body):
        started = time.monotonic()
        try:
            req = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            # 手机把 wav 二进制发到这个接口来了（老版本服务没有
            # /v1/clone/reference，路径会落到这里）：说清楚，别抛一屏乱码
            self._error("这个接口要的是 JSON（不是 wav）", 400)
            return
        if not isinstance(req, dict):
            self._error("克隆请求体必须是 JSON 对象", 400)
            return
        # 参考音频：先传过一次（/v1/clone/reference），
        # 后面每句话只带 reference_id，不用再传几百 KB。
        ref_b64 = ""
        rid = req.get("reference_id") or ""
        if rid and not isinstance(rid, str):
            self._error("reference_id 必须是字符串", 400)
            return
        if rid:
            cached_b64 = ref_get(rid, owner=self._caller_owner())
            if cached_b64:
                ref_b64 = cached_b64
            else:
                # 服务重启过，缓存里的参考音频没了：让客户端重新传一次
                log("参考音频 id 不认识：%s" % _sanitize_log_value(rid))
                self._error("参考音频 id 不认识，请重新上传", 404, error_code="REFERENCE_NOT_FOUND")
                return
        else:
            raw_ref = req.get("reference_wav", "")
            if not isinstance(raw_ref, str):
                self._error("reference_wav 必须是字符串", 400)
                return
            ref_b64 = raw_ref
        text_in = req.get("text", "")
        lang_in = req.get("lang", "")
        ref_text_in = req.get("reference_text", "")
        engine_in = (req.get("engine") or "qwen3").strip().lower()
        gender_in = (req.get("gender") or "").strip().lower()
        if not isinstance(text_in, str) or not isinstance(lang_in, str) or not isinstance(ref_text_in, str):
            self._error("text / lang / reference_text 必须是字符串", 400)
            return
        if engine_in in ("edge_tts", "edge-tts", "edge"):
            t0 = time.time()
            try:
                wav, rate, voice = edge_tts_synthesize_wav(text_in, lang_in, gender_in)
            except Exception as e:
                log("Edge-TTS 合成失败：%s" % e)
                self._error("Edge-TTS 合成失败：%s" % e, 503)
                return
            log("Edge-TTS 合成结束 %.2fs（%s）：%d 字，%d 字节，%d Hz"
                % (time.time() - t0, voice, len(text_in), len(wav), rate))
            if (self.headers.get("X-Hear-Audio") or "").strip().lower() == "wav":
                self._send_wav(wav)
                return
            self._send_json({
                "audio": base64.b64encode(wav).decode("ascii"),
                "sample_rate": rate,
            })
            return
        payload = {
            "input": text_in,
            "lang": lang_in,
            "speaker_ref_b64": ref_b64,
            "speaker_ref_text": ref_text_in,
        }
        payload = {k: v for k, v in payload.items() if v}
        # 采样参数必须和手机本地完全一致（top_k 20 / top_p 0.6 / 用模型默认温度）。
        # 不传的话 llama-server 用自己的默认值（temp 0.8 / top_k 40 / top_p 0.95），
        # 对 TTS 来说太松：念出来会跑调、还会冒出一堆杂音。
        # （翻译那条路早就照抄了手机的参数，克隆这条路以前漏了）
        payload["top_k"] = 20
        payload["top_p"] = 0.6
        payload["temperature"] = -1
        t0 = time.time()
        log("克隆 开始：%d 字，参考音频 %d 字节"
            % (len(payload.get("input", "")), len(payload.get("speaker_ref_b64", "")) * 3 // 4))
        # 后端跑的是哪个模型：不是 TTS 模型的话，出来的是一堆乱响
        m = backend_model(CLONE_URL)
        if m and "tts" not in m.lower():
            log("！！克隆后端跑的不是 TTS 模型（%s）：出来的声音会是乱的。"
                "多半是上一个窗口没关干净，端口上留着旧的 llama-server" % m)
        data = json.dumps(payload).encode("utf-8")
        limit = min(85, 30 + len(payload.get("input", "")) * 0.2)
        try:
            limit = max(1, min(limit, int(self.headers.get("X-Hear-Clone-Timeout", ""))))
        except ValueError:
            pass
        wav = clone_upstream(CLONE_URL + "/tts", data, started + limit, MAX_BODY)
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


# 已经作废的证书（SHA-256 指纹）。
# 2026-11 有一次把生成的证书和私钥误提交进了公开仓库，那把私钥已经泄露，
# 用过它的部署都必须换一张新的：这里认出它就自动重签。
REVOKED_CERT_SHA256 = {
    "1c6c08935e2f9b008514e0311cd49320fe146d5126a7dc4f0122e5b71fd62729",
}


def cert_revoked(path):
    """这个证书是不是已经作废的（私钥公开过，不能再用）"""
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes
        with open(path, "rb") as f:
            cert = x509.load_pem_x509_certificate(f.read())
        return cert.fingerprint(hashes.SHA256()).hex() in REVOKED_CERT_SHA256
    except Exception:
        return False


def cert_covers_ip():
    """现有证书里有没有这台电脑现在的所有 IP。

    换了网络、路由器重新分配了 IP、开了 VPN（Cloudflare WARP 之类），
    旧证书里就没有新地址了，手机会直接拒绝（certificate unknown）
    —— 这种时候要重新生成。
    """
    want = local_ips()
    if not want:
        return True, ""
    try:
        from cryptography import x509
        with open(TLS_CERT, "rb") as f:
            cert = x509.load_pem_x509_certificate(f.read())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        have = set()
        for name in san:
            if isinstance(name, x509.IPAddress):
                have.add(str(name.value))
        missing = [ip for ip in want if ip not in have]
        if missing:
            return False, ", ".join(missing)
        return True, ""
    except Exception:
        # 看不出来就先当没问题（别把还能用的证书弄没了）
        return True, ""


def cert_signed_by_root(path, root_cert):
    """这张服务器证书是不是签发根签出来的。

    不是的话（比如以前自己签自己的），手机上"严格模式"就认不认——
    这种要重新签一张。
    """
    try:
        from cryptography import x509
        with open(path, "rb") as f:
            pem = f.read()
        cert = x509.load_pem_x509_certificate(pem)
        if cert.issuer != root_cert.subject:
            return False
        # 新版的 cryptography 能直接验签；老版就只看签发者名字
        try:
            cert.verify_directly_issued_by(root_cert)
        except AttributeError:
            pass
        except Exception:
            return False
        return True
    except Exception:
        return False


def ensure_root(report=log):
    """这台电脑自己的签发根（长期不变）。

    服务器证书用这个根来签：换了网络、IP 变了，重新签一张就行，
    但根还是那一个——手机上配对过一次就一直认，不用重新配对。
    """
    try:
        from cryptography import x509
        from cryptography.x509.oid import NameOID
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
    except ImportError:
        return None
    try:
        os.makedirs(os.path.dirname(ROOT_CERT), exist_ok=True)
        if os.path.exists(ROOT_CERT) and os.path.exists(ROOT_KEY):
            with open(ROOT_CERT, "rb") as f:
                cert = x509.load_pem_x509_certificate(f.read())
            with open(ROOT_KEY, "rb") as f:
                key = serialization.load_pem_private_key(f.read(), password=None)
            return (cert, key)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "hear-cloud root"),
                          x509.NameAttribute(NameOID.ORGANIZATION_NAME, "hear-cloud")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(name).issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=3650))
            .add_extension(x509.BasicConstraints(ca=True, path_length=1), critical=True)
            .add_extension(x509.KeyUsage(
                digital_signature=True, content_commitment=False, key_encipherment=False,
                data_encipherment=False, key_agreement=False, key_cert_sign=True,
                crl_sign=True, encipher_only=False, decipher_only=False,
            ), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), critical=False)
            .sign(key, hashes.SHA256())
        )
        with open(ROOT_CERT, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))
        _write_private_bytes(ROOT_KEY, key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption()))
        report("签发根证书生成好了：%s" % ROOT_CERT)
        return (cert, key)
    except Exception as e:
        report("签发根证书生成失败：%s" % e)
        return None


def pair_info():
    """这台电脑的签发根信息：手机第一次配对时用。

    确认了指纹以后，以后换网络重签证书都不用重新配对。
    """
    import base64
    try:
        with open(ROOT_CERT, "rb") as f:
            pem = f.read()
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        cert = x509.load_pem_x509_certificate(pem)
        der = cert.public_bytes(serialization.Encoding.DER)
        fp = cert.fingerprint(hashes.SHA256()).hex()
        return {"root_fingerprint": ":".join(fp[i:i + 2] for i in range(0, len(fp), 2)).upper(),
                "root_der": base64.b64encode(der).decode("ascii")}
    except Exception as e:
        return {"error": "拿不到签发根：%s" % e}


def cert_has_current_server_profile(path):
    try:
        from cryptography import x509
        from cryptography.x509.oid import ExtendedKeyUsageOID
    except ImportError:
        # An already provisioned certificate can still be served.
        return True

    try:
        with open(path, "rb") as f:
            cert = x509.load_pem_x509_certificate(f.read())
        usage = cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value
        constraints = cert.extensions.get_extension_for_class(x509.BasicConstraints).value
        # Older cryptography versions expose naive UTC dates.
        since = getattr(cert, "not_valid_before_utc", None)
        until = getattr(cert, "not_valid_after_utc", None)
        if since is None:
            since = cert.not_valid_before.replace(tzinfo=datetime.timezone.utc)
            until = cert.not_valid_after.replace(tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        return (ExtendedKeyUsageOID.SERVER_AUTH in usage and not constraints.ca
                and until - since <= datetime.timedelta(days=397)
                and since <= now < until - datetime.timedelta(days=7))
    except (OSError, ValueError, x509.ExtensionNotFound):
        return False


def ensure_cert(force=False, report=log):
    """确保有服务器证书；没有就自己生成一份。

    App 只走 https，所以证书必须有。放在这里自己生成，
    就不会因为"某个文件没下载下来"而没有证书。
    """
    # 签发根先准备好：手机上的"严格模式"配对要用它
    root = ensure_root(report=report)
    if not force and os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        if cert_revoked(TLS_CERT):
            report("这张证书的私钥曾经公开过，已经作废，重新签一张")
        else:
            ok, missing = cert_covers_ip()
            if ok:
                if root and not cert_signed_by_root(TLS_CERT, root[0]):
                    # 以前签的（自己签自己），重新用签发根签一张
                    report("这张证书不是用签发根签的，重新签一张")
                elif not cert_has_current_server_profile(TLS_CERT):
                    report("更新 HTTPS 服务证书，沿用现有签发根")
                else:
                    return True
            else:
                report("本机 IP 变成 %s 了（旧证书里没有），重新生成证书" % missing)
    try:
        from cryptography import x509
        from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
    except ImportError:
        report("没有 cryptography 这个包，生成不了证书")
        report("   装一下：pip install cryptography")
        return False
    try:
        os.makedirs(os.path.dirname(TLS_CERT), exist_ok=True)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "hear-cloud")])
        # 用这台电脑的签发根来签（根没有就退回自己签自己）
        issuer = name
        signer = key
        if root:
            issuer = root[0].subject
            signer = root[1]
        ips = []
        for ip in local_ips():
            try:
                ips.append(ipaddress.ip_address(ip))
            except ValueError:
                pass
        ips.append(ipaddress.ip_address("127.0.0.1"))
        san = [x509.DNSName("localhost"), x509.DNSName("hear-cloud.local")]
        try:
            san.append(x509.DNSName(socket.gethostname()))
        except Exception:
            pass
        san += [x509.IPAddress(i) for i in ips]
        now = datetime.datetime.now(datetime.timezone.utc)
        signer_pub = root[0].public_key() if root else key.public_key()
        cert = (
            x509.CertificateBuilder()
            .subject_name(name).issuer_name(issuer)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=365))
            .add_extension(x509.SubjectAlternativeName(san), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(
                digital_signature=True, content_commitment=False, key_encipherment=True,
                data_encipherment=False, key_agreement=False, key_cert_sign=False,
                crl_sign=False, encipher_only=False, decipher_only=False,
            ), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(signer_pub), critical=False)
            .sign(signer, hashes.SHA256())
        )
        # 证书文件里带上签发根：客户端要能顺着链找到它
        pem = cert.public_bytes(serialization.Encoding.PEM)
        if root:
            pem += root[0].public_bytes(serialization.Encoding.PEM)
        with open(TLS_CERT, "wb") as f:
            f.write(pem)
        _write_private_bytes(TLS_KEY, key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption()))
        report("自签证书生成好了：%s" % TLS_CERT)
        return True
    except Exception as e:
        report("证书生成失败：%s" % e)
        return False


def make_ssl_context():
    """有自签证书就返回 TLS 上下文，没有就返回 None（只用 http）"""
    if not ensure_cert():
        return None
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
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

    【关键】偷看字节和 TLS 握手都放在【工作线程】里做，不能放在 accept 线程里。
    放在 accept 线程里的话，一个连上不吭声的客户端（或者一个握手慢的）就能把
    整个服务堵住，手机那边就表现成"卡住了"。放线程里就各干各的，互不影响。
    """

    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64     # 排队等着的连接数（手机会同时开好几个连接）

    def __init__(self, addr, handler, ssl_context=None):
        super().__init__(addr, handler)
        self.ssl_context = ssl_context
        self._conn_slots = threading.BoundedSemaphore(int(os.environ.get("HEAR_MAX_CONNECTIONS", "64")))

    def process_request(self, request, client_address):
        if not self._conn_slots.acquire(blocking=False):
            self._close(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._conn_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        # ThreadingHTTPServer 会给每个连接起一个线程跑这里，
        # 握手放在线程里做，accept 线程只管收连接
        try:
            if self.ssl_context is not None:
                request = self._wrap_tls(request)
                if request is None:
                    return
            super().process_request_thread(request, client_address)
        finally:
            self._conn_slots.release()

    def _wrap_tls(self, sock):
        """看第一个字节判断是 http 还是 https；是 https 就套上 TLS。"""
        try:
            sock.settimeout(TLS_PEEK_TIMEOUT)
            first = sock.recv(1, socket.MSG_PEEK)
        except socket.timeout:
            # 连上不说话就走了（手机偶尔会试探性地连一下又断开）
            log("有个连接连上没说话，已断开")
            self._close(sock)
            return None
        except OSError:
            self._close(sock)
            return None
        if not first:
            self._close(sock)
            return None
        if first != b"\x16":
            sock.settimeout(180)        # 普通 http（同样设个读超时）
            return sock
        try:
            wrapped = self.ssl_context.wrap_socket(sock, server_side=True)
            # 读超时：手机连上了不发数据、或者发一半就断开的，不能一直占着线程
            wrapped.settimeout(180)
            return wrapped
        except (ssl.SSLEOFError, ConnectionResetError, ConnectionAbortedError):
            # A client cancelled before the handshake completed. Keep actual TLS
            # protocol and certificate errors visible in the console.
            self._close(sock)
            return None
        except OSError as e:
            self._close(sock)
            log("TLS 握手失败：%s%s" % (e, self.tls_hint(e)))
            return None

    @staticmethod
    def tls_hint(err):
        """握手失败时补一句人话：这个错误十有八九是什么意思。"""
        if getattr(err, "reason", None) in {
            "SSLV3_ALERT_CERTIFICATE_UNKNOWN", "TLSV1_ALERT_UNKNOWN_CA",
            "SSLV3_ALERT_BAD_CERTIFICATE", "SSLV3_ALERT_CERTIFICATE_EXPIRED",
        }:
            return "（客户端未接受服务端证书，请核对当前服务地址与 HTTPS 配置）"
        return ""

    @staticmethod
    def _close(sock):
        try:
            sock.close()
        except OSError:
            pass



def main():
    global AUTH, AUTH_MODE
    try:
        mode = hear_auth.auth_mode_from_env()
    except hear_auth.AuthConfigError as error:
        raise SystemExit("鉴权配置错误：%s" % error)
    if ALLOW_LOOPBACK_HTTP and not (REQUIRE_TOKEN or mode == "managed"):
        raise SystemExit("启用本机 HTTP 回源时，必须同时启用访问口令")
    _console_log.start()
    # 先把端口占上（这样别人连过来不会报"拒绝连接"），再开始处理请求
    ctx = make_ssl_context()
    token = None
    if mode == "managed":
        if ctx is None:
            raise SystemExit("管理模式需要 HTTPS 证书（server/certs/cert.pem），明文 HTTP 推理会被拒绝")
        try:
            AUTH = hear_auth.managed_from_env(logger=log)
        except hear_auth.AuthConfigError as error:
            raise SystemExit("鉴权配置错误：%s" % error)
        AUTH_MODE = "managed"
    elif mode == "legacy" and REQUIRE_TOKEN:
        token = access_token()
        if not token or ctx is None:
            raise SystemExit("访问口令已启用，需要可用的口令文件和 HTTPS 证书")
        AUTH_MODE = "legacy"
    else:
        AUTH_MODE = "off"
    srv = MixedServer((HOST, PORT), Handler, ctx)
    srv.request_policy = RequestPolicy(MAX_BODY, int(os.environ.get("HEAR_MAX_INFLIGHT", "4")), token,
                                       allow_loopback_http=ALLOW_LOOPBACK_HTTP, authenticator=AUTH,
                                       local_secret=LOCAL_SECRET or None)
    log("服务起来了，监听 %s:%d（%s）" % (HOST, PORT, "仅本机" if HOST in ("127.0.0.1", "::1", "localhost") else "局域网共享"))
    if ALLOW_LOOPBACK_HTTP:
        log("已启用本机 HTTP 回源，仍需访问口令")
    # 签发根指纹：手机上开"严格模式"配对的时候，要对着这一串核对
    _pair = pair_info()
    if _pair.get("root_fingerprint"):
        log("证书指纹（配对时核对这一串）：%s" % _pair["root_fingerprint"])
    if AUTH is not None:
        log("口令管理模式：网关 %s，清单地址 %s（每 %d 秒同步）" % (AUTH.gateway_id, AUTH.snapshot_url,
                                                          int(AUTH.refresh_interval)))
        log("   清单加载前，推理请求返回 503；用户 Token 在管理后台签发")
        AUTH.start()
    elif token:
        log("访问口令：%s" % token)
        log("   手机上要填这个：设置 → 云端模型 → 通用服务地址 → 访问口令")
    log("本机测试：https://127.0.0.1:%d/" % PORT)
    for ip in local_ips():
        if ctx is not None:
            log("手机访问：https://%s:%d/" % (ip, PORT))
            if os.environ.get("HEAR_SHOW_VERIFIED_ADDRESS") == "1" and _pair.get("root_fingerprint"):
                digest = _pair["root_fingerprint"].replace(":", "").lower()
                log("App 专用服务地址：https://%s:%d#hear-root=%s" % (ip, PORT, digest))
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
    if not ASR_URL and ASR_SCHEME != "sensevoice":
        threading.Thread(target=preload_whisper, daemon=True).start()
    threading.Thread(target=preload_edge_tts, daemon=True).start()
    threading.Thread(target=warm_backends, daemon=True).start()
    threading.Thread(target=self_check, daemon=True).start()
    def _handle_sigterm(signum, frame):
        threading.Thread(target=srv.shutdown, daemon=True).start()

    try:
        signal.signal(signal.SIGTERM, _handle_sigterm)
    except (ValueError, OSError, AttributeError):
        pass
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("停了")
    finally:
        if AUTH is not None:
            AUTH.stop()
        srv.server_close()


if __name__ == "__main__":
    with console_without_quick_edit():
        main()
