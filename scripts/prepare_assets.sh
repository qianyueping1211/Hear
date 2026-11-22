#!/usr/bin/env bash
# 把 branding/icon/part*.b64（文本形式保存的图标，分段存放）还原成 App 图标图片
set -euo pipefail
cd "$(dirname "$0")/.."
DST="apps/ios/Hear/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
TMP=$(mktemp)
cat branding/icon/part0.b64 branding/icon/part1.b64 branding/icon/part2.b64 \
    branding/icon/part3.b64 branding/icon/part4.b64 branding/icon/part5.b64 > "$TMP"
if base64 --help 2>&1 | grep -q -- '--decode'; then
  base64 --decode < "$TMP" > "$DST"
else
  base64 -D -i "$TMP" -o "$DST"
fi
rm -f "$TMP"
echo "✅ App 图标已生成：${DST}（$(wc -c < "${DST}") 字节）"
