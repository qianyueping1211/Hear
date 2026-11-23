//! macOS 平台适配层（Phase 3 将接入 ScreenCaptureKit 系统/单应用内录与 NSWindow sharingType）
use tauri::WebviewWindow;

pub fn apply_subtitle_overlay_traits(
    _window: &WebviewWindow,
    _click_through: bool,
    _exclude_from_capture: bool,
) -> Result<(), String> {
    // Tauri 的 set_ignore_cursor_events 已处理 NSWindow.ignoresMouseEvents；
    // Phase 3 补充 NSWindow.setSharingType(.none) 实现防录屏/防共享。
    Ok(())
}
