use std::mem::size_of;
use tauri::WebviewWindow;
use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE};
use windows::Win32::UI::WindowsAndMessaging::{
    GetWindowLongPtrW, SetWindowDisplayAffinity, SetWindowLongPtrW, GWL_EXSTYLE,
    WDA_EXCLUDEFROMCAPTURE, WDA_NONE, WS_EX_LAYERED, WS_EX_TRANSPARENT,
};

/// Win32 Job Object：主进程正常退出或崩溃时，内核级自动终止所有 Sidecar 与 llama-server 子进程
pub struct ChildProcessGuard {
    job: Option<HANDLE>,
}

unsafe impl Send for ChildProcessGuard {}
unsafe impl Sync for ChildProcessGuard {}

impl ChildProcessGuard {
    pub fn new() -> Self {
        unsafe {
            let Ok(job) = CreateJobObjectW(None, None) else {
                return Self { job: None };
            };
            let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let ok = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            if ok.is_err() {
                let _ = CloseHandle(job);
                return Self { job: None };
            }
            Self { job: Some(job) }
        }
    }

    pub fn attach_pid(&self, pid: u32) {
        let Some(job) = self.job else { return };
        unsafe {
            if let Ok(proc_handle) = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, pid)
            {
                let _ = AssignProcessToJobObject(job, proc_handle);
                let _ = CloseHandle(proc_handle);
            }
        }
    }
}

impl Drop for ChildProcessGuard {
    fn drop(&mut self) {
        if let Some(job) = self.job.take() {
            unsafe {
                let _ = CloseHandle(job);
            }
        }
    }
}

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
