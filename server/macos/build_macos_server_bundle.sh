#!/usr/bin/env bash
# 打包 macOS Apple Silicon (M1/M2/M3/M4 Max) 服务端独立整合包（含双击 .app 与预编译 Metal llama-server）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/server/MAC_VERSION")"
LLAMA_BIN_DIR="${1:-$ROOT/llama.cpp/build/bin}"
OUT_DIR="${2:-$ROOT/dist-macos-server}"

STAGE="$OUT_DIR/Hear-Mac-Server-$VERSION-arm64"
ZIP_PATH="$OUT_DIR/Hear-Mac-Server-$VERSION-arm64.zip"

rm -rf "$STAGE" "$ZIP_PATH"
mkdir -p "$STAGE/server/bin"

# 1. 复制服务端核心代码
for f in \
  hear_cloud.py hear_http.py hear_auth.py hear_speaker.py \
  hear_check_token.py hear_token_service.py hear_token_store.py \
  hear_token_admin.html hear_token_admin.css hear_token_admin.js \
  make_cert.py requirements.txt start-macos.sh README.md TOKEN_ADMIN.md; do
  if [ -f "$ROOT/server/$f" ]; then
    cp "$ROOT/server/$f" "$STAGE/server/$f"
  fi
done
chmod +x "$STAGE/server/start-macos.sh"

# 2. 复制预编译的 Apple Silicon Metal llama-server 及动态库/shader（若存在）
if [ -x "$LLAMA_BIN_DIR/llama-server" ]; then
  cp "$LLAMA_BIN_DIR/llama-server" "$STAGE/server/bin/llama-server"
  chmod +x "$STAGE/server/bin/llama-server"
  # 顺带复制同目录下的 dylib / metallib / metal 文件
  for extra in "$LLAMA_BIN_DIR"/*.dylib "$LLAMA_BIN_DIR"/*.metallib "$LLAMA_BIN_DIR"/*.metal; do
    [ -e "$extra" ] && cp "$extra" "$STAGE/server/bin/"
  done
else
  echo "警告：未在 $LLAMA_BIN_DIR 找到 llama-server，运行 start-macos.sh 时将自动编译"
fi

# 3. 创建双击启动的 .command 快捷脚本
cat > "$STAGE/启动听见服务端.command" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")/server"
exec /bin/bash ./start-macos.sh
EOF
chmod +x "$STAGE/启动听见服务端.command"

cat > "$STAGE/重新配置模型档位.command" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")/server"
exec /bin/bash ./start-macos.sh --reconfigure
EOF
chmod +x "$STAGE/重新配置模型档位.command"

cat > "$STAGE/安装开机自启.command" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")/server"
/bin/bash ./start-macos.sh install-launchd
echo
read -r -p "按回车键关闭窗口…" _
EOF
chmod +x "$STAGE/安装开机自启.command"

cat > "$STAGE/卸载开机自启.command" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")/server"
/bin/bash ./start-macos.sh uninstall-launchd
echo
read -r -p "按回车键关闭窗口…" _
EOF
chmod +x "$STAGE/卸载开机自启.command"

# 4. 创建原生 macOS 双击应用「听见服务端.app」
APP_DIR="$STAGE/听见服务端.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>听见服务端</string>
  <key>CFBundleDisplayName</key>
  <string>听见服务端</string>
  <key>CFBundleIdentifier</key>
  <string>asia.yueping1211.hear.server</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleExecutable</key>
  <string>launch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

cat > "$APP_DIR/Contents/MacOS/launch" <<'EOF'
#!/usr/bin/env bash
# 通过 macOS 终端打开 start-macos.sh，保留实时日志与交互式模型选择
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE_DIR="$(cd "$APP_DIR/.." && pwd)"
CMD_SCRIPT="$BUNDLE_DIR/启动听见服务端.command"
if [ -x "$CMD_SCRIPT" ]; then
  open -a Terminal "$CMD_SCRIPT"
else
  osascript -e 'display alert "未找到启动脚本" message "请确保「听见服务端.app」与「server」目录在同一文件夹下。"'
fi
EOF
chmod +x "$APP_DIR/Contents/MacOS/launch"

# 5. 写入 Mac Studio M4 Max 使用说明
cat > "$STAGE/使用说明-MacStudio.txt" <<'EOF'
================================================================
听见 (Hear) Mac Studio (Apple Silicon M4 Max) 服务端使用说明
================================================================

1. 首次启动（推荐）
   - 解压整个文件夹到任意目录（例如 ~/Applications/Hear-Mac-Server）。
   - 双击「听见服务端.app」（或双击「启动听见服务端.command」）。
   - 如 macOS 提示“无法验证开发者”，请右键点击 → 打开，或在终端执行：
       xattr -dr com.apple.quarantine .

2. M4 Max 64GB 自动优化
   - 启动器会自动检测 64GB 统一内存与 Apple Metal GPU，默认推荐旗舰模型组合：
       * 翻译模型：Hy-MT2-30B-A3B（MoE 30B 仅激活 3B，Metal GPU 全层卸载 -ngl 99）
       * 声音克隆：Qwen3-TTS-1.7B（Metal GPU 全层卸载，秒级出声，告别 504 超时）
       * 语音识别：SenseVoice（秒级初识）+ faster-whisper large-v3-turbo（后台精修）
   - 首次启动会自动创建 Python 虚拟环境并从国内镜像（hf-mirror）下载所需模型。
   - 如需切换模型档位，双击「重新配置模型档位.command」即可。

3. 客户端连接
   - 启动完成后终端会打印局域网地址（例如 https://192.168.x.x:8000）。
   - 在 iPhone「听见」App 与 Windows 桌面端「设置 → 模型服务 → 远端云端服务地址」中填入该地址即可。
   - 如需开启访问口令管理，浏览器打开 https://<Mac局域网IP>:8000/admin。

4. 开机自启（适合 Mac Studio 24 小时常驻）
   - 先手动双击启动一次、完成首次模型下载。
   - 之后双击「安装开机自启.command」，即可在后台随 Mac Studio 开机自动运行。
   - 日志保存在 server/logs/ 目录下；如需关闭开机自启，双击「卸载开机自启.command」。
EOF

# 6. 压缩为 .zip
(cd "$OUT_DIR" && zip -r -y "$(basename "$ZIP_PATH")" "$(basename "$STAGE")" >/dev/null)
echo "已生成 macOS 服务端整合包：$ZIP_PATH"
ls -lh "$ZIP_PATH"
