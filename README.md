# 听见 (Hear)

iPhone 上的**完全本地**实时语音翻译。不联网、不上传，说话就翻译。

- 选两种语言（默认 中文 ⇄ English），点一下开始，之后直接说话
- 自动判断说的是哪种语言，翻译成另一种，并可朗读出来
- 语音识别：Whisper large-v3 turbo（WhisperKit，跑在神经网络引擎上）
- 翻译：腾讯 Hy-MT2-1.8B（llama.cpp，跑在 GPU 上）
- 支持上下文连贯翻译、自定义术语表
- 适配 iPhone 16 Pro / Pro Max 等 8GB 内存机型，iOS 18+

📄 完整介绍与技术架构（功能清单、信号通路、服务接口、在线模型服务）：**[docs/index.html](docs/index.html)**
（下载后用浏览器打开就行）

🪟 在 Windows 上把模型跑在自己电脑上：**[docs/windows-deploy.md](docs/windows-deploy.md)**
（部署步骤、启动时按类型选模型、注意事项、已知问题和处理方案）

---

## 安装方法（二选一）

不需要付费开发者账号。免费 Apple ID 签名的 App 有效期 7 天，到期后**覆盖安装**一次即可。不要先删除 App，模型和设置都会保留，不用重新下载。

### 方法 A：直接下载安装包 + Sideloadly 安装（不用学 Xcode，Windows 也行）

1. 打开本仓库右侧的 **Releases（发行版）**，进入最新版本，下载 `Hear-版本号.ipa`（例如 `Hear-1.0.0.ipa`）。不用登录。
   （每次更新代码后，GitHub 会自动打包并发布一个新版本，大约 3～15 分钟。）
2. 如果想手动重新打包：**Actions** → **Build IPA (unsigned)** → **Run workflow**。
3. 在电脑上安装 [Sideloadly](https://sideloadly.io)（Mac / Windows 都有）。Windows 还需要装 iTunes 和 iCloud 的官网版本。
4. 用数据线连接 iPhone，把下载的 ipa 拖进 Sideloadly，填你的 Apple ID，点 **Start**。
5. 在 iPhone 上：
   - **设置 → 隐私与安全性 → 开发者模式** → 打开（会重启）。
   - **设置 → 通用 → VPN 与设备管理** → 点你的 Apple ID → **信任**。
6. 7 天后过期：重复第 4 步即可（同一个 ipa 就行，也可以顺便下载最新版）。

### 方法 B：有 Mac，用 Xcode 直接装

1. App Store 安装 **Xcode**，打开一次，同意协议。
2. 下载本仓库（绿色 Code 按钮 → Download ZIP），解压。
3. 打开“终端”，把解压出来的文件夹拖进终端窗口，运行：
   ```bash
   cd 拖进来的路径
   bash setup.sh
   ```
   脚本会自动安装工具、下载 llama.cpp、生成并打开 Xcode 工程。
4. Xcode 里：**Xcode → Settings → Accounts** 添加你的 Apple ID。
5. 左侧点蓝色的 **Hear** → **Signing & Capabilities** → **Team** 选你的名字（Personal Team）。
6. 用数据线连上 iPhone，顶部设备选你的手机，点 ▶ 运行。
7. iPhone 上同样打开开发者模式，并信任开发者（见方法 A 第 5 步）。
8. 7 天后过期：连上手机，再点一次 ▶。

---

## 第一次打开

1. 点 **开始下载**。翻译模型约 2 GB，语音模型约 1.6 GB。请连接 Wi‑Fi，并让 App 保持在前台。
2. 下载完会加载模型。**第一次加载语音模型需要编译 1～3 分钟**，以后打开就快了。
3. 点麦克风按钮开始，直接说话。再点一下停止。

下载慢或失败时，可以在 **设置 → 下载源** 换成 `hf-mirror`（国内镜像）。
也可以在电脑上先下载 `.gguf` 文件，再用 **设置 → 从“文件”导入**。模型地址：
[tencent/Hy-MT2-1.8B-GGUF](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF)

## 使用技巧

- **两种模式**：底部左右滑动切换（也可以点底部的小圆点）。
  - **实时翻译模式**：点一下中间的按钮开始，之后直接说话，自动判断语言；再点一下停止。
  - **对话翻译模式**：左右两个国旗按钮，按住说对应的语言，松开就暂停，这一段会接着翻译完再播报。
- **识别引擎**（功能设置 → 语音识别）：
  - **本地最准：Whisper**：标点和长句最好，说完一句后识别，稍慢。
  - **本地最快：SenseVoice**：说完马上出字（约 240 MB，只支持中、英、日、韩）。
  - **SenseVoice + Whisper 校正**：SenseVoice 先出结果，空闲时 Whisper 再识别一遍，有明显差别就替换（句子后面显示魔法棒）。
  - **iOS 系统听写**：说话时逐字显示，说完由 Whisper 定稿。
- **朗读开/关**：开着时，翻译结果会读出来；朗读期间麦克风自动暂停，避免回声。
- **上下文开**：参考前两句来翻译，代词和语气更连贯。
- **术语表**（设置里）：每行 `原文=译文`，比如人名、公司名、专业词。
- **灵敏度 / 停顿时长**：环境吵就调高灵敏度数值；想更快出结果，就把停顿时长调短。
- 对话页长按某一句可以修改原文并重新翻译；在历史记录里长按可以复制或重新朗读。
- 想让朗读更自然：**设置 → 辅助功能 → 朗读内容 → 声音**，下载“增强版/高级版”中英文语音。

## 云端模型（想用电脑的算力）

App 默认什么都跑在手机上。也可以把模型放到自己的电脑上跑，手机通过局域网调用，
三个模型（识别 / 翻译 / 声音克隆）**各自独立**，可以分别选本地或云端。

**Windows 上直接跑（推荐）**：装好 Python 和 Git 之后，

```powershell
git clone https://github.com/qianyueping1211/Hear.git
cd Hear
powershell -ExecutionPolicy Bypass -File server\start-windows.ps1
```

脚本会自己下载 llama.cpp 的运行包、三个模型、faster-whisper，不用编译也不用装 WSL，
最后打印一个地址，填到手机 App 的 **功能设置 → 模型管理 → 在线模型** 里，
再把「引擎管理」里需要的模型改成「云端：自己电脑上的服务」。

**更省事：双击 `start-hear-cloud.bat`**（Windows）

仓库根目录里的 `start-hear-cloud.bat` 是给不想敲命令的人准备的：
双击之后它会自己下载（或更新）最新代码、装好依赖、生成证书、启动服务，
中间会问你识别 / 翻译 / 声音克隆各用哪个模型。

两种摆法都行：

- 把 `start-hear-cloud.bat` 单独放在一个空文件夹里 → 它会把代码下到旁边的 `Hear` 目录
- 把整个仓库下载下来解压，直接双击里面的 `start-hear-cloud.bat` → 它就在原地跑

Intel 核显（NPU 也行）机器上，翻译可以走核显的 Vulkan 或 NPU 的 OpenVINO 后端；
WSL2 里访问不到 NPU，所以想用满硬件就别装 WSL。完整说明（端口、防火墙、性能、常见问题）
看 [server/README.md](server/README.md)。

---

## 项目结构

```
Hear/
├── App/LiveSession.swift        整体流程：断句 → 识别 → 翻译 → 朗读
├── Audio/AudioCapture.swift     麦克风采集、重采样到 16kHz
├── Audio/Segmenter.swift        自动断句（不用一直按着）
├── Speech/SpeechRecognizer.swift  WhisperKit 语音识别 + 语种判断
├── Speech/Speaker.swift         系统朗读
├── Translate/LlamaTranslator.swift  llama.cpp 运行 Hy-MT2
├── Translate/PromptBuilder.swift    官方提示词格式（上下文、术语）
├── Models/                      语言列表、模型下载与管理
├── Cloud/CloudClient.swift      云端模型服务客户端（识别/翻译/克隆三个接口）
├── Audio/Wav.swift              wav 编解码（传声音用）
└── Views/                       界面
project.yml                      XcodeGen 工程描述
setup.sh                         Mac 一键生成工程
start-hear-cloud.bat             Windows 一键启动（下载代码 + 装依赖 + 起服务）
scripts/fetch_llama.sh           下载 llama.cpp 的 iOS 框架
server/                          云端模型服务（WSL2 上跑，README 在里面）
.github/workflows/build-ipa.yml  GitHub 自动打包 ipa
```

## 常见问题

- **打包失败（Actions 变红）**：点进失败的任务，下载 `build-log`，把里面带 `error:` 的几行发给 Claude 修。
- **llama.cpp 新版本改了接口导致编译错误**：可以固定版本。在 workflow 的 `env` 里加 `LLAMA_TAG: b7xxx`（填一个能用的版本号）。
- **打包显示 “The job was not acquired by Runner” 或 “Internal server error”**：这是 GitHub 自己的服务器临时出问题，和代码无关。进入这次打包，点右上角 **Re-run all jobs** 重新打包即可。
- **免费账号限制**：同时最多 3 个自签 App；每 7 天需要重签。
- **版本号**：三位数字，写在仓库根目录的 `VERSION` 文件里（例如 `1.0.0`），打包时用它命名安装包，例如 `Hear-1.0.0.ipa`。之前的版本已改为 0.x.y（例如 4.3 → 0.4.3）。
