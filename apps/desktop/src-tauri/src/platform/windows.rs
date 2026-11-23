use tauri::WebviewWindow;
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::{
    GetWindowLongPtrW, SetWindowDisplayAffinity, SetWindowLongPtrW, GWL_EXSTYLE,
    WDA_EXCLUDEFROMCAPTURE, WDA_NONE, WS_EX_LAYERED, WS_EX_TRANSPARENT,
};

/// 应用 Windows 悬浮字幕原生属性：鼠标穿透 + 防共享/防录屏 (WDA_EXCLUDEFROMCAPTURE)
pub fn apply_subtitle_overlay_traits(
    window: &WebviewWindow,
    click_through: bool,
    exclude_from_capture: bool,
) -> Result<(), String> {
    let raw_hwnd = window.hwnd().map_err(|e| e.to_string())?;
    let hwnd = HWND(raw_hwnd.0 as *mut std::ffi::c_void);
    unsafe {
        let ex_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let next_style = if click_through {
            ex_style | (WS_EX_LAYERED.0 as isize) | (WS_EX_TRANSPARENT.0 as isize)
        } else {
            ex_style & !(WS_EX_TRANSPARENT.0 as isize)
        };
        let _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, next_style);

        let affinity = if exclude_from_capture {
            WDA_EXCLUDEFROMCAPTURE
        } else {
            WDA_NONE
        };
        let _ = SetWindowDisplayAffinity(hwnd, affinity);
    }
    Ok(())
}
