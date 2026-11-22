#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 branding/icon/part0..5.b64 还原桌面端源图标 PNG（及基础 ICO 兜底）。"""

import base64
import os
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRANDING_DIR = os.path.join(ROOT, "branding", "icon")
ICONS_DIR = os.path.join(ROOT, "desktop", "src-tauri", "icons")


def write_png_ico(png_bytes, out_path):
    """封装单帧 PNG-in-ICO（Windows Vista+ 及 NSIS 原生支持）。"""
    # ICONDIR: reserved(2), type=1(2), count=1(2)
    header = struct.pack("<HHH", 0, 1, 1)
    # ICONDIRENTRY: width(1, 0=256), height(1, 0=256), colors(1), reserved(1),
    # planes(2), bpp(2), size(4), offset(4)
    entry = struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png_bytes), 6 + 16)
    with open(out_path, "wb") as f:
        f.write(header + entry + png_bytes)


def main():
    os.makedirs(ICONS_DIR, exist_ok=True)
    raw_b64 = ""
    for i in range(6):
        part = os.path.join(BRANDING_DIR, "part%d.b64" % i)
        with open(part, "r", encoding="utf-8") as f:
            raw_b64 += f.read()
    png_bytes = base64.b64decode(raw_b64)
    if png_bytes[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("解码后的图标不是有效的 PNG")

    icon_png = os.path.join(ICONS_DIR, "icon.png")
    with open(icon_png, "wb") as f:
        f.write(png_bytes)

    # 兜底生成基础 PNG 与 ICO；CI 中会再运行 `npx tauri icon` 生成全套多分辨率图标
    for name in ("32x32.png", "128x128.png", "128x128@2x.png"):
        with open(os.path.join(ICONS_DIR, name), "wb") as f:
            f.write(png_bytes)
    write_png_ico(png_bytes, os.path.join(ICONS_DIR, "icon.ico"))
    print("Desktop icon prepared:", icon_png, "(%d bytes)" % len(png_bytes))


if __name__ == "__main__":
    main()
