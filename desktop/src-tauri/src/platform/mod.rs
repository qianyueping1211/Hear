use crate::state::{AudioCaptureMode, AudioSourceOption};
use tauri::WebviewWindow;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
pub use windows as os;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos as os;

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
mod fallback {
    use tauri::WebviewWindow;

    pub struct ChildProcessGuard;
    impl ChildProcessGuard {
        pub fn new() -> Self {
            Self
        }
        pub fn attach_pid(&self, _pid: u32) {}
    }

    pub fn apply_subtitle_overlay_traits(
        _window: &WebviewWindow,
        _click_through: bool,
        _exclude_from_capture: bool,
    ) -> Result<(), String> {
        Ok(())
    }
}
#[cfg(not(any(target_os = "windows", target_os = "macos")))]
pub use fallback as os;

/// 列出当前桌面端可用的基础音频源（Sprint 2 将接入实时发声应用枚举）
pub fn default_audio_sources() -> Vec<AudioSourceOption> {
    vec![
        AudioSourceOption {
            id: "system_loopback".into(),
            label: "系统声音内录（自动排除听见自身）".into(),
            kind: AudioCaptureMode::SystemLoopback,
            process_id: None,
            process_name: None,
        },
        AudioSourceOption {
            id: "app_loopback".into(),
            label: "单应用进程内录（选择浏览器/会议软件）".into(),
            kind: AudioCaptureMode::AppLoopback,
            process_id: None,
            process_name: None,
        },
        AudioSourceOption {
            id: "microphone".into(),
            label: "默认麦克风".into(),
            kind: AudioCaptureMode::Microphone,
            process_id: None,
            process_name: None,
        },
        AudioSourceOption {
            id: "dual_mix".into(),
            label: "双路混合（系统声=对方 / 麦克风=我）".into(),
            kind: AudioCaptureMode::DualMix,
            process_id: None,
            process_name: None,
        },
    ]
}

pub fn apply_overlay_traits(
    window: &WebviewWindow,
    click_through: bool,
    exclude_from_capture: bool,
) -> Result<(), String> {
    window
        .set_ignore_cursor_events(click_through)
        .map_err(|e| e.to_string())?;
    os::apply_subtitle_overlay_traits(window, click_through, exclude_from_capture)
}
