#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""手动检查一个网关和一串访问口令（start-hear-cloud.bat --check-token 调用）。

    python hear_check_token.py [https://hear.example.com]

口令只通过隐藏输入读取：不进命令参数、不回显、不写日志。
退出码：0 有效 / 2 网络或 TLS 不可达 / 3 缺少或无效 / 4 未生效 / 5 已到期 / 6 已撤销 /
       7 鉴权服务未就绪或接口不兼容
"""
import datetime
import getpass
import http.client
import json
import os
import socket
import ssl
import sys
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
EXIT_OK, EXIT_NETWORK, EXIT_INVALID, EXIT_NOT_STARTED, EXIT_EXPIRED, EXIT_REVOKED, EXIT_UNAVAILABLE = 0, 2, 3, 4, 5, 6, 7
CODE_EXITS = {
    "TOKEN_REQUIRED": EXIT_INVALID,
    "TOKEN_INVALID": EXIT_INVALID,
    "TOKEN_NOT_STARTED": EXIT_NOT_STARTED,
    "TOKEN_EXPIRED": EXIT_EXPIRED,
    "TOKEN_REVOKED": EXIT_REVOKED,
    "AUTH_SERVICE_UNAVAILABLE": EXIT_UNAVAILABLE,
}


class Unreachable(Exception):
    pass


def say(text=""):
    print(text, flush=True)


def local(iso):
    if not iso:
        return "—"
    try:
        moment = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return "%s（UTC %s）" % (moment.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z"), iso)
    except ValueError:
        return iso


def tls_context():
    """系统信任库 + 本机网关自己的根证书（内网自签地址也能完整校验证书和主机名）。"""
    context = ssl.create_default_context()
    # 网关自签证书没有 Authority Key Identifier；Python 3.13 起默认的严格模式会拒绝它。
    # 只放宽这条 RFC 5280 格式检查，证书链和主机名照常校验。
    context.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)
    for path in (os.environ.get("HEAR_CHECK_CA_FILE"), os.environ.get("HEAR_ROOT_CERT"),
                 os.path.join(HERE, "certs", "root.pem")):
        if path and os.path.isfile(path):
            try:
                context.load_verify_locations(cafile=path)
            except (ssl.SSLError, OSError):
                pass
    return context


def normalize(url):
    url = (url or "").strip()
    if not url:
        url = "https://127.0.0.1:%s" % os.environ.get("HEAR_PORT", "8000")
    if "://" not in url:
        url = "https://" + url
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname:
        raise ValueError("只支持 https:// 地址（口令不能经明文 HTTP 发送）")
    return parts


def request(target, path, headers=None):
    connection = http.client.HTTPSConnection(target.hostname, target.port or 443, timeout=10,
                                             context=tls_context())
    base = target.path.rstrip("/")
    try:
        connection.request("GET", base + path, headers=dict(headers or {}, **{"Accept": "application/json"}))
        response = connection.getresponse()
        body = response.read(1024 * 1024)
        try:
            data = json.loads(body.decode("utf-8")) if body else {}
        except (UnicodeDecodeError, ValueError):
            data = None
        return response.status, data
    except socket.gaierror as error:
        raise Unreachable("找不到域名 %s（DNS 解析失败：%s）" % (target.hostname, error.strerror or error))
    except ssl.SSLCertVerificationError as error:
        raise Unreachable("证书错误：%s。内网自签地址请在网关电脑上运行，或设 HEAR_CHECK_CA_FILE 指向网关根证书"
                          % (error.verify_message or error))
    except ssl.SSLError as error:
        raise Unreachable("TLS 握手失败：%s" % error)
    except ConnectionRefusedError:
        raise Unreachable("连不上 %s:%s（端口没有服务在监听，或被防火墙拦截）" % (target.hostname, target.port or 443))
    except (socket.timeout, TimeoutError):
        raise Unreachable("连接超时（%s:%s）" % (target.hostname, target.port or 443))
    except (OSError, http.client.HTTPException) as error:
        raise Unreachable("网络错误：%s" % error)
    finally:
        connection.close()


def read_token():
    if sys.stdin is None:
        return ""
    if sys.stdin.isatty():
        return getpass.getpass("  访问口令（输入不回显，回车结束）：").strip()
    # 从管道读（自动化验收用），同样不经过命令参数
    return sys.stdin.readline().strip()


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    url = argv[1] if len(argv) > 1 else os.environ.get("HEAR_CHECK_URL", "")
    if not url and sys.stdin is not None and sys.stdin.isatty():
        url = input("  目标地址（回车 = 本机 https://127.0.0.1:%s）：" % os.environ.get("HEAR_PORT", "8000"))
    try:
        target = normalize(url)
    except ValueError as error:
        say("!! %s" % error)
        return EXIT_NETWORK
    shown = "%s://%s%s" % (target.scheme, target.netloc, target.path.rstrip("/"))
    say("")
    say("== 检查 %s ==" % shown)

    # 1) 网络和模型
    try:
        status, health = request(target, "/health")
    except Unreachable as error:
        say("  网络连通：失败 —— %s" % error)
        return EXIT_NETWORK
    if status != 200 or not isinstance(health, dict):
        say("  网络连通：已连上，但 /health 返回 HTTP %d，不是听见网关" % status)
        return EXIT_UNAVAILABLE
    say("  网络连通：正常（/health 200）")
    flags = [("识别", "asr_ready"), ("翻译", "mt_ready"), ("克隆", "clone_ready")]
    say("  模型就绪：" + "  ".join("%s %s" % (name, "就绪" if health.get(key) else "未就绪") for name, key in flags))
    mode = health.get("auth_mode")
    if mode is None:
        say("  口令服务：这个网关版本没有 auth_mode 字段（还未接入托管鉴权）")
    else:
        say("  口令服务：模式 %s，%s" % (mode, "已就绪" if health.get("auth_ready") else "未就绪（推理会返回 503）"))

    # 2) 口令
    token = read_token()
    if not token:
        say("  口令状态：没有输入访问口令")
        return EXIT_INVALID
    try:
        status, data = request(target, "/v1/auth/check", {"X-Hear-Token": token})
    except Unreachable as error:
        say("  口令检查：网络失败 —— %s" % error)
        return EXIT_NETWORK
    finally:
        token = None
    data = data if isinstance(data, dict) else {}
    if status == 404:
        say("  口令检查：目标服务还未接入托管鉴权（/v1/auth/check 返回 404）")
        return EXIT_UNAVAILABLE
    if status == 200 and data.get("active") is True:
        say("  口令状态：有效")
        say("    生效时间：%s" % local(data.get("starts_at")))
        say("    计划到期：%s" % local(data.get("expires_at")))
        say("    服务器时间：%s" % local(data.get("server_time")))
        return EXIT_OK
    code = data.get("code")
    message = data.get("message") or data.get("error") or "HTTP %d" % status
    say("  口令状态：%s（%s，HTTP %d）" % (message, code or "未知", status))
    if code == "TOKEN_NOT_STARTED":
        say("    生效时间：%s" % local(data.get("starts_at")))
    elif code == "TOKEN_EXPIRED":
        say("    到期时间：%s" % local(data.get("invalidated_at") or data.get("expires_at")))
    elif code == "TOKEN_REVOKED":
        say("    失效时间：%s（请联系管理员）" % local(data.get("invalidated_at")))
    if data.get("request_id"):
        say("    request_id：%s" % data["request_id"])
    return CODE_EXITS.get(code, EXIT_UNAVAILABLE)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        say("\n已取消")
        sys.exit(EXIT_INVALID)
