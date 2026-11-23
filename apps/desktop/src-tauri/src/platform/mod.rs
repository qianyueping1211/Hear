use crate::state::{AudioCaptureMode, AudioSourceOption};
use tauri::WebviewWindow;

#[cfg(target_os = "windows")]
pub mod windows;
#[cfg(target_os = "windows")]
pub use windows as os;

#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "macos")]
pub use macos as os;

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
pub mod fallback {
    use tauri::WebviewWindow;

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

/// 列出当前桌面端可用的基础音频源
pub fn default_audio_sources() -> Vec<AudioSourceOption> {
    vec![
        AudioSourceOption {
            id: "dual_mix".into(),
            label: "双路混合（电脑播放声 + 麦克风说话声）".into(),
            kind: AudioCaptureMode::DualMix,
            process_id: None,
            process_name: None,
        },
        AudioSourceOption {
            id: "microphone".into(),
            label: "默认麦克风（录人声说话）".into(),
            kind: AudioCaptureMode::Microphone,
            process_id: None,
            process_name: None,
        },
        AudioSourceOption {
            id: "system_loopback".into(),
            label: "系统声音内录（仅录电脑播放的声音）".into(),
            kind: AudioCaptureMode::SystemLoopback,
            process_id: None,
            process_name: None,
        },
        AudioSourceOption {
            id: "app_loopback".into(),
            label: "单应用进程内录（暂同系统内录）".into(),
            kind: AudioCaptureMode::AppLoopback,
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
