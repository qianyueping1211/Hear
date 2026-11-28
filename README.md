# 听见 (Hear)

面向 **iPhone / iPad 与 Windows** 的实时语音翻译与会议同传工具。支持本机离线推理，也可连接自建的局域网/云端模型服务。

| 平台 / 产物 | 版本 | 下载与文档 |
| --- | --- | --- |
| iPhone / iPad（iOS / iPadOS 18+） | `0.4.164` | [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) · [SideStore 官方源](https://raw.githubusercontent.com/qianyueping1211/Hear/main/docs/sidestore.json) |
| Windows x64 客户端 | `0.1.78` | [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) · [桌面端说明](apps/desktop/README.md) |
| Windows x64 模型服务端 | `Win-Server 1.0.9` | [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) · [服务端说明](server/README.md) |
| macOS (Apple Silicon) 模型服务端 | `Apple-Server 1.0.10` | [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) · [服务端说明](server/README.md) |

> 完整产品架构与接口说明请查看 **[docs/index.html](docs/index.html)**（下载后用浏览器打开）。Android、鸿蒙与 macOS 客户端暂未发布。

---

## 核心特性

### iPhone / iPad 端
- **四大翻译模式与 iOS 26 液态玻璃导航**：支持**聆听翻译**（左侧支持「自动识别」或指定单一语种 → 右侧统一译为目标语种，通栏说话人卡片）、**单侧自动**（单按钮自动双向识别选定双语，第三语种自动过滤并横线提醒）、**并排双键**（左右独立按钮，仅启单语种识别器）、**面对面**（180° 上下分屏）；底部采用 iOS 26 原生 Liquid Glass 滑动透镜与浮动线框示意图预览，仅「并排 ↔ 面对面」共用内容；另有 **iPad 专属桌面工作台**（`⌘1` 分屏 / `⌘2` 字幕看板）。
- **离线、系统与云端自由组合**：本机 SenseVoice（CPU/AMX 加速，2~3 秒就绪）+ 腾讯 Hy-MT2-1.8B 离线翻译；iOS 26+ 支持苹果系统听写（配独立 `sherpa-onnx` Whisper-Tiny 99 语种裁判）与系统翻译；也可按需连接自建云端服务。
- **客户端直连微软 Edge-TTS 与原声克隆**：新增 **iPhone 直连微软 Edge-TTS**（13 国男女神经语音，免电脑端中转、毫秒级原生解码，自动带云端/系统兜底）；系统语音支持基于人声基频（F0）自动匹配男女声；开启云端 Qwen3-TTS 可使用原声克隆播报。
- **隐私与高效复盘**：支持说话人区分、自定义术语表、灵动岛/锁屏实时译文、iCloud 同步、隐私日志默认不记录对话原文/译文，以及 5 套大模型一键总结模板。

### Windows 桌面端
- **会议同传模式**：内置双路虚拟声卡（`VB-Cable` + `Hi-Fi Cable`）一键自动安装与独立检测；仅在「会议同传 + 录音中」自动在系统层启用，停止录音或切回面对面自动禁用；支持原声自动压低（DuckGuard）。
- **13 国语种模型感知与全双工字幕**：与 iOS 对齐全部 13 国语种（含阿联酋阿语等），按服务端能力自动过滤与回落；支持系统内录 + 麦克风双路采集、NLMS AEC 防回声、独立置顶透明悬浮字幕（穿透锁定与防共享录屏）及平滑自动跟随滚动。
- **原生语音、Edge-TTS 与隐私控制**：内置 WinRT OneCore 语音引擎（男女声自动匹配）、云端 Edge-TTS / Qwen3-TTS；支持「记录对话内容日志」隐私开关（默认关闭并同步透传至服务端）。
- **同步总结模板**：内置与 iOS 一致的 5 套一键总结模板（德鲁克会议纪要、简明摘要、行动项清单、双语要点、沟通访谈），支持 `[mm:ss]` 时间锚点跳转回放。

### 独立模型服务端（可选）
- 提供 **Win-Server**（内置便携 Python）与 **Apple-Server**（预编译 Metal GPU `llama-server`）开箱即用整合包。
- 统一通过 `8000` 端口提供 SenseVoice + Whisper 智能混合语种识别路由（如 `zh ⇄ ar` 中文极速首出、阿语直通 Whisper）、Hy-MT2（1.8B / 7B / 30B-A3B）翻译、Qwen3-TTS 声音克隆、微软 Edge-TTS 神经语音兜底及口令管理后台（`127.0.0.1:8443/admin/`），默认不记录对话内容日志。

---

## 快速开始

- **Windows 客户端**：从 [Releases](https://github.com/qianyueping1211/Hear/releases) 下载 `Hear-Win-*.exe` 安装。开启会议同传时，在「设置」中按提示一键安装缺失的虚拟声卡即可。
- **iPhone / iPad 客户端**：
  - **方式一：SideStore / AltStore 官方源安装（推荐，免电脑无线更新）**
    1. 打开 **SideStore**（或 AltStore）→ 进入 **Sources（源）** → 点击右上角 **`+`**。
    2. 粘贴官方源地址并添加（每次发布新版本会自动同步更新）：
       ```text
       https://raw.githubusercontent.com/qianyueping1211/Hear/main/docs/sidestore.json
       ```
    3. 进入「听见 Hear 官方源」即可直接安装或覆盖更新（模型与历史记录均保留；如国内访问较慢可先开启代理）。
  - **方式二：手动下载 IPA / Xcode 安装**
    - 从 [Releases](https://github.com/qianyueping1211/Hear/releases) 下载 `Hear-iOS-*.ipa`，通过 [Sideloadly](https://sideloadly.io) 使用免费 Apple ID 签名安装（每 7 天覆盖安装一次，模型和历史均保留）；有 Mac 也可在仓库根目录运行 `bash setup.sh` 后用 Xcode 安装。首次使用可直接在 App 内下载离线模型（国内可在设置中切换 `hf-mirror` 源）。
- **自建模型服务端**：从 [Releases](https://github.com/qianyueping1211/Hear/releases) 下载对应平台整合包，Windows 双击 `start-hear-cloud.bat`、macOS 双击 `听见服务端.app`，将控制台输出的地址填入客户端即可。详细参数与防火墙说明见 [server/README.md](server/README.md)。

---

## 项目结构

```text
apps/ios/            iPhone / iPad App 与灵动岛扩展（Swift / SwiftUI）
apps/desktop/        Windows 桌面端（Tauri v2 / Rust / React）
server/              跨端共用模型服务端（Python / llama.cpp）
docs/index.html      完整产品与技术架构文档
docs/sidestore.json  SideStore / AltStore 官方软件源（CI 自动更新）
.github/workflows/   各端自动构建与 Release 发布工作流
```
