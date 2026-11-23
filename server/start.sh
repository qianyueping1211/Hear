#!/usr/bin/env bash
# 启动“听见”App 的云端模型服务。
#
#   ./server/start.sh              正常启动
#   HEAR_ASR_MODEL=base ./server/start.sh    换一个识别模型（small/base/tiny…）
#
# 需要：git、cmake、curl、python3。Windows 上先装好 WSL2（Ubuntu），在 WSL 里跑这个脚本。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/server"
MODEL_DIR="${HEAR_MODEL_DIR:-$SERVER_DIR/models}"
LLAMA_DIR="${HEAR_LLAMA_DIR:-$ROOT/llama.cpp}"
LLAMA_TAG="${HEAR_LLAMA_TAG:-b12491}"
LLAMA_REPO="${HEAR_LLAMA_REPO:-https://github.com/ggml-org/llama.cpp}"

PORT="${HEAR_PORT:-8000}"
MT_PORT="${HEAR_MT_PORT:-8081}"
CLONE_PORT="${HEAR_CLONE_PORT:-8082}"
THREADS="${HEAR_THREADS:-8}"
CTX="${HEAR_CTX:-4096}"
HF="${HF_ENDPOINT:-https://huggingface.co}"
MT_QUANT="${HEAR_MT_QUANT:-Q4_K_M}"
ASR_MODEL="${HEAR_ASR_MODEL:-small}"

mkdir -p "$MODEL_DIR"
cd "$SERVER_DIR"

say() { printf '\033[1;36m▶\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- llama.cpp
if [ ! -x "$LLAMA_DIR/build/bin/llama-server" ]; then
  say "准备 llama.cpp（$LLAMA_TAG），第一次要编译几分钟"
  if [ ! -d "$LLAMA_DIR/.git" ]; then
    git clone --depth 1 --branch "$LLAMA_TAG" "$LLAMA_REPO" "$LLAMA_DIR"
  fi
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
  cmake --build "$LLAMA_DIR/build" --config Release -j "$(nproc)" --target llama-server
fi
LLAMA_SERVER="$LLAMA_DIR/build/bin/llama-server"
[ -x "$LLAMA_SERVER" ] || { echo "没找到 llama-server"; exit 1; }

# ---------------------------------------------------------------- 下载模型
fetch() {   # $1=仓库  $2=文件名  $3=存哪
  if [ -f "$3" ]; then say "已有 $(basename "$3")"; return; fi
  say "下载 $2"
  curl -fL --retry 5 --retry-delay 3 -o "$3.part" "$HF/$1/resolve/main/$2"
  mv "$3.part" "$3"
}
fetch "tencent/Hy-MT2-1.8B-GGUF" "Hy-MT2-1.8B-$MT_QUANT.gguf" "$MODEL_DIR/Hy-MT2-1.8B-$MT_QUANT.gguf"
fetch "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF" "Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf" "$MODEL_DIR/Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf"
fetch "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF" "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf" "$MODEL_DIR/mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf"

# ---------------------------------------------------------------- 识别模型
if [ ! -x "$SERVER_DIR/.venv/bin/python" ]; then
  say "装 faster-whisper（语音识别用）"
  rm -rf "$SERVER_DIR/.venv"
  if python3 -m venv "$SERVER_DIR/.venv"; then
    "$SERVER_DIR/.venv/bin/pip" install --upgrade pip -q || true
    "$SERVER_DIR/.venv/bin/pip" install -r "$SERVER_DIR/requirements.txt" -q || true
  else
    rm -rf "$SERVER_DIR/.venv"
    say "创建虚拟环境失败（可尝试安装 python3-venv），暂用系统 python3"
  fi
fi
if [ -x "$SERVER_DIR/.venv/bin/python" ]; then
  PY="$SERVER_DIR/.venv/bin/python"
else
  PY="python3"
fi

# ---------------------------------------------------------------- 起服务
PIDS=()
cleanup() {
  say "关掉服务"
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

wait_health() {   # $1=地址  $2=名字
  for i in $(seq 1 120); do
    if curl -sf "$1/health" >/dev/null 2>&1; then say "$2 好了"; return 0; fi
    sleep 2
  done
  say "$2 没能在两分钟内就绪，继续往下走"
}

say "起翻译模型（Hy-MT2，端口 $MT_PORT）"
"$LLAMA_SERVER" -m "$MODEL_DIR/Hy-MT2-1.8B-$MT_QUANT.gguf" \
  --host 127.0.0.1 --port "$MT_PORT" -c "$CTX" -t "$THREADS" --no-warmup \
  > "$SERVER_DIR/mt.log" 2>&1 &
PIDS+=($!)

say "起声音克隆模型（Qwen3-TTS，端口 $CLONE_PORT）"
"$LLAMA_SERVER" -m "$MODEL_DIR/Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf" \
  --mmproj "$MODEL_DIR/mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf" \
  --host 127.0.0.1 --port "$CLONE_PORT" -c "$CTX" -t "$THREADS" --no-warmup \
  > "$SERVER_DIR/clone.log" 2>&1 &
PIDS+=($!)

wait_health "http://127.0.0.1:$MT_PORT" "翻译模型"
wait_health "http://127.0.0.1:$CLONE_PORT" "声音克隆模型"

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
say "云端服务监听 0.0.0.0:$PORT"
echo
echo "  手机 App 里「功能设置 → 云端模型」填："
echo "      http://${IP:-电脑的局域网IP}:$PORT"
echo
echo "  （手机和电脑要在同一个 Wi‑Fi 下；Windows 防火墙要放行 $PORT 端口）"
echo

export HEAR_PORT="$PORT" HEAR_MT_URL="http://127.0.0.1:$MT_PORT" HEAR_CLONE_URL="http://127.0.0.1:$CLONE_PORT"
export HEAR_ASR_MODEL="$ASR_MODEL"
# 不使用 exec，确保退出或收到 SIGINT/SIGTERM 时 trap cleanup 能清理所有后台 llama-server
"$PY" "$SERVER_DIR/hear_cloud.py"
