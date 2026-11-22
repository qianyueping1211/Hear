# Hear Desktop（Windows x64 预览版）

基于 **Tauri v2（Rust + React/TypeScript/Tailwind）** 构建的听见 Windows 桌面实时翻译与悬浮字幕客户端，与 iPhone 端共用 `server/` 模型服务接口。[下载 Windows 0.1.0 预览版安装包](https://github.com/qianyueping1211/Hear/releases/tag/win-v0.1.0)。macOS 适配尚未完成。

## 目录结构

- `src/windows/main/`：主工作台（完整录音时间轴、双向定位波形播放器、一键总结时间锚点、本机/云端双开关设置弹窗）
- `src/windows/subtitle/`：独立悬浮字幕窗（透明置顶、鼠标穿透锁定、防共享录屏、悬停工具栏）
- `src-tauri/src/`：
  - `state.rs`：显式状态机与数据模型
  - `platform/`：平台适配层（`windows.rs` Win32 穿透/防录屏/Job Object；`macos.rs` Phase 3 预留）
  - `sidecar/`：`LocalEngineManager`（托管 `server/`，实现「仅本机 127.0.0.1」与「局域网共享给 iPhone」双开关）
  - `cloud/`：`HearCloudClient`（支持 `/health`、`/v1/pair`、SSE 流式 `/v1/translate`、`X-Hear-Device-Id` 预览隔离）
  - `vad/`：512 采样对齐的环形缓冲 `Segmenter`（含单元测试）
  - `recorder/`：防崩溃流式 WAV 录音器与 50ms 波形峰值生成器（含单元测试）

## 本地开发运行（Windows x64）

1. 安装 [Node.js 20 LTS](https://nodejs.org/) 与 [Rustup (MSVC)](https://rustup.rs/)（Visual Studio 需勾选「使用 C++ 的桌面开发」）。
2. 安装前端依赖并启动开发模式（开发期自动调用同仓库 `../server/hear_cloud.py`）：
   ```powershell
   cd desktop
   npm install
   npm run tauri dev
   ```
3. 运行 Rust 核心单元测试（断句器与流式 WAV 录音器）：
   ```powershell
   cd desktop\src-tauri
   cargo test
   ```
4. 也可直接推送到 GitHub，通过 `.github/workflows/build-windows.yml` 在 `windows-latest` 自动构建并发布 Windows 安装包：
   - 版本号独立管理于 `desktop/VERSION`（如 `0.1.0`）
   - GitHub Release 标题：`听见 Windows 0.1.0`（Tag：`win-v0.1.0`）
   - 安装包文件名：`Hear-Win-0.1.0.exe`（NSIS 单文件安装程序，内置 `hear-server` Sidecar）
