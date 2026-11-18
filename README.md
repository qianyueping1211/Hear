# 听见 (Hear)

iPhone 上的**完全本地**实时语音翻译。不联网、不上传，说话就翻译。

- 选两种语言（默认 中文 ⇄ English），点一下开始，之后直接说话
- 自动判断说的是哪种语言，翻译成另一种，并可朗读出来
- 语音识别：Whisper large-v3 turbo（WhisperKit，跑在神经网络引擎上）
- 翻译：腾讯 Hy-MT2-1.8B（llama.cpp，跑在 GPU 上）
- 支持上下文连贯翻译、自定义术语表
- 适配 iPhone 16 Pro / Pro Max 等 8GB 内存机型，iOS 18+

---

## 安装方法（二选一）

不需要付费开发者账号。免费 Apple ID 签名的 App 有效期 7 天，到期后**覆盖安装**一次即可。不要先删除 App，模型和设置都会保留，不用重新下载。

### 方法 A：直接下载安装包 + Sideloadly 安装（不用学 Xcode，Windows 也行）

1. 打开本仓库右侧的 **Releases（发行版）**，进入最新版本，下载 `Hear-版本号.ipa`（例如 `Hear-3.4.ipa`）。不用登录。
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

- **朗读开/关**：开着时，翻译结果会读出来；朗读期间麦克风自动暂停，避免回声。
- **上下文开**：参考前两句来翻译，代词和语气更连贯。
- **术语表**（设置里）：每行 `原文=译文`，比如人名、公司名、专业词。
- **灵敏度 / 停顿时长**：环境吵就调高灵敏度数值；想更快出结果，就把停顿时长调短。
- 对话页长按某一句可以修改原文并重新翻译；在历史记录里长按可以复制或重新朗读。
- 想让朗读更自然：**设置 → 辅助功能 → 朗读内容 → 声音**，下载“增强版/高级版”中英文语音。

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
└── Views/                       界面
project.yml                      XcodeGen 工程描述
setup.sh                         Mac 一键生成工程
scripts/fetch_llama.sh           下载 llama.cpp 的 iOS 框架
.github/workflows/build-ipa.yml  GitHub 自动打包 ipa
```

## 常见问题

- **打包失败（Actions 变红）**：点进失败的任务，下载 `build-log`，把里面带 `error:` 的几行发给 Claude 修。
- **llama.cpp 新版本改了接口导致编译错误**：可以固定版本。在 workflow 的 `env` 里加 `LLAMA_TAG: b7xxx`（填一个能用的版本号）。
- **免费账号限制**：同时最多 3 个自签 App；每 7 天需要重签。
- **安装包文件名**：从 3.4 起，Releases 里的安装包文件名带版本号，例如 `Hear-3.4.ipa`。
