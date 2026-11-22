//! macOS 平台适配层（Phase 3 将接入 ScreenCaptureKit 系统/单应用内录与 NSWindow sharingType）
use tauri::WebviewWindow;

pub struct ChildProcessGuard;

impl ChildProcessGuard {
    pub fn new() -> Self {
        Self
    }

    pub fn attach_pid(&self, _pid: u32) {
        // Phase 3: 通过进程组与退出钩子清理 macOS Sidecar 子进程树
    }
}

pub fn apply_subtitle_overlay_traits(
    _window: &WebviewWindow,
    _click_through: bool,
    _exclude_from_capture: bool,
) -> Result<(), String> {
    // Tauri 的 set_ignore_cursor_events 已处理 NSWindow.ignoresMouseEvents；
    // Phase 3 补充 NSWindow.setSharingType(.none) 实现防录屏/防共享。
    Ok(())
}
