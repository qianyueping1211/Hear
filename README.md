# 听见 (Hear)

面向 **iPhone / iPad 与 Windows** 的实时语音翻译与会议同传工具。支持本机离线推理，也可连接自建的局域网/云端模型服务。

| 平台 / 产物 | 版本 | 下载与文档 |
| --- | --- | --- |
| iPhone / iPad（iOS / iPadOS 18+） | `0.4.119` | [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) |
| Windows x64 客户端 | `0.1.55` | [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) · [桌面端说明](apps/desktop/README.md) |
| Windows x64 模型服务端 | `Win-Server 1.0.3` | [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) · [服务端说明](server/README.md) |
| macOS (Apple Silicon) 模型服务端 | `Apple-Server 1.0.4` | [GitHub Releases](https://github.com/qianyueping1211/Hear/releases) · [服务端说明](server/README.md) |

> 完整产品架构与接口说明请查看 **[docs/index.html](docs/index.html)**（下载后用浏览器打开）。Android、鸿蒙与 macOS 客户端暂未发布。

---

## 核心特性

### iPhone / iPad 端
- **多模式交互**：支持实时双向自动语种翻译、对话模式，以及 **iPad 专属桌面工作台**（面对面 180° 分屏 `⌘1`、高对比全屏字幕看板 `⌘2`）。
- **离线与云端自由组合**：本机 SenseVoice（CPU/AMX 加速，2~3 秒完成加载）+ 腾讯 Hy-MT2-1.8B 离线翻译；也可按需切换至苹果系统引擎或自建云端服务。
- **自然播报与克隆**：系统语音支持基于人声基频自动匹配男女声；开启云端 Qwen3-TTS 可使用克隆音色播报。
- **高效复盘**：支持说话人区分、自定义术语表、灵动岛/锁屏实时译文、iCloud 同步，以及 5 套大模型一键总结模板。

### Windows 桌面端
- **会议同传模式**：内置双路虚拟声卡（`VB-Cable` + `Hi-Fi Cable`）一键自动安装与独立检测；仅在「会议同传 + 录音中」自动在系统层启用，停止录音或切回面对面自动禁用；支持原声自动压低（DuckGuard）。
- **全双工采集与字幕**：支持系统内录 + 麦克风双路采集、NLMS AEC 防回声、独立置顶透明悬浮字幕（支持穿透锁定与防共享录屏）。
- **原生语音与克隆**：内置 WinRT OneCore 语音引擎（支持中文男女声与自动性别匹配）及云端 Qwen3-TTS 声音克隆。
- **同步总结模板**：内置与 iOS 一致的 5 套一键总结模板（德鲁克会议纪要、简明摘要、行动项清单、双语要点、沟通访谈），支持 `[mm:ss]` 时间锚点跳转回放。

### 独立模型服务端（可选）
- 提供 **Win-Server**（内置便携 Python）与 **Apple-Server**（预编译 Metal GPU `llama-server`）开箱即用整合包。
- 统一通过 `8000` 端口提供 SenseVoice + Whisper 识别、Hy-MT2（1.8B / 7B / 30B-A3B）翻译、Qwen3-TTS 声音克隆及口令管理后台（`127.0.0.1:8443/admin/`）。

---

## 快速开始

- **Windows 客户端**：从 [Releases](https://github.com/qianyueping1211/Hear/releases) 下载 `Hear-Win-*.exe` 安装。开启会议同传时，在「设置」中按提示一键安装缺失的虚拟声卡即可。
- **iPhone / iPad 客户端**：从 [Releases](https://github.com/qianyueping1211/Hear/releases) 下载 `Hear-iOS-*.ipa`，通过 [Sideloadly](https://sideloadly.io) 使用免费 Apple ID 签名安装（每 7 天覆盖安装一次，模型和历史均保留）；有 Mac 也可在仓库根目录运行 `bash setup.sh` 后用 Xcode 安装。首次使用可直接在 App 内下载离线模型（国内可在设置中切换 `hf-mirror` 源）。
- **自建模型服务端**：从 [Releases](https://github.com/qianyueping1211/Hear/releases) 下载对应平台整合包，Windows 双击 `start-hear-cloud.bat`、macOS 双击 `听见服务端.app`，将控制台输出的地址填入客户端即可。详细参数与防火墙说明见 [server/README.md](server/README.md)。

---

## 项目结构

```text
apps/ios/            iPhone / iPad App 与灵动岛扩展（Swift / SwiftUI）
apps/desktop/        Windows 桌面端（Tauri v2 / Rust / React）
server/              跨端共用模型服务端（Python / llama.cpp）
docs/index.html      完整产品与技术架构文档
.github/workflows/   各端自动构建与 Release 发布工作流
```
