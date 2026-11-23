# Hear Desktop（Windows x64 / 后续 macOS）

基于 **Tauri v2（Rust + React/TypeScript/Tailwind）** 构建的听见桌面实时翻译与悬浮字幕客户端。客户端不负责启动或管理服务端进程，模型服务由服务端独立运行与维护，客户端通过配置本机或远端服务地址连接使用。

## 目录结构

- `src/windows/main/`：主工作台（完整录音时间轴、双向定位波形播放器、一键总结时间锚点、模型服务连接测试与状态展示、悬浮字幕样式设置）
- `src/windows/subtitle/`：独立悬浮字幕窗（透明置顶、自定义背景色与透明度、鼠标穿透锁定、防共享录屏、悬停工具栏）
- `src-tauri/src/`：
  - `state.rs`：显式状态机与客户端配置/状态模型
  - `platform/`：平台适配层（`windows.rs` Win32 穿透与防录屏；`macos.rs` 预留）
  - `cloud/`：`HearCloudClient`（支持 `/health` 与 `/v1/auth/check` 连接测试、SSE 流式 `/v1/translate`）
  - `vad/`：512 采样对齐的环形缓冲 `Segmenter`（含单元测试）
  - `recorder/`：防崩溃流式 WAV 录音器与 50ms 波形峰值生成器（含单元测试）

## 本地开发运行（Windows x64）

1. 安装 [Node.js 20 LTS](https://nodejs.org/) 与 [Rustup (MSVC)](https://rustup.rs/)（Visual Studio 需勾选「使用 C++ 的桌面开发」）。
2. 安装前端依赖并启动开发模式：
   ```powershell
   cd apps\desktop
   npm install
   npm run tauri dev
   ```
3. 运行 Rust 核心单元测试（断句器与流式 WAV 录音器）：
   ```powershell
   cd apps\desktop\src-tauri
   cargo test
   ```
4. 推送到 GitHub 后，`.github/workflows/build-windows.yml` 会在 `windows-latest` 自动构建并发布 Windows 安装包：
   - 版本号独立管理于 `apps/desktop/VERSION`（当前 `0.1.2`）
   - GitHub Release 标题：`听见 Windows 0.1.2`（Tag：`win-v0.1.2`）
   - 安装包文件名：`Hear-Win-0.1.2.exe`
