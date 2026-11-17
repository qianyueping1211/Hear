#!/usr/bin/env bash
# 在 Mac 上一键生成 Xcode 工程并打开
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1 || [ ! -d "$(xcode-select -p)/Platforms/iPhoneOS.platform" ]; then
  echo "❌ 没有检测到完整的 Xcode。请先从 App Store 安装 Xcode，打开一次并同意协议，然后重新运行本脚本。"
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "安装 Homebrew（需要输入开机密码）…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
  fi
  brew install xcodegen
fi

[ -d Frameworks/llama.xcframework ] || bash scripts/fetch_llama.sh

# 免费 Apple ID 要求 Bundle ID 全球唯一，这里用你的 Mac 用户名生成一个
USER_SAFE=$(echo "${USER:-me}" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')
export BUNDLE_ID="${BUNDLE_ID:-com.${USER_SAFE}.hear}"
export TEAM_ID="${TEAM_ID:-}"

xcodegen generate
echo ""
echo "✅ 工程已生成，Bundle ID：$BUNDLE_ID"
echo "接下来在 Xcode 里：选左侧 Hear → Signing & Capabilities → Team 选你的 Apple ID → 连上 iPhone → 点 ▶"
open Hear.xcodeproj
