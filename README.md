# 听见 (Hear)

听见是面向 **iPhone 和 Windows** 的实时语音翻译项目。iPhone App 支持本机识别、翻译和朗读，也可以连接模型服务；Windows 桌面端提供翻译工作台、悬浮字幕和本机模型服务。选择本地模型并完成下载后，iPhone 可以离线使用。

| 当前平台 / 产物 | 版本 | 下载与说明 |
| --- | --- | --- |
| iPhone（iOS 18+） | 0.4.106 | [Releases · 听见 iOS](https://github.com/qianyueping1211/Hear/releases) |
| Windows x64 客户端 | 0.1.36 | [Releases · 听见 Windows](https://github.com/qianyueping1211/Hear/releases) · [桌面端说明](apps/desktop/README.md) |
| Windows x64 服务端 | Win-Server 1.0.1 | [Releases · 听见 Win-Server](https://github.com/qianyueping1211/Hear/releases) · [服务端说明](server/README.md) |
| Mac Studio / Apple Silicon 服务端 | Apple-Server 1.0.2 | [Releases · 听见 Apple-Server](https://github.com/qianyueping1211/Hear/releases) · [服务端说明](server/README.md) |

iPad、Android、鸿蒙和 macOS 客户端尚未发布；仓库中的 Android、鸿蒙目录目前只是预留。

### iPhone 版

- 选两种语言（默认 中文 ⇄ English），点一下开始，之后直接说话
- 自动判断说的是哪种语言，翻译成另一种，并可朗读出来
- 语音识别：本机 SenseVoice Small（Core ML）或云端服务
- 翻译：腾讯 Hy-MT2-1.8B（llama.cpp，跑在 GPU 上）
- 支持上下文连贯翻译、自定义术语表
- 适配 iPhone 16 Pro / Pro Max 等 8GB 内存机型，iOS 18+

📄 产品与技术介绍（两个平台的定位、iPhone 功能架构、服务接口）：**[docs/index.html](docs/index.html)**
（下载后用浏览器打开就行）

🪟 Windows 桌面程序见 **[apps/desktop/README.md](apps/desktop/README.md)**。如果想用 Windows 或 Mac Studio 电脑为客户端提供模型服务，见 **[server/README.md](server/README.md)**。

---

## Windows 桌面端

从 [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) 下载最新版 `Hear-Win-*.exe` 并安装。桌面程序支持双路采集、悬浮字幕、NLMS AEC 全双工防回声、固定声纹录制与自动更新；功能与开发说明见 [apps/desktop/README.md](apps/desktop/README.md)。

`server/windows/start-hear-cloud.bat`（及独立发布的 **听见 Win-Server** 整合包）与 `server/start-macos.sh`（**听见 Apple-Server** 整合包）是独立的模型服务端，供 iPhone 与 Windows 客户端局域网或公网连接。

## iPhone 安装方法（二选一）

不需要付费开发者账号。免费 Apple ID 签名的 App 有效期 7 天，到期后**覆盖安装**一次即可。不要先删除 App，模型和设置都会保留，不用重新下载。

### 方法 A：直接下载安装包 + Sideloadly 安装（不用学 Xcode，Windows 也行）

1. 打开 [GitHub Releases](https://github.com/qianyueping1211/Hear/releases)，下载最新的 `Hear-iOS-*.ipa`。以后更新时从 Releases 中选名称带 **iOS** 的版本。
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
  - **本地最快：SenseVoice**：说完马上出字（约 240 MB，只支持中、英、日、韩）。
  - **云端综合：SenseVoice + Whisper**：SenseVoice 先出结果，服务端再用 Whisper 校正。
  - **iOS 系统听写**：在支持的设备上实时显示听写结果。
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
最后打印一个地址，填到手机 App 的 **功能设置 → 模型管理 → 云端模型** 里，
再把「引擎管理」里需要的模型改成「云端：自己电脑上的服务」。

**更省事：直接下载独立服务端整合包或运行 `server/windows/start-hear-cloud.bat`**（Windows / macOS）

- **Windows**：从 Releases 下载 **听见 Win-Server**（内置便携 Python 3.12 与全套依赖），解压后双击 `start-hear-cloud.bat` 即可启动；源码内脚本位于 `server/windows/start-hear-cloud.bat` 与 `server/windows/start-hear-token-admin.bat`。
- **macOS (Apple Silicon / Mac Studio)**：从 Releases 下载 **听见 Apple-Server**（内置 Metal GPU 预编译 `llama-server`），解压后双击 `听见服务端.app` 或 `启动听见服务端.command`，支持一键安装开机自启与口令管理后台（`http://127.0.0.1:8443/admin/`）。

Intel 核显（NPU 也行）机器上，翻译可以走核显的 Vulkan 或 NPU 的 OpenVINO 后端；
WSL2 里访问不到 NPU，所以想用满硬件就别装 WSL。完整说明（端口、防火墙、性能、常见问题）
看 [server/README.md](server/README.md)。

---

## 项目结构

```
apps/ios/                       iPhone App 与实时活动扩展
├── Hear/                       采集、识别、翻译、朗读及界面
├── HearLiveActivity/           灵动岛与锁屏界面
├── Frameworks/                 构建时下载的 iOS 框架
├── tests/                      iOS 会话回归测试
├── project.yml                 XcodeGen 工程描述
└── VERSION                     iOS 独立版本号
apps/desktop/                   Windows 桌面端及未来 macOS 桌面端
server/                         桌面端与移动端共用的模型服务
├── windows/                    Windows 一键启动与口令管理 .bat
├── macos/                      macOS Apple Silicon 整合包构建脚本
└── start-macos.sh              Mac Studio Metal GPU 服务端启动器
branding/                       两端共用的图标源文件
docs/index.html                 项目完整产品与技术介绍页
setup.sh                        Mac 一键生成 iOS 工程
scripts/fetch_llama.sh          下载 llama.cpp 的 iOS 框架
.github/workflows/              四端独立自动构建与发布工作流
```

`apps/android/` 和 `apps/harmony/` 已预留给未来的手机、平板客户端；同一平台在一个工程内适配不同屏幕。当前 iOS 工程仍只面向 iPhone，尚未开启 iPad 构建目标。

## 常见问题

- **打包失败（Actions 变红）**：点进失败的任务，下载 `build-log`，把里面带 `error:` 的几行发给 Claude 修。
- **llama.cpp 新版本改了接口导致编译错误**：可以固定版本。在 workflow 的 `env` 里加 `LLAMA_TAG: b7xxx`（填一个能用的版本号）。
- **打包显示 “The job was not acquired by Runner” 或 “Internal server error”**：这是 GitHub 自己的服务器临时出问题，和代码无关。进入这次打包，点右上角 **Re-run all jobs** 重新打包即可。
- **免费账号限制**：同时最多 3 个自签 App；每 7 天需要重签。
- **版本号**：三位数字，iOS 写在 `apps/ios/VERSION`（例如 `1.0.0`），Windows 写在 `apps/desktop/VERSION`。iOS 安装包按平台和版本号命名，例如 `Hear-iOS-1.0.0.ipa`。


## 声音克隆引擎

- iPhone 本机使用 **ZipVoice-Distill INT8 + Vocos**，支持中文和英文。需要与参考音频匹配的原文。
- 电脑云端随听见 Windows 服务使用 **Qwen3-TTS**。手机通过局域网提交克隆请求。

在「功能设置 → 引擎管理 → 声音克隆引擎」选「本机：ZipVoice INT8」后点「下载」。
App 会从 [官方发布](https://k2-fsa.github.io/sherpa/onnx/tts/zipvoice.html) 下载并校验模型和 Vocos。
也可以在「模型管理 → 本地模型 → 声音克隆」下载、重新下载或导入已有模型目录。
未安装或模型不可用时会用系统声音朗读。旧版的本地 Qwen 权重不会被加载。

官方模型权重采用 CC BY-NC 许可，详见 [ZipVoice 模型卡](https://huggingface.co/k2-fsa/ZipVoice)。

## Windows 启动器更新

仓库中的 `start-hear-cloud.bat` 使用同目录服务源码。单独放置时，会在旁边的
`Hear\server` 同步同一份 GitHub 源码快照，已下载模型、证书与设置保留。
旧版只逐个更新几个文件的启动器需要换成仓库中的新版。
运行 `start-hear-cloud.bat --check` 可只检查启动所需文件。

## 实时翻译中的说话人

使用电脑端云端识别时，App 会给已断句的发言标上「说话人 1」等标签。
在实时页或历史页点标签，可以改名，也可以把这句话改分给另一人。
生成总结时会使用当前的发言人姓名。要更新已有总结，可从历史页重新生成。
短句和判断不清的发言可能保持「未分配」；多人同时说话时可手动更正。
Windows 启动器会准备约 28 MB 的说话人模型。手机仅在当前对话中临时保留声音特征，
存档只保留编号、姓名和句子的归属。可在设置里关闭自动区分。
