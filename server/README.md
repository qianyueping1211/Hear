# 云端模型服务

把模型跑在自己电脑上，手机 App 通过局域网调用。三个模型各自独立，
在 App 的「功能设置 → 模型管理 → 在线模型」里可以**分别**选本地或云端：

| 模型 | 本地（手机上跑） | 云端（电脑上跑） |
|---|---|---|
| 语音识别 | SenseVoice / Whisper | faster-whisper（或者 whisper.cpp 的服务） |
| 文本翻译 | Hy-MT2 (GGUF) | llama.cpp 的 `llama-server` |
| 声音克隆 | Qwen3-TTS (GGUF) | llama.cpp 的 `llama-server`（`/tts` 接口，带参考音频克隆音色） |

> 📄 完整的部署步骤、注意事项、已知问题和处理方案：
> **[docs/windows-deploy.md](../docs/windows-deploy.md)**

三个模型默认都走 8000 那个总服务（`hear_cloud.py`），它再转发给 8081（翻译）
和 8082（克隆）。也可以在 App 里给某个模型单独填地址，直接连那个模型服务：

| 地址 | 是什么 | 能做什么 |
|---|---|---|
| `http://电脑IP:8000` | 总服务（`hear_cloud.py`） | 识别 + 翻译 + 克隆，三个都在 |
| `http://电脑IP:8081` | 单独的翻译模型（llama-server） | 只有文本翻译 |
| `http://电脑IP:8082` | 单独的克隆模型（llama-server） | 只有声音克隆 |

App 会自己看这个地址上跑的是哪种服务，用对应的接口去调，不用手动切换。
（8081、8082 现在监听 0.0.0.0，手机能直接连。）

## 先自己验证一下服务通不通

服务起来以后，窗口里会自己打印这些地址：

```
[听见] 服务起来了，监听 0.0.0.0:8000
[听见] 本机测试：http://127.0.0.1:8000/
[听见] 手机访问：http://192.168.x.x:8000/
[听见] 自检通过（200）。...
```

按这个顺序试，三步就能定位问题：

1. **电脑浏览器打开 `http://127.0.0.1:8000/`**——打不开就是服务根本没起来，
   看窗口里的报错（模型还在下载、或 Python 报错）。
   注意：服务是**先**起来的，模型在后面下载，所以就算翻译和克隆还没准备好，
   这个页面也照样能打开（只是那时候 /health 里 mt、clone 显示"连不上"）。
2. 电脑浏览器打开 `http://192.168.x.x:8000/`（窗口里打印的那个 IP）——
   打不开说明这个 IP 不是这台电脑现在的地址（可能连了别的 Wi-Fi、或者地址变了）。
3. **手机浏览器打开同一个地址**——能打开说明手机到电脑的网络是通的，
   App 连不上就是 iOS 的「本地网络」权限没给：
   设置 → 隐私与安全性 → 本地网络，打开「听见」。

## 云端语音识别有三种方案（可以选）

服务端同时支持三种识别方案，在 App 的
「功能设置 → 模型管理 → 在线模型 → 语音识别 → 配置 → 识别方案」里选：

| 方案 | 说明 |
|---|---|
| **最快：SenseVoice** | 只用 SenseVoice（阿里 FunASR，ONNX，CPU 也能跑，约 230 MB） |
| **最准：Whisper** | 只用 faster-whisper（准，但慢一点） |
| **SenseVoice + Whisper** | SenseVoice 先出结果，Whisper 再修正（推荐） |

选哪个方案，App 会在请求里带上 `X-ASR-Scheme` 头，服务端按它来跑；
App 的运行日志和服务端日志都会写清楚这次用的是哪个方案。

**这个列表是按电脑上实际有的模型动态给的**：

- 电脑上没装 SenseVoice（模型文件不在）时，列表里只留 Whisper，
  并提示"这台电脑上没装 SenseVoice，在电脑上重跑一次启动脚本就会装上"；
- Whisper 那一项会带上电脑上跑的型号，比如「最准：Whisper（large-v3）」——
  型号是启动时选的（`HEAR_ASR_MODEL` 或启动脚本里选的），
  服务端从 `/health` 里报出来，App 拿到就显示出来。

服务端默认用 `sensevoice+whisper`，也可以用环境变量改：

| 环境变量 | 说明 | 默认 |
|---|---|---|
| `HEAR_ASR_SCHEME` | 识别方案 | `sensevoice+whisper` |
| `HEAR_ASR_MODEL` | Whisper 模型（tiny/base/small/medium/large-v3） | `small` |

SenseVoice 模型放在 `server/models/sensevoice/`（`model.int8.onnx` + `tokens.txt`），
脚本会自动下载。

## 三个模型分别是怎么起来的

启动的时候你会看到两行 `==>`：

```
==> 起翻译模型（Hy-MT2，后端 GPU，端口 8081）
==> 起声音克隆模型（Qwen3-TTS，后端 GPU，端口 8082）
```

**语音识别没有这一行**，因为它不是独立进程：它跑在 8000 端口那个 Python 服务里
（`hear_cloud.py`），用 faster-whisper，默认 `small` 模型、CPU int8。

而且**识别模型的权重不在"下载模型"那一步**——脚本只下三个 GGUF（翻译、克隆、克隆的 mmproj），
faster-whisper 的模型是**服务启动后在后台下载**的（几百 MB，缓存到
`C:\Users\你的用户名\.cache\huggingface`，只下一次）。

所以：

- 刚起来的头几分钟，手机 App 里「语音识别」那一行会显示**异常**，
  打开「配置 → 测试连接」能看到服务端回的是 `加载中（第一次要下识别模型）`，
  等模型下完就变成**正常**了。这是正常的，不是配错了。
- 想快一点可以把模型改小：`set HEAR_ASR_MODEL=tiny` 或 `base`（识别准确率会差一些）。
- 想用别的识别服务（比如 whisper.cpp 的 whisper-server）：
  `set HEAR_ASR_URL=http://127.0.0.1:8083`，设了以后就不装 faster-whisper 了。

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

不需要装 WSL、不需要编译、不需要 Visual Studio。

### 1. 装 Python

到 [python.org](https://www.python.org/downloads/windows/) 下载安装，
**安装第一页底部要勾上 “Add python.exe to PATH”**，否则脚本找不到 Python。
装完把 PowerShell 关掉重开（让 PATH 生效）。

### 2. 拿到仓库

有 Git 就 `git clone`，没有就到 [Releases](https://github.com/qianyueping1211/Hear/releases) 下源码 zip 解压。
假设放在 `C:\Users\你的用户名\Downloads\Hear`。

### 3. 在仓库根目录里运行

**位置很重要**：要在有 `README.md` 和 `server` 文件夹的那一层，右键这个文件夹
→ “在终端中打开”，或者自己 `cd` 过去：

```powershell
cd C:\Users\你的用户名\Downloads\Hear
powershell -ExecutionPolicy Bypass -File server\start-windows.ps1
```

也可以用绝对路径，从哪儿运行都行：

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\你的用户名\Downloads\Hear\server\start-windows.ps1"
```

脚本开头会打印它认到的目录，不用怕跑错地方：

```
==> 仓库目录：C:\Users\你的用户名\Downloads\Hear
==> 模型目录：C:\Users\你的用户名\Downloads\Hear\server\models
```

### 4. 启动时按类型选模型

每次启动都会问三个问题（识别 / 翻译 / 克隆各选一个），直接回车就是上次选的；
选完记在 `server\hear_models.json` 里：

```
  语音识别（Whisper，CPU 上跑）
    1) tiny      约 75 MB    最快，精度一般
    2) base      约 145 MB   省空间，日常够用
    3) small     约 480 MB   速度和准确度都还行 （推荐）
    4) medium    约 1.5 GB   更准，慢一点
    5) large-v3  约 3 GB     最准；CPU 上偏慢，有独显会快很多
```

翻译可以选 Hy-MT2 的 1.8B（1.1 GB，快）/ 7B（4.4 GB，更准）/ 30B-A3B
（18 GB，混合专家，30B 里只激活 3B，又大又快又好，内存要 24G 以上）；
克隆可以选 Qwen3-TTS 的 0.6B（快）/ 1.7B（更像原声，推荐）。

（也可以随时加 `-Choose` 重新选一次：）

```powershell
powershell -ExecutionPolicy Bypass -File server\start-windows.ps1 -Choose
```

### 5. 脚本会自动做的事

- 从 llama.cpp 官方发行版下载 **Vulkan 版**（核显）和 **OpenVINO 版**（NPU，OpenVINO 运行库已经打包在里面了）；
- 下载刚才选的三个模型（默认 Hy-MT2 1.1 GB、Qwen3-TTS 两个文件共约 1.7 GB）；
- 建虚拟环境并装 faster-whisper（识别模型，第一次跑会再下几百 MB）；
- 起三个服务，最后打印一个地址，填到手机 App 里就行。

跑起来屏幕上会打印：

```
  手机 App 里「功能设置 → 模型管理 → 在线模型」填：
      http://192.168.1.10:8000
```

所有下载的东西都在 `server\bin`（llama.cpp）和 `server\models`（模型）里，删了重跑就重新下。
日志在 `server\mt.log`（翻译）和 `server\clone.log`（克隆）。

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

POST /v1/clone/reference   请求体：16 kHz 单声道 wav（二进制）
                    返回：{"id": "一串 id"}
                    参考音频先存一次拿到 id，后面的克隆请求带
                    "reference_id" 就行，不用每句都重传几百 KB。
                    （老的 App 不带这个 id，服务照旧按 reference_wav 收。）
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
