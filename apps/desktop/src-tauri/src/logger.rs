use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager};

const MAX_LOG_BYTES: u64 = 2 * 1024 * 1024;

static LOG_PATH: OnceLock<PathBuf> = OnceLock::new();
static LOG_LOCK: Mutex<()> = Mutex::new(());
static LOG_ENABLED: AtomicBool = AtomicBool::new(false);

pub fn set_enabled(enabled: bool) {
    LOG_ENABLED.store(enabled, Ordering::Relaxed);
}

pub fn init(app: &AppHandle) {
    let dir = app
        .path()
        .app_config_dir()
        .ok()
        .map(|d| d.join("logs"))
        .unwrap_or_else(|| std::env::temp_dir().join("Hear-Logs"));
    let _ = fs::create_dir_all(&dir);
    let path = dir.join("hear-desktop.log");
    let _ = LOG_PATH.set(path);
    info("Hear Desktop 日志系统已初始化");
}

pub fn log_dir(app: &AppHandle) -> PathBuf {
    if let Some(p) = LOG_PATH.get() {
        if let Some(parent) = p.parent() {
            let _ = fs::create_dir_all(parent);
            return parent.to_path_buf();
        }
    }
    let dir = app
        .path()
        .app_config_dir()
        .ok()
        .map(|d| d.join("logs"))
        .unwrap_or_else(|| std::env::temp_dir().join("Hear-Logs"));
    let _ = fs::create_dir_all(&dir);
    dir
}

pub fn info(msg: impl AsRef<str>) {
    write_line("INFO", msg.as_ref());
}

pub fn warn(msg: impl AsRef<str>) {
    write_line("WARN", msg.as_ref());
}

pub fn error(msg: impl AsRef<str>) {
    write_line("ERROR", msg.as_ref());
}

fn write_line(level: &str, msg: &str) {
    if !LOG_ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let Some(path) = LOG_PATH.get() else {
        return;
    };
    let Ok(_guard) = LOG_LOCK.lock() else {
        return;
    };
    if let Ok(meta) = fs::metadata(path) {
        if meta.len() >= MAX_LOG_BYTES {
            let backup = path.with_extension("log.1");
            let _ = fs::remove_file(&backup);
            let _ = fs::rename(path, &backup);
        }
    }
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "[{}][{}] {}", ts, level, msg);
    }
}

pub fn open_log_dir(app: &AppHandle) -> Result<(), String> {
    let dir = log_dir(app);
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(&dir)
            .spawn()
            .map_err(|e| format!("打开日志目录失败：{}", e))?;
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&dir)
            .spawn()
            .map_err(|e| format!("打开日志目录失败：{}", e))?;
        return Ok(());
    }
    #[cfg(all(not(target_os = "windows"), not(target_os = "macos")))]
    {
        let _ = dir;
        Ok(())
    }
}
