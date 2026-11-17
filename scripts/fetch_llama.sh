#!/usr/bin/env bash
# 下载 llama.cpp 官方编译好的 iOS 框架（llama.xcframework）到 Frameworks/
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="ggml-org/llama.cpp"
TAG="${LLAMA_TAG:-}"
TMP=$(mktemp -d)

if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  # GitHub Actions 里：用官方 gh 命令下载，更稳定
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [ -n "$TAG" ] || TAG=$(gh release view -R "$REPO" --json tagName -q .tagName)
  echo "下载 llama.cpp ${TAG}（gh）…"
  for i in 1 2 3; do
    gh release download "$TAG" -R "$REPO" -p '*xcframework*.zip' -D "$TMP" --clobber && break
    echo "重试 $i …"; sleep 5
  done
else
  # 本地 Mac：用 curl
  CURL=(curl -fL --http1.1 --retry 5 --retry-all-errors --retry-delay 3)
  if [ -z "$TAG" ]; then
    TAG=$("${CURL[@]}" -sS "https://api.github.com/repos/${REPO}/releases/latest" \
          | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')
  fi
  echo "下载 llama.cpp ${TAG}（curl）…"
  "${CURL[@]}" "https://github.com/${REPO}/releases/download/${TAG}/llama-${TAG}-xcframework.zip" \
    -o "$TMP/llama.zip"
fi

ZIP=$(ls "$TMP"/*.zip 2>/dev/null | head -1)
[ -n "$ZIP" ] || { echo "❌ 没有下载到 xcframework 压缩包"; exit 1; }
mkdir -p "$TMP/x"
unzip -q "$ZIP" -d "$TMP/x"
XC=$(find "$TMP/x" -type d -name 'llama.xcframework' | head -1)
[ -n "$XC" ] || { echo "❌ 压缩包里没找到 llama.xcframework"; exit 1; }

rm -rf Frameworks/llama.xcframework
mkdir -p Frameworks
cp -R "$XC" Frameworks/
echo "$TAG" > Frameworks/LLAMA_VERSION
rm -rf "$TMP"
echo "✅ Frameworks/llama.xcframework（llama.cpp ${TAG}）"
