#!/usr/bin/env bash
# 听见 (Hear) macOS Apple Silicon (M1/M2/M3/M4 Max) 服务端启动器
# 针对 Mac Studio M4 Max 64GB 统一内存自动启用 Metal GPU 全层卸载（-ngl 99 -fa on）
#
# 用法：
#   ./start-macos.sh                   正常启动（首次自动安装依赖与下载模型）
#   ./start-macos.sh --reconfigure     重新选择翻译/克隆/识别模型档位
#   ./start-macos.sh install-launchd   安装为 macOS 开机自启后台服务
#   ./start-macos.sh uninstall-launchd 卸载开机自启后台服务
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/hear_cloud.py" ]; then
  SERVER_DIR="$SCRIPT_DIR"
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  ROOT_DIR="$SCRIPT_DIR"
  SERVER_DIR="$SCRIPT_DIR/server"
fi

MODEL_DIR="${HEAR_MODEL_DIR:-$SERVER_DIR/models}"
SV_DIR="$MODEL_DIR/sensevoice"
CFG_FILE="$SERVER_DIR/mac-config.env"
LOG_DIR="$SERVER_DIR/logs"
mkdir -p "$MODEL_DIR" "$SV_DIR" "$LOG_DIR"
cd "$SERVER_DIR"

say()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✖\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------- launchd 后台服务管理
PLIST_LABEL="asia.yueping1211.hear.server"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

if [ "${1:-}" = "install-launchd" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SERVER_DIR/start-macos.sh</string>
    <string>--non-interactive</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$SERVER_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HEAR_NON_INTERACTIVE</key>
    <string>1</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load -w "$PLIST_PATH"
  ok "已安装并启动 macOS 后台自启服务：$PLIST_LABEL"
  echo "  日志路径：$LOG_DIR/launchd.out.log"
  echo "  如需卸载：./start-macos.sh uninstall-launchd"
  exit 0
fi

if [ "${1:-}" = "uninstall-launchd" ]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  ok "已卸载 macOS 后台自启服务：$PLIST_LABEL"
  exit 0
fi

NON_INTERACTIVE="${HEAR_NON_INTERACTIVE:-0}"
RECONFIGURE=0
for arg in "$@"; do
  [ "$arg" = "--non-interactive" ] && NON_INTERACTIVE=1
  [ "$arg" = "--reconfigure" ] && RECONFIGURE=1
done

# ---------------------------------------------------------------- 检测 Apple Silicon 硬件配置
ARCH="$(uname -m)"
RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 17179869184)"
RAM_GB="$((RAM_BYTES / 1073741824))"
CPU_CORES="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)"
CHIP_NAME="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")"

say "检测到硬件：$CHIP_NAME ($ARCH) · 统一内存 ${RAM_GB} GB · 性能核 ${CPU_CORES}"

# 按统一内存自动推荐最优档位（Mac Studio M4 Max 64GB 默认拉满旗舰组合）
if [ "$RAM_GB" -ge 48 ]; then
  REC_MT="30b"
  REC_CLONE="1.7b"
  REC_ASR="large-v3-turbo"
elif [ "$RAM_GB" -ge 24 ]; then
  REC_MT="7b"
  REC_CLONE="1.7b"
  REC_ASR="medium"
else
  REC_MT="1.8b"
  REC_CLONE="0.6b"
  REC_ASR="small"
fi

if [ -f "$CFG_FILE" ] && [ "$RECONFIGURE" = "0" ]; then
  # shellcheck disable=SC1090
  source "$CFG_FILE"
fi

MT_TIER="${HEAR_MT_TIER:-${CFG_MT_TIER:-$REC_MT}}"
CLONE_TIER="${HEAR_CLONE_TIER:-${CFG_CLONE_TIER:-$REC_CLONE}}"
ASR_MODEL="${HEAR_ASR_MODEL:-${CFG_ASR_MODEL:-$REC_ASR}}"
MT_QUANT="${HEAR_MT_QUANT:-Q4_K_M}"
PORT="${HEAR_PORT:-8000}"
MT_PORT="${HEAR_MT_PORT:-8081}"
CLONE_PORT="${HEAR_CLONE_PORT:-8082}"
CTX="${HEAR_CTX:-4096}"
THREADS="${HEAR_THREADS:-$CPU_CORES}"

if [ ! -f "$CFG_FILE" ] || [ "$RECONFIGURE" = "1" ]; then
  if [ "$NON_INTERACTIVE" = "0" ] && [ -t 0 ]; then
    echo
    say "首次配置模型档位（针对本机 ${RAM_GB}GB 内存已默认推荐最佳组合，直接回车即可）："
    echo "  1) 文本翻译 Hy-MT2："
    echo "     [1] 30b  (Hy-MT2-30B-A3B，约 18GB，旗舰画质+MoE极速，推荐 48GB+ 内存)"
    echo "     [2] 7b   (Hy-MT2-7B，约 4.4GB，均衡)"
    echo "     [3] 1.8b (Hy-MT2-1.8B，约 1.1GB，极轻)"
    read -r -p "  选择翻译模型 [默认 $MT_TIER]：" ans_mt || true
    case "${ans_mt:-}" in
      1|30b) MT_TIER="30b" ;;
      2|7b)  MT_TIER="7b" ;;
      3|1.8b) MT_TIER="1.8b" ;;
    esac

    echo "  2) 声音克隆 Qwen3-TTS："
    echo "     [1] 1.7b (约 1.1GB，最像原声，推荐)"
    echo "     [2] 0.6b (约 0.6GB，更轻量)"
    read -r -p "  选择声音克隆模型 [默认 $CLONE_TIER]：" ans_cl || true
    case "${ans_cl:-}" in
      1|1.7b) CLONE_TIER="1.7b" ;;
      2|0.6b) CLONE_TIER="0.6b" ;;
    esac

    echo "  3) Whisper 二次精修模型（SenseVoice 默认先出秒级原文）："
    echo "     [1] large-v3-turbo (最准最快，推荐 M4 Max)"
    echo "     [2] medium"
    echo "     [3] small"
    read -r -p "  选择 Whisper 模型 [默认 $ASR_MODEL]：" ans_asr || true
    case "${ans_asr:-}" in
      1|large-v3-turbo) ASR_MODEL="large-v3-turbo" ;;
      2|medium)         ASR_MODEL="medium" ;;
      3|small)          ASR_MODEL="small" ;;
    esac
  fi
  cat > "$CFG_FILE" <<EOF
CFG_MT_TIER="$MT_TIER"
CFG_CLONE_TIER="$CLONE_TIER"
CFG_ASR_MODEL="$ASR_MODEL"
EOF
fi

case "$MT_TIER" in
  30b)  MT_REPO="tencent/Hy-MT2-30B-A3B-GGUF"; MT_FILE="Hy-MT2-30B-A3B-$MT_QUANT.gguf" ;;
  7b)   MT_REPO="tencent/Hy-MT2-7B-GGUF";      MT_FILE="Hy-MT2-7B-$MT_QUANT.gguf" ;;
  *)    MT_REPO="tencent/Hy-MT2-1.8B-GGUF";    MT_FILE="Hy-MT2-1.8B-$MT_QUANT.gguf" ;;
esac

case "$CLONE_TIER" in
  1.7b)
    CLONE_REPO="ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF"
    CLONE_FILE="Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf"
    CLONE_MMPROJ="mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf"
    ;;
  *)
    CLONE_REPO="Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF"
    CLONE_FILE="Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf"
    CLONE_MMPROJ="mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf"
    ;;
esac

say "当前模型组合：翻译=Hy-MT2-$MT_TIER · 克隆=Qwen3-TTS-$CLONE_TIER · 识别=SenseVoice+Whisper($ASR_MODEL)"

# ---------------------------------------------------------------- 定位或编译 llama-server (Apple Metal)
LLAMA_SERVER=""
for cand in \
  "$SERVER_DIR/bin/llama-server" \
  "$ROOT_DIR/bin/llama-server" \
  "$ROOT_DIR/llama.cpp/build/bin/llama-server" \
  "$(command -v llama-server 2>/dev/null || true)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    LLAMA_SERVER="$cand"
    break
  fi
done

if [ -z "$LLAMA_SERVER" ]; then
  LLAMA_DIR="${HEAR_LLAMA_DIR:-$ROOT_DIR/llama.cpp}"
  LLAMA_TAG="${HEAR_LLAMA_TAG:-b12491}"
  LLAMA_REPO="${HEAR_LLAMA_REPO:-https://github.com/ggml-org/llama.cpp}"
  say "未检测到预编译 llama-server，正在使用 Apple Metal 编译 llama.cpp ($LLAMA_TAG)…"
  if ! command -v cmake >/dev/null 2>&1; then
    err "缺少 cmake。请先运行：brew install cmake"
    exit 1
  fi
  if [ ! -d "$LLAMA_DIR/.git" ]; then
    git clone --depth 1 --branch "$LLAMA_TAG" "$LLAMA_REPO" "$LLAMA_DIR"
  fi
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DLLAMA_CURL=OFF
  cmake --build "$LLAMA_DIR/build" --config Release -j "$CPU_CORES" --target llama-server
  LLAMA_SERVER="$LLAMA_DIR/build/bin/llama-server"
fi
ok "llama-server 就绪：$LLAMA_SERVER（Apple Metal GPU 加速）"

# 若同目录下有 dylib（整合包自带），设置 DYLD_LIBRARY_PATH
LLAMA_BIN_DIR="$(cd "$(dirname "$LLAMA_SERVER")" && pwd)"
export DYLD_LIBRARY_PATH="$LLAMA_BIN_DIR:${DYLD_LIBRARY_PATH:-}"

# ---------------------------------------------------------------- 下载模型（双镜像自动回退）
fetch_hf() {
  local repo="$1" file="$2" dest="$3"
  if [ -f "$dest" ] && [ -s "$dest" ]; then
    ok "已有模型：$(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  local endpoints=()
  if [ -n "${HF_ENDPOINT:-}" ]; then
    endpoints+=("$HF_ENDPOINT")
  fi
  endpoints+=("https://hf-mirror.com" "https://huggingface.co")
  for ep in "${endpoints[@]}"; do
    local url="${ep%/}/$repo/resolve/main/$file"
    say "下载 $file ← $ep"
    if curl -fL --retry 3 --retry-delay 2 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      ok "下载完成：$file"
      return 0
    fi
    warn "镜像 $ep 下载失败，尝试下一个镜像…"
  done
  err "无法下载 $file，请检查网络或设置 HF_ENDPOINT"
  exit 1
}

fetch_hf "$MT_REPO" "$MT_FILE" "$MODEL_DIR/$MT_FILE"
fetch_hf "$CLONE_REPO" "$CLONE_FILE" "$MODEL_DIR/$CLONE_FILE"
fetch_hf "$CLONE_REPO" "$CLONE_MMPROJ" "$MODEL_DIR/$CLONE_MMPROJ"

# SenseVoice（秒级初识）
if [ "${HEAR_SENSEVOICE:-1}" != "0" ]; then
  SV_REPO="csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
  fetch_hf "$SV_REPO" "model.int8.onnx" "$SV_DIR/model.int8.onnx"
  fetch_hf "$SV_REPO" "tokens.txt" "$SV_DIR/tokens.txt"
fi

# 说话人区分模型（约 28 MB）
SPK_FILE="$MODEL_DIR/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
if [ ! -f "$SPK_FILE" ]; then
  say "下载说话人区分模型（约 28 MB）…"
  SPK_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
  if curl -fL --retry 3 -o "$SPK_FILE.part" "$SPK_URL"; then
    mv "$SPK_FILE.part" "$SPK_FILE"
    ok "说话人区分模型就绪"
  else
    rm -f "$SPK_FILE.part"
    warn "说话人模型下载失败（不影响核心翻译与克隆）"
  fi
fi

# ---------------------------------------------------------------- Python 虚拟环境
PYTHON_BIN=""
for p in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
  if command -v "$p" >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v "$p")"
    break
  fi
done
if [ -z "$PYTHON_BIN" ]; then
  err "未找到 python3，请先运行：brew install python@3.12"
  exit 1
fi

if [ ! -x "$SERVER_DIR/.venv/bin/python" ]; then
  say "初始化 Python 虚拟环境并安装识别/加密依赖（首次约 1~2 分钟）…"
  "$PYTHON_BIN" -m venv "$SERVER_DIR/.venv"
  "$SERVER_DIR/.venv/bin/pip" install --upgrade pip -q || true
  "$SERVER_DIR/.venv/bin/pip" install -r "$SERVER_DIR/requirements.txt"
fi
PY="$SERVER_DIR/.venv/bin/python"

# 生成自签 HTTPS 证书（如果不存在）
if [ -f "$SERVER_DIR/make_cert.py" ] && [ ! -f "$SERVER_DIR/cert.pem" ]; then
  say "生成局域网 HTTPS 自签证书…"
  "$PY" "$SERVER_DIR/make_cert.py" || warn "证书生成跳过，将由 hear_cloud.py 自动处理"
fi

# ---------------------------------------------------------------- 启动 Metal GPU 模型服务
PIDS=()
cleanup() {
  echo
  say "正在停止听见 Mac 服务端所有进程…"
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  ok "已全部停止"
}
trap cleanup EXIT INT TERM

wait_health() {
  local url="$1" name="$2"
  for _ in $(seq 1 120); do
    if curl -sf "$url/health" >/dev/null 2>&1; then
      ok "$name 已就绪 ($url)"
      return 0
    fi
    sleep 1
  done
  warn "$name 超过 2 分钟仍未就绪，请查看日志：$LOG_DIR"
}

# 释放可能残留的旧端口进程
for p in "$MT_PORT" "$CLONE_PORT" "$PORT"; do
  old_pid="$(lsof -ti tcp:"$p" 2>/dev/null || true)"
  if [ -n "$old_pid" ]; then
    warn "端口 $p 已被旧进程 ($old_pid) 占用，尝试结束…"
    kill "$old_pid" 2>/dev/null || true
    sleep 0.5
  fi
done

say "启动文本翻译模型（Hy-MT2-$MT_TIER · Metal GPU 全层卸载 · 端口 $MT_PORT）"
"$LLAMA_SERVER" \
  -m "$MODEL_DIR/$MT_FILE" \
  --host 0.0.0.0 --port "$MT_PORT" \
  -ngl 99 -fa on -c "$CTX" -t "$THREADS" --no-warmup \
  > "$LOG_DIR/mt.log" 2>&1 &
PIDS+=($!)

say "启动声音克隆模型（Qwen3-TTS-$CLONE_TIER · Metal GPU 全层卸载 · 端口 $CLONE_PORT）"
"$LLAMA_SERVER" \
  -m "$MODEL_DIR/$CLONE_FILE" \
  --mmproj "$MODEL_DIR/$CLONE_MMPROJ" \
  --host 0.0.0.0 --port "$CLONE_PORT" \
  -ngl 99 -fa on -c "$CTX" -t "$THREADS" --no-warmup \
  > "$LOG_DIR/clone.log" 2>&1 &
PIDS+=($!)

wait_health "http://127.0.0.1:$MT_PORT" "翻译模型 (Hy-MT2)"
wait_health "http://127.0.0.1:$CLONE_PORT" "声音克隆模型 (Qwen3-TTS)"

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "Mac的局域网IP")"
SCHEME="http"
[ -f "$SERVER_DIR/cert.pem" ] && SCHEME="https"

echo
echo "=================================================================="
ok "听见 (Hear) Mac Studio 服务端已就绪！（Apple Metal GPU 加速）"
echo "  局域网地址： ${SCHEME}://${LAN_IP}:${PORT}"
echo "  本机自检：   ${SCHEME}://127.0.0.1:${PORT}/health"
echo "  口令管理页： ${SCHEME}://${LAN_IP}:${PORT}/admin"
echo "  模型日志：   $LOG_DIR/"
echo "  提示：iPhone / Windows 客户端填入上方地址即可极速连接。"
echo "=================================================================="
echo

export HEAR_PORT="$PORT"
export HEAR_MT_URL="http://127.0.0.1:$MT_PORT"
export HEAR_CLONE_URL="http://127.0.0.1:$CLONE_PORT"
export HEAR_ASR_MODEL="$ASR_MODEL"
export HEAR_ASR_SCHEME="${HEAR_ASR_SCHEME:-sensevoice+whisper}"
export HEAR_SENSEVOICE="${HEAR_SENSEVOICE:-1}"
export HEAR_SENSEVOICE_DIR="$SV_DIR"
export HEAR_MODEL_DIR="$MODEL_DIR"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"

"$PY" "$SERVER_DIR/hear_cloud.py"
