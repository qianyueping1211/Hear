#!/usr/bin/env bash
# 下载 llama.cpp 官方编译好的 iOS 框架（llama.xcframework）到 Frameworks/
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${LLAMA_TAG:-}"
if [ -z "$TAG" ]; then
  AUTH=()
  [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  TAG=$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} https://api.github.com/repos/ggml-org/llama.cpp/releases/latest \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')
fi

URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-xcframework.zip"
TMP=$(mktemp -d)
echo "下载 llama.cpp ${TAG} …"
curl -fL --retry 3 "$URL" -o "$TMP/llama.zip"
unzip -q "$TMP/llama.zip" -d "$TMP"
XC=$(find "$TMP" -type d -name 'llama.xcframework' | head -1)
[ -n "$XC" ] || { echo "没找到 llama.xcframework"; exit 1; }

rm -rf Frameworks/llama.xcframework
mkdir -p Frameworks
cp -R "$XC" Frameworks/
echo "$TAG" > Frameworks/LLAMA_VERSION
rm -rf "$TMP"
echo "✅ Frameworks/llama.xcframework（llama.cpp ${TAG}）"
