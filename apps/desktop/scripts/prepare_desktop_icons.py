#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 branding/icon/part0..5.b64 还原桌面端源图标 PNG（及基础 ICO 兜底）。"""

import base64
import pathlib
import struct

DESKTOP_DIR = pathlib.Path(__file__).resolve().parent.parent
REPO_ROOT = DESKTOP_DIR.parent.parent
BRANDING_DIR = REPO_ROOT / "branding" / "icon"
ICONS_DIR = DESKTOP_DIR / "src-tauri" / "icons"


def write_png_ico(png_bytes, out_path):
    """封装单帧 PNG-in-ICO（Windows Vista+ 及 NSIS 原生支持）。"""
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png_bytes), 6 + 16)
    out_path.write_bytes(header + entry + png_bytes)


def main():
    ICONS_DIR.mkdir(parents=True, exist_ok=True)
    raw_b64 = "".join(
        (BRANDING_DIR / ("part%d.b64" % i)).read_text(encoding="utf-8")
        for i in range(6)
    )
    png_bytes = base64.b64decode(raw_b64)
    if png_bytes[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("解码后的图标不是有效的 PNG")

    icon_png = ICONS_DIR / "icon.png"
    icon_png.write_bytes(png_bytes)

    for name in ("32x32.png", "128x128.png", "128x128@2x.png"):
        (ICONS_DIR / name).write_bytes(png_bytes)
    write_png_ico(png_bytes, ICONS_DIR / "icon.ico")
    print("Desktop icon prepared:", icon_png, "(%d bytes)" % len(png_bytes))


if __name__ == "__main__":
    main()
