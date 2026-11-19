# 云端模型服务

把模型跑在自己电脑上，手机 App 通过局域网调用。三个模型各自独立，
在 App 的「功能设置 → 引擎管理」里可以**分别**选本地或云端：

| 模型 | 本地（手机上跑） | 云端（电脑上跑） |
|---|---|---|
| 语音识别 | SenseVoice / Whisper | faster-whisper（或者 whisper.cpp 的服务） |
| 文本翻译 | Hy-MT2 (GGUF) | llama.cpp 的 `llama-server` |
| 声音克隆 | Qwen3-TTS (GGUF) | llama.cpp 的 `llama-server`（`/tts` 接口，带参考音频克隆音色） |

## 一、Windows 上装 WSL

在 **PowerShell（管理员）** 里执行：

```powershell
wsl --install -d Ubuntu
```

装完重启，按提示设好用户名密码。然后在开始菜单里打开「Ubuntu」，
把下面的命令一条条粘进去执行（WSL 里就是普通的 Linux 环境）：

```bash
sudo apt update
sudo apt install -y git cmake build-essential curl python3 python3-venv ffmpeg
```

## 二、拿代码、起服务

把仓库 clone 到 WSL 里（或者直接在 Windows 上 clone，再从 `/mnt/c/...` 访问）：

```bash
cd ~
git clone https://github.com/qianyueping1211/Hear.git
cd Hear
```

然后：

```bash
./server/start.sh
```

第一次会做三件事：编译 llama.cpp（几分钟）、下载三个模型（约 2 GB）、
安装 faster-whisper（识别模型，第一次跑会再下载几百 MB）。

跑起来以后屏幕上会打印一行地址：

```
  手机 App 里「功能设置 → 云端模型」填：
      http://192.168.1.10:8000
```

把这个地址填到手机 App 的「功能设置 → 云端模型」里，点「测试连接」，
看到 `asr：就绪  mt：就绪  clone：就绪` 就成了。

## 三、手机和电脑要能互相找到

- 手机和电脑连同一个 Wi‑Fi。
- Windows 防火墙第一次会问「是否允许 Python 访问网络」，要选**允许**。
  没弹窗的话，在 PowerShell（管理员）里放行一下：

```powershell
New-NetFirewallRule -DisplayName "Hear Cloud" -Direction Inbound -LocalPort 8000,8081,8082 -Protocol TCP -Action Allow
```

- 地址里的 IP 是电脑的局域网 IP（`hostname -I` 能看到）。
  如果电脑用的是 Wi‑Fi 而手机插的是流量，或者有 VPN，App 可能连不上。

## 四、接口说明

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

## 五、几个常用开关

| 环境变量 | 作用 | 默认 |
|---|---|---|
| `HEAR_PORT` | 服务端口 | 8000 |
| `HEAR_MT_PORT` / `HEAR_CLONE_PORT` | 两个 llama-server 的端口 | 8081 / 8082 |
| `HEAR_THREADS` | 用的 CPU 线程数 | 8 |
| `HEAR_CTX` | 上下文长度 | 4096 |
| `HEAR_MT_QUANT` | 翻译模型的量化（Q4_K_M 最小最快，Q8_0 最准最大） | Q4_K_M |
| `HEAR_ASR_MODEL` | 识别模型（tiny/base/small/medium/large-v3） | small |
| `HEAR_ASR_DEVICE` | 识别模型用 cpu 还是 cuda | cpu |
| `HEAR_ASR_URL` | 识别转发给别的服务（例如 whisper.cpp 的 whisper-server） | 空 |

比如换个更准的识别模型、翻译也用大一点的量化：

```bash
HEAR_ASR_MODEL=medium HEAR_MT_QUANT=Q8_0 ./server/start.sh
```

## 六、性能参考

Intel Core Ultra 7 258V（16 核，纯 CPU 推理）大致能到：

- 翻译（Hy-MT2 Q4_K_M）：一句 10 来个字的英文约 1～2 秒
- 识别（faster-whisper small，int8）：10 秒的语音约 1～2 秒
- 声音克隆（Qwen3-TTS 0.6B Q4_K_M）：一句话约 3～6 秒

想更快的话，llama-server 可以开 Vulkan 后端用上核显：

```bash
cmake -S llama.cpp -B llama.cpp/build -DLLAMA_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build llama.cpp/build --config Release -j --target llama-server
```

然后在启动命令里加上 `--gpu Vulkan`（在 `start.sh` 里加）。
M 系列 Mac 同理可以用 Metal（默认就是）。

## 七、常见问题

**App 显示“连不上”**：先在电脑上 `curl http://127.0.0.1:8000/health`，
能通就是网络/防火墙问题，不能通看 `server/mt.log`、`server/clone.log`。

**识别报“未安装 faster-whisper”**：装一下

```bash
cd server && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

**声音克隆没声音**：确认 App 里「声音克隆引擎」选的是「云端」，
并且电脑上 `server/clone.log` 里能看到 `/tts` 的请求记录。

**翻译很慢或超时**：把 `HEAR_MT_QUANT` 换成 `Q4_K_M`（默认就是这个），
或者把 `HEAR_THREADS` 调大。
