# 云端模型服务

把模型跑在自己电脑上，手机 App 通过局域网调用。三个模型各自独立，
在 App 的「功能设置 → 模型管理 → 在线模型」里可以**分别**选本地或云端：

| 模型 | 本地（手机上跑） | 云端（电脑上跑） |
|---|---|---|
| 语音识别 | SenseVoice / Whisper | faster-whisper（或者 whisper.cpp 的服务） |
| 文本翻译 | Hy-MT2 (GGUF) | llama.cpp 的 `llama-server` |
| 声音克隆 | Qwen3-TTS (GGUF) | llama.cpp 的 `llama-server`（`/tts` 接口，带参考音频克隆音色） |

## 先说硬件：CUDA、NPU、核显怎么选

| 你的机器 | 能用哪个后端 |
|---|---|
| Intel Core Ultra（核显 + NPU，比如 258V） | 核显 **Vulkan** ✅ ｜ NPU **OpenVINO** ✅ ｜ CPU ✅ |
| NVIDIA 显卡 | CUDA ✅ |
| Apple Silicon | Metal ✅ |

**CUDA 只能跑在 NVIDIA 显卡上**，Intel 核显装不了 CUDA 也用不了，所以你的机器没这条路。
llama.cpp 对 Intel 机器有两条：

- **核显走 Vulkan**（`--device Vulkan`）：兼容性最好，什么模型架构都能跑，包括声音克隆这种多模态的。
- **NPU 走 OpenVINO**（`GGML_OPENVINO_DEVICE=NPU`）：llama.cpp 官方的 OpenVINO 后端支持 Intel NPU，
  官方文档里验证的机器就是 Lunar Lake（Core Ultra 5 238V + NPU 驱动 1.38.0），
  跟你的 258V 是同一代。**但它只支持纯文本模型**，多模态（声音克隆）还不支持，
  而且 NPU 只支持无状态执行（`-np 1`）、必须明确给 `-c`。

所以默认的分工是：**翻译走核显或 NPU，声音克隆走核显，识别走 CPU（faster-whisper int8）**。

**另外一件重要的事：WSL2 里访问不到 Intel 的 NPU**（WSL2 只给 NVIDIA 显卡提供 CUDA 转发），
核显的 Vulkan 在 WSL2 里也不太稳。**要吃满 NPU 和核显，就在 Windows 上原生跑**（方法 A）。

---

## 方法 A：Windows 上直接跑（推荐）

不需要装 WSL、不需要编译、不需要 Visual Studio：

1. 装 [Python 3.10 以上](https://www.python.org/downloads/windows/)（安装时勾上 “Add to PATH”）。
2. 装 [Git](https://git-scm.com/download/win)。
3. 把仓库 clone 到本地，然后在这个目录里开一个 PowerShell（普通权限就行）：

```powershell
cd Hear
powershell -ExecutionPolicy Bypass -File server\start-windows.ps1
```

脚本会自动：

- 从 llama.cpp 的官方发行版下载 **Vulkan 版**（核显）和 **OpenVINO 版**（NPU）的 `llama-server.exe`；
- 从 Intel 官网下载 OpenVINO 运行库（要用 NPU 才有必要）；
- 下载三个模型（Hy-MT2 1.1 GB、Qwen3-TTS 两个文件共约 800 MB）；
- 装 faster-whisper（识别模型，第一次跑会再下几百 MB）；
- 起三个服务，最后打印一个地址，填到手机 App 里就行。

跑起来屏幕上会打印：

```
  手机 App 里「功能设置 → 模型管理 → 在线模型」填：
      http://192.168.1.10:8000
```

### 想换后端

```powershell
# 翻译走 NPU（OpenVINO 后端）
$env:HEAR_MT_DEVICE = "NPU"
# 声音克隆走 CPU
$env:HEAR_CLONE_DEVICE = "CPU"
powershell -ExecutionPolicy Bypass -File server\start-windows.ps1
```

翻译模型如果用 NPU 起不来（Hy-MT2 是个自研架构，OpenVINO 后端对架构的覆盖还在补），
就改回 `HEAR_MT_DEVICE=GPU`（核显 Vulkan），一样很快。

### 防火墙

第一次运行时 Windows 会弹窗问「是否允许 Python 访问网络」，要选**允许**。
没弹窗的话，用**管理员** PowerShell 执行一次：

```powershell
New-NetFirewallRule -DisplayName "Hear Cloud" -Direction Inbound -LocalPort 8000,8081,8082 -Protocol TCP -Action Allow
```

---

## 方法 B：WSL2（只有 CPU）

在 **PowerShell（管理员）** 里：

```powershell
wsl --install -d Ubuntu
```

装完重启，在 Ubuntu 里：

```bash
sudo apt update
sudo apt install -y git cmake build-essential curl python3 python3-venv ffmpeg
cd ~
git clone https://github.com/qianyueping1211/Hear.git
cd Hear
./server/start.sh
```

WSL2 里没有 NPU，核显的 Vulkan 也不太稳，所以这个方法基本就是纯 CPU 跑。

---

## 接口说明

服务本身只用了 Python 标准库，接口很简单：

```
GET  /health        → {"asr": "就绪（small）", "mt": "就绪", "clone": "就绪"}

POST /v1/asr        请求体：16 kHz 单声道 wav（二进制）
                    头：X-Languages: zh,en   X-Fallback-Language: zh
                    返回：{"lang": "en", "text": "..."}

POST /v1/translate  {"prompt": "把下面的文本翻译成英文…", "src": "zh", "dst": "en"}
                    返回：{"text": "..."}

POST /v1/clone      {"text": "Hello", "lang": "english",
                     "reference_wav": "<base64 的 16 kHz wav>",
                     "reference_text": "参考音频里说的那句话"}
                    返回：{"audio": "<base64 的 wav>", "sample_rate": 24000}
```

`prompt` 是 App 拼好的（和本地翻译用的是同一套格式，包含上下文和术语表），
服务端只是转发给 llama.cpp，由 llama.cpp 套模型的对话模板。

`lang` 用模型认的那种写法（`english` / `chinese` / `japanese`…），App 会自己转好再发过来。

## 常用开关

| 环境变量 | 作用 | 默认 |
|---|---|---|
| `HEAR_PORT` | 服务端口 | 8000 |
| `HEAR_MT_PORT` / `HEAR_CLONE_PORT` | 两个 llama-server 的端口 | 8081 / 8082 |
| `HEAR_MT_DEVICE` | 翻译后端：NPU / GPU / CPU（**只有 Windows 方法有**） | GPU |
| `HEAR_CLONE_DEVICE` | 克隆后端：GPU / CPU | GPU |
| `HEAR_THREADS` | 用的 CPU 线程数 | 8 |
| `HEAR_CTX` | 上下文长度 | 4096 |
| `HEAR_MT_QUANT` | 翻译模型的量化（Q4_K_M 最小最快，Q8_0 最准最大） | Q4_K_M |
| `HEAR_ASR_MODEL` | 识别模型（tiny/base/small/medium/large-v3） | small |
| `HEAR_ASR_DEVICE` | 识别模型用 cpu 还是 cuda | cpu |
| `HEAR_ASR_URL` | 识别转发给别的服务（例如 whisper.cpp 的 whisper-server） | 空 |

## 性能参考

Intel Core Ultra 7 258V（16 核，核显 Arc 130V，NPU 48 TOPS）大致能到：

- 翻译（Hy-MT2 Q4_K_M，核显 Vulkan）：一句 10 来个字的英文约 1～2 秒；NPU 更快
- 识别（faster-whisper small，CPU int8）：10 秒的语音约 1～2 秒
- 声音克隆（Qwen3-TTS 0.6B Q4_K_M，核显 Vulkan）：一句话约 2～4 秒

## 常见问题

**App 显示“连不上”**：先在电脑上 `curl http://127.0.0.1:8000/health`，
能通就是网络/防火墙问题，不能通看 `server/mt.log`、`server/clone.log`。

**NPU 那一档起不来**：看 `server/mt.log`，OpenVINO 后端对模型架构的覆盖还不全，
把 `HEAR_MT_DEVICE` 改回 `GPU`（核显）就行。

**识别报“未安装 faster-whisper”**：在 Windows 上执行

```powershell
cd Hear\server
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
```

**声音克隆没声音**：确认 App 里「声音克隆引擎」选的是「云端」，
并且 `server/clone.log` 里能看到 `/tts` 的请求记录。

**翻译很慢或超时**：把 `HEAR_MT_QUANT` 换成 `Q4_K_M`（默认就是这个），
或者在 Windows 上用核显（`HEAR_MT_DEVICE=GPU`）。
