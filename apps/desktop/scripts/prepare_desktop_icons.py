#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 branding/icon/part0..5.b64 还原桌面端源图标 PNG、基础 ICO 及 NSIS 安装向导品牌位图。"""

import base64
import pathlib
import struct
import zlib

DESKTOP_DIR = pathlib.Path(__file__).resolve().parent.parent
REPO_ROOT = DESKTOP_DIR.parent.parent
BRANDING_DIR = REPO_ROOT / "branding" / "icon"
ICONS_DIR = DESKTOP_DIR / "src-tauri" / "icons"


def write_png_ico(png_bytes, out_path):
    """封装单帧 PNG-in-ICO（Windows Vista+ 及 NSIS 兜底，CI 中会再由 tauri icon 生成多分辨率 ICO）。"""
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png_bytes), 6 + 16)
    out_path.write_bytes(header + entry + png_bytes)


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def decode_png_rgb(png_bytes):
    """使用 Python 标准库解码非隔行 8-bit PNG（支持索引色 / RGB / RGBA）为 (w, h, rgb_bytes)。"""
    pos = 8
    width = height = bit_depth = color_type = 0
    palette = None
    idat = bytearray()
    while pos + 8 <= len(png_bytes):
        length, ctype = struct.unpack(">I4s", png_bytes[pos:pos + 8])
        data = png_bytes[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", data)
            if bit_depth != 8 or interlace != 0 or color_type not in (2, 3, 6):
                raise ValueError(f"Unsupported PNG format: bd={bit_depth}, ct={color_type}, interlace={interlace}")
        elif ctype == b"PLTE":
            palette = data
        elif ctype == b"IDAT":
            idat.extend(data)
        elif ctype == b"IEND":
            break

    bpp = {2: 3, 3: 1, 6: 4}[color_type]
    stride = width * bpp
    raw = zlib.decompress(bytes(idat))
    prev = bytearray(stride)
    rgb = bytearray(width * height * 3)

    idx = 0
    for y in range(height):
        flt = raw[idx]
        idx += 1
        row = bytearray(raw[idx:idx + stride])
        idx += stride
        if flt == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif flt == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif flt == 3:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif flt == 4:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                up = prev[i]
                up_left = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + _paeth(left, up, up_left)) & 0xFF
        prev = row

        out_base = y * width * 3
        if color_type == 3:
            for x in range(width):
                p = row[x] * 3
                o = out_base + x * 3
                rgb[o:o + 3] = palette[p:p + 3]
        elif color_type == 2:
            rgb[out_base:out_base + width * 3] = row
        else:  # RGBA -> composite over dark teal if alpha < 255
            for x in range(width):
                s = x * 4
                o = out_base + x * 3
                rgb[o:o + 3] = row[s:s + 3]
    return width, height, bytes(rgb)


def resize_rgb_box(src_w, src_h, src_rgb, dst_w, dst_h):
    """区域均值缩放，保证缩小的品牌 Logo 边缘平滑清晰。"""
    out = bytearray(dst_w * dst_h * 3)
    for y in range(dst_h):
        y0 = int(y * src_h / dst_h)
        y1 = max(y0 + 1, int((y + 1) * src_h / dst_h))
        for x in range(dst_w):
            x0 = int(x * src_w / dst_w)
            x1 = max(x0 + 1, int((x + 1) * src_w / dst_w))
            r = g = b = cnt = 0
            for sy in range(y0, min(y1, src_h)):
                row_off = sy * src_w * 3
                for sx in range(x0, min(x1, src_w)):
                    p = row_off + sx * 3
                    r += src_rgb[p]
                    g += src_rgb[p + 1]
                    b += src_rgb[p + 2]
                    cnt += 1
            o = (y * dst_w + x) * 3
            out[o] = r // cnt
            out[o + 1] = g // cnt
            out[o + 2] = b // cnt
    return bytes(out)


def write_bmp24(width, height, rgb, out_path):
    """写出标准 24-bit 无压缩 BMP（Windows NSIS MUI_HEADERIMAGE / MUI_WELCOMEFINISHPAGE_BITMAP 要求）。"""
    row_bytes = width * 3
    pad = (4 - (row_bytes % 4)) % 4
    img_size = (row_bytes + pad) * height
    file_size = 54 + img_size
    file_header = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, 54)
    dib_header = struct.pack("<IIIHHIIIIII", 40, width, height, 1, 24, 0, img_size, 2835, 2835, 0, 0)
    rows = bytearray()
    pad_bytes = b"\x00" * pad
    # BMP 为自底向上 BGR 排列
    for y in range(height - 1, -1, -1):
        base = y * width * 3
        for x in range(width):
            p = base + x * 3
            rows.append(rgb[p + 2])
            rows.append(rgb[p + 1])
            rows.append(rgb[p])
        rows.extend(pad_bytes)
    out_path.write_bytes(file_header + dib_header + bytes(rows))


def build_branded_bmp(src_w, src_h, src_rgb, canvas_w, canvas_h, logo_size, out_path):
    bg = src_rgb[0:3]
    canvas = bytearray(bg * (canvas_w * canvas_h))
    scaled = resize_rgb_box(src_w, src_h, src_rgb, logo_size, logo_size)
    ox = (canvas_w - logo_size) // 2
    oy = (canvas_h - logo_size) // 2
    for y in range(logo_size):
        dst_off = ((oy + y) * canvas_w + ox) * 3
        src_off = y * logo_size * 3
        canvas[dst_off:dst_off + logo_size * 3] = scaled[src_off:src_off + logo_size * 3]
    write_bmp24(canvas_w, canvas_h, bytes(canvas), out_path)


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

    # 生成 Windows NSIS 安装向导顶部与侧边听见品牌图（150x57 / 164x314 24-bit BMP）
    w, h, rgb = decode_png_rgb(png_bytes)
    build_branded_bmp(w, h, rgb, 150, 57, 48, ICONS_DIR / "nsis-header.bmp")
    build_branded_bmp(w, h, rgb, 164, 314, 128, ICONS_DIR / "nsis-sidebar.bmp")
    print("Desktop icons & NSIS branding bitmaps prepared:", icon_png, "(%d bytes)" % len(png_bytes))


if __name__ == "__main__":
    main()
