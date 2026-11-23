# -*- coding: utf-8 -*-
"""在 Windows 上直接测本机的云端服务（不用手机、不用 App）。

用来分清楚"是服务端的问题还是 App 的问题"：

    python test_api.py health
    python test_api.py clone --wav 参考.wav --text "Hello, this is a test."
    python test_api.py translate --text "你好，今天天气怎么样？"
    python test_api.py asr --wav 参考.wav
    python test_api.py all --wav 参考.wav --text "Hello, this is a test."

声音克隆要两个东西：
    · --wav  一段中文的声音（参考音频，wav 格式，16 位 PCM）
    · --text 要用这个声音念出来的文字（这里是英文）

克隆成功会把生成的音频存成 clone_out.wav，直接双击就能听。
"""
import argparse
import json
import os
import ssl
import struct
import sys
import time
import urllib.error
import urllib.request
import wave

DEFAULT_URL = "https://127.0.0.1:8000"


# ---------------------------------------------------------------- 工具

def say(msg):
    print(msg, flush=True)


def make_ctx(insecure=True):
    """自签证书的 https：默认不校验证书（服务用的是自己签的证书）"""
    ctx = ssl.create_default_context()
    if insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def request(url, method="GET", body=None, headers=None, timeout=900, insecure=True,
            content_type="application/json"):
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Content-Type", content_type)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=make_ctx(insecure)) as resp:
            data = resp.read()
            return resp.status, data, time.time() - t0
    except urllib.error.HTTPError as e:
        data = e.read()
        return e.code, data, time.time() - t0
    except Exception as e:
        return 0, str(e).encode("utf-8"), time.time() - t0


# ---------------------------------------------------------------- wav

def read_wav_mono16k(path):
    """读 wav，转成 16 位单声道 16k 的采样（App 传给服务的就是这种）"""
    with wave.open(path, "rb") as w:
        nch = w.getnchannels()
        sw = w.getsampwidth()
        rate = w.getframerate()
        total = w.getnframes()
        raw = w.readframes(total)
    if sw != 2:
        raise SystemExit("参考音频要 16 位的 wav（现在这个是 %d 位），手机录音机导出的就是 16 位" % (sw * 8))
    # 多声道 → 取第一个声道
    if nch > 1:
        vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
        vals = vals[0::nch]
        raw = struct.pack("<%dh" % len(vals), *vals)
    # 重采样到 16k（线性插值，够用）
    if rate != 16000:
        vals = list(struct.unpack("<%dh" % (len(raw) // 2), raw))
        n = len(vals)
        if n > 0:
            step = rate / 16000.0
            m = int(n / step)
            out = []
            for i in range(m):
                x = i * step
                i0 = int(x)
                i1 = min(i0 + 1, n - 1)
                f = x - i0
                out.append(int(vals[i0] * (1 - f) + vals[i1] * f))
            raw = struct.pack("<%dh" % len(out), *out)
        rate = 16000
    return raw, rate


def make_wav(raw, rate=16000):
    """把 16 位单声道 PCM 装成 wav 容器（App 传给服务的就是这种）"""
    import io as _io
    buf = _io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(raw)
    return buf.getvalue()


def wav_duration(data):
    """wav 原始数据里读出时长（秒）"""
    if len(data) < 44 or data[:4] != b"RIFF":
        return 0.0
    pos = 12
    rate, ch, bits = 16000, 1, 16
    length = 0
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b"fmt " and body + 16 <= len(data):
            ch = struct.unpack("<H", data[body + 2:body + 4])[0] or 1
            rate = struct.unpack("<I", data[body + 4:body + 8])[0]
            bits = struct.unpack("<H", data[body + 14:body + 16])[0]
        elif cid == b"data":
            length = min(size, len(data) - body)
            break
        pos = body + size + (size % 2)
    if bits != 16 or rate <= 0:
        return 0.0
    return length / 2.0 / ch / rate


def wav_sample_rate(data):
    if len(data) < 44 or data[:4] != b"RIFF":
        return 0
    pos = 12
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b"fmt " and body + 16 <= len(data):
            return struct.unpack("<I", data[body + 4:body + 8])[0]
        if cid == b"data":
            break
        pos = body + size + (size % 2)
    return 0


# ---------------------------------------------------------------- 各个测试

def test_health(url, insecure):
    say("== 检查服务 ==")
    code, data, dt = request(url + "/health", timeout=10, insecure=insecure)
    if code != 200:
        say("   连不上：%s（%s）" % (code, data[:200].decode("utf-8", "replace")))
        return False
    try:
        info = json.loads(data.decode("utf-8"))
    except Exception:
        info = {}
    for k in sorted(info):
        say("   %-8s %s" % (k, info[k]))
    say("   服务是通的（%.2fs）" % dt)
    return True


def auth_headers(token):
    return {"X-Hear-Token": token.strip()} if token and token.strip() else None


def test_translate(url, text, insecure, token=""):
    say("== 文本翻译 ==")
    body = json.dumps({"prompt": text, "src": "zh", "dst": "en"}).encode("utf-8")
    code, data, dt = request(url + "/v1/translate", method="POST", body=body,
                             headers=auth_headers(token), timeout=180, insecure=insecure)
    if code != 200:
        say("   失败：%s %s" % (code, data[:300].decode("utf-8", "replace")))
        return False
    try:
        out = json.loads(data.decode("utf-8")).get("text", "")
    except Exception:
        out = data[:200].decode("utf-8", "replace")
    say("   %s → %s（%.2fs）" % (text, out, dt))
    return bool(out)


def test_asr(url, wav, insecure, token=""):
    say("== 语音识别 ==")
    raw, rate = read_wav_mono16k(wav)
    # 服务端要的是原始 wav（跟 App 发的一样），不是 JSON
    body = make_wav(raw, rate)
    code, data, dt = request(url + "/v1/asr", method="POST", body=body,
                             headers=auth_headers(token), timeout=600,
                             insecure=insecure, content_type="audio/wav")
    if code != 200:
        say("   失败：%s %s" % (code, data[:300].decode("utf-8", "replace")))
        return False
    try:
        out = json.loads(data.decode("utf-8")).get("text", "")
    except Exception:
        out = data[:200].decode("utf-8", "replace")
    say("   识别结果：%s（%.2fs）" % (out, dt))
    return bool(out)


def base64_of(raw):
    import base64
    return base64.b64encode(raw).decode("ascii")


def test_clone(url, wav, text, outfile, insecure, token=""):
    say("== 声音克隆（中文声音 + 英文文字）==")
    raw, rate = read_wav_mono16k(wav)
    ref_wav = make_wav(raw, rate)
    body = json.dumps({
        "text": text,
        "lang": "english",
        "reference_wav": base64_of(ref_wav),
        "reference_text": "",
    }).encode("utf-8")
    say("   参考音频：%s（%d 字节 WAV，%d Hz 单声道）" % (os.path.basename(wav), len(ref_wav), rate))
    say("   要念的文字：%s" % text)
    code, data, dt = request(url + "/v1/clone", method="POST", body=body,
                             headers=auth_headers(token), timeout=900, insecure=insecure)
    if code != 200:
        say("   失败：%s %s" % (code, data[:300].decode("utf-8", "replace")))
        return False
    # 服务有两种回法：wav 原始数据，或者 JSON（audio 是 base64）
    if data[:4] == b"RIFF":
        wav_data = data
    else:
        try:
            obj = json.loads(data.decode("utf-8"))
            wav_data = base64_decode(obj.get("audio", ""))
        except Exception as e:
            say("   回的不是音频：%s" % data[:200].decode("utf-8", "replace"))
            return False
    if not wav_data or wav_data[:4] != b"RIFF":
        say("   没拿到 wav 音频（%d 字节）" % len(wav_data))
        return False
    dur = wav_duration(wav_data)
    with open(outfile, "wb") as f:
        f.write(wav_data)
    say("   成功：%d 字节，%d Hz，%.2f 秒，用时 %.2fs" % (len(wav_data), wav_sample_rate(wav_data), dur, dt))
    say("   音频已经存成：%s（双击就能听）" % os.path.abspath(outfile))
    return True


def base64_decode(s):
    import base64
    try:
        return base64.b64decode(s)
    except Exception:
        return b""


# ---------------------------------------------------------------- 入口

def main():
    ap = argparse.ArgumentParser(description="测本机的云端服务（区分是服务的问题还是 App 的问题）")
    ap.add_argument("what", nargs="?", default="all",
                    choices=["health", "clone", "translate", "asr", "all"], help="要测哪一项")
    ap.add_argument("--url", default=DEFAULT_URL, help="服务地址（默认 %s）" % DEFAULT_URL)
    ap.add_argument("--wav", default="", help="参考音频（中文声音，16 位 wav）")
    ap.add_argument("--text", default="Hello, this is a test of the voice clone service.",
                    help="要念的文字")
    ap.add_argument("--out", default="clone_out.wav", help="克隆出来的音频存哪（默认 clone_out.wav）")
    ap.add_argument("--token", default=os.environ.get("HEAR_TOKEN", ""), help="访问口令 X-Hear-Token")
    ap.add_argument("--insecure", action="store_true", default=True, help="不校验证书（自签证书要用）")
    ap.add_argument("--verify", action="store_true", default=False, help="严格校验 HTTPS 证书")
    args = ap.parse_args()
    insecure = args.insecure and not args.verify

    url = args.url.rstrip("/")
    say("服务地址：%s" % url)
    say("")

    # 结果分三种：通过 / 失败 / 跳过。跳过的不能算"都通过了"
    passed = []
    failed = []
    skipped = []

    if args.what in ("health", "all"):
        (passed if test_health(url, insecure) else failed).append("服务状态")
        say("")

    if args.what in ("translate", "all"):
        (passed if test_translate(url, "你好，今天天气怎么样？", insecure, args.token)
         else failed).append("文本翻译")
        say("")

    if args.what in ("asr", "all"):
        if not args.wav:
            say("== 语音识别 ==")
            say("   跳过（要一个 --wav 音频文件）")
            skipped.append("语音识别")
        else:
            (passed if test_asr(url, args.wav, insecure, args.token) else failed).append("语音识别")
        say("")

    if args.what in ("clone", "all"):
        if not args.wav:
            say("== 声音克隆 ==")
            say("   跳过：要一段中文声音（--wav），才能用这个声音念英文")
            say("   例如：python test_api.py clone --wav 中文.wav --text \"Hello there\"")
            skipped.append("声音克隆")
        else:
            (passed if test_clone(url, args.wav, args.text, args.out, insecure, args.token)
             else failed).append("声音克隆")
        say("")

    # 单独测某一项、但没给必须的输入 → 直接报参数错，别装作通过了
    if args.what in ("asr", "clone") and not args.wav:
        say("结果：%s 要测%s必须给 --wav（一个 16 位 wav 文件）" %
            ("有问题" if failed else "没法测", "语音识别" if args.what == "asr" else "声音克隆"))
        return 2

    say("结果：通过 %d 项%s%s" % (
        len(passed),
        ("，失败 %d 项（%s）" % (len(failed), "、".join(failed))) if failed else "",
        ("，跳过 %d 项（%s）" % (len(skipped), "、".join(skipped))) if skipped else ""))
    if failed:
        say("      有问题（看上面哪一项失败）")
        return 1
    if skipped:
        say("      跳过的不算通过：补上 --wav 再测一次")
        return 2
    say("      都通过了（服务端没问题，问题在 App 那边）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
