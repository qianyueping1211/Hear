pub mod cloud;
pub mod config_store;
pub mod platform;
pub mod recorder;
pub mod state;
pub mod updater;
pub mod vad;

use cloud::HearCloudClient;
use config_store::{load_config, save_config, PersistedConfig};
use state::{
    AppSnapshot, AudioCaptureMode, AudioSourceOption, EngineSource, ServiceConfig,
    ServiceProbeResult, SessionMode, SubtitleStyle, TtsOutputSettings, UpdateCheckResult,
    UpdateConfig,
};
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tokio::sync::Mutex;

pub struct AppRuntime {
    pub snapshot: Mutex<AppSnapshot>,
    pub cloud: HearCloudClient,
}

impl AppRuntime {
    pub fn new() -> Self {
        Self {
            snapshot: Mutex::new(AppSnapshot::default()),
            cloud: HearCloudClient::new(),
        }
    }

    pub async fn persist(&self, app: &AppHandle) {
        let cfg = {
            let snap = self.snapshot.lock().await;
            PersistedConfig {
                service_config: snap.service_config.clone(),
                subtitle_style: snap.subtitle_style.clone(),
                tts_settings: snap.tts_settings.clone(),
                glossary: snap.glossary.clone(),
                update_config: snap.update_config.clone(),
            }
        };
        save_config(app, &cfg);
    }
}

#[tauri::command]
async fn get_snapshot(rt: State<'_, Arc<AppRuntime>>) -> Result<AppSnapshot, String> {
    Ok(rt.snapshot.lock().await.clone())
}

#[tauri::command]
async fn list_audio_sources() -> Result<Vec<AudioSourceOption>, String> {
    Ok(platform::default_audio_sources())
}

#[tauri::command]
async fn set_language_pair(
    rt: State<'_, Arc<AppRuntime>>,
    source_lang: String,
    target_lang: String,
    lock_source_lang: bool,
) -> Result<(), String> {
    let mut snap = rt.snapshot.lock().await;
    snap.source_lang = source_lang;
    snap.target_lang = target_lang;
    snap.lock_source_lang = lock_source_lang;
    Ok(())
}

#[tauri::command]
async fn set_capture_mode(
    rt: State<'_, Arc<AppRuntime>>,
    capture_mode: AudioCaptureMode,
    selected_app_pid: Option<u32>,
) -> Result<(), String> {
    let mut snap = rt.snapshot.lock().await;
    snap.capture_mode = capture_mode;
    snap.selected_app_pid = selected_app_pid;
    Ok(())
}

#[tauri::command]
async fn toggle_recording(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<SessionMode, String> {
    let mut snap = rt.snapshot.lock().await;
    snap.mode = if snap.mode == SessionMode::Recording {
        SessionMode::Idle
    } else {
        SessionMode::Recording
    };
    let mode = snap.mode;
    let _ = app.emit("session:mode", mode);
    Ok(mode)
}

#[tauri::command]
async fn clear_recording(rt: State<'_, Arc<AppRuntime>>) -> Result<(), String> {
    let mut snap = rt.snapshot.lock().await;
    snap.segments.clear();
    snap.live_partial_source.clear();
    snap.live_partial_translation.clear();
    snap.playback = Default::default();
    Ok(())
}

#[tauri::command]
async fn seek_playback(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    position_ms: u64,
    auto_play: bool,
) -> Result<(), String> {
    let (dur, playing) = {
        let mut snap = rt.snapshot.lock().await;
        snap.playback.position_ms = position_ms.min(snap.playback.duration_ms.max(position_ms));
        if auto_play {
            snap.playback.is_playing = true;
        }
        (snap.playback.duration_ms, snap.playback.is_playing)
    };
    let _ = app.emit(
        "playback:tick",
        serde_json::json!({
            "positionMs": position_ms,
            "durationMs": dur,
            "isPlaying": playing
        }),
    );
    Ok(())
}

#[tauri::command]
async fn set_playback_playing(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    playing: bool,
) -> Result<(), String> {
    let (pos, dur) = {
        let mut snap = rt.snapshot.lock().await;
        snap.playback.is_playing = playing;
        (snap.playback.position_ms, snap.playback.duration_ms)
    };
    let _ = app.emit(
        "playback:tick",
        serde_json::json!({
            "positionMs": pos,
            "durationMs": dur,
            "isPlaying": playing
        }),
    );
    Ok(())
}

#[tauri::command]
async fn set_playback_speed(rt: State<'_, Arc<AppRuntime>>, speed: f32) -> Result<(), String> {
    let mut snap = rt.snapshot.lock().await;
    snap.playback.speed = speed.clamp(0.5, 2.5);
    Ok(())
}

#[tauri::command]
async fn set_track_volumes(
    rt: State<'_, Arc<AppRuntime>>,
    system_volume: f32,
    mic_volume: f32,
) -> Result<(), String> {
    let mut snap = rt.snapshot.lock().await;
    snap.playback.system_volume = system_volume.clamp(0.0, 1.0);
    snap.playback.mic_volume = mic_volume.clamp(0.0, 1.0);
    Ok(())
}

#[tauri::command]
async fn set_subtitle_style(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    style: SubtitleStyle,
) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("subtitle") {
        if style.visible {
            let _ = win.show();
        } else {
            let _ = win.hide();
        }
        let _ = platform::apply_overlay_traits(&win, style.click_through, style.exclude_from_capture);
    }
    {
        let mut snap = rt.snapshot.lock().await;
        snap.subtitle_style = style.clone();
    }
    rt.persist(&app).await;
    let _ = app.emit("subtitle:style", style);
    Ok(())
}

/// 仅保存服务连接配置，不拉起或干预任何服务端进程
#[tauri::command]
async fn save_service_config(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    config: ServiceConfig,
) -> Result<ServiceConfig, String> {
    {
        let mut snap = rt.snapshot.lock().await;
        snap.service_config = config.clone();
    }
    rt.persist(&app).await;
    Ok(config)
}

/// 测试指定服务地址与口令的连通性及模型就绪状态（只读探测 /health 与 /v1/auth/check）
#[tauri::command]
async fn test_service_connection(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    target: EngineSource,
    address: String,
    access_token: String,
) -> Result<ServiceProbeResult, String> {
    let result = rt.cloud.test_connection(&address, &access_token).await;
    {
        let mut snap = rt.snapshot.lock().await;
        match target {
            EngineSource::Local => {
                snap.local_status = result.clone();
                let _ = app.emit("service:local_status", &result);
            }
            EngineSource::Cloud => {
                snap.cloud_status = result.clone();
                let _ = app.emit("service:cloud_status", &result);
            }
        }
    }
    Ok(result)
}

#[tauri::command]
async fn save_update_config(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    config: UpdateConfig,
) -> Result<UpdateConfig, String> {
    {
        let mut snap = rt.snapshot.lock().await;
        snap.update_config = config.clone();
    }
    rt.persist(&app).await;
    Ok(config)
}

#[tauri::command]
async fn check_for_updates(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    override_config: Option<UpdateConfig>,
) -> Result<UpdateCheckResult, String> {
    let cfg = match override_config {
        Some(c) => {
            {
                let mut snap = rt.snapshot.lock().await;
                snap.update_config = c.clone();
            }
            rt.persist(&app).await;
            c
        }
        None => rt.snapshot.lock().await.update_config.clone(),
    };
    let res = updater::check_for_updates(&cfg).await;
    {
        let mut snap = rt.snapshot.lock().await;
        snap.update_info = Some(res.clone());
    }
    let _ = app.emit("update:info", &res);
    Ok(res)
}

#[tauri::command]
async fn download_and_install_update(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<String, String> {
    let (token, asset_url, asset_name) = {
        let snap = rt.snapshot.lock().await;
        let info = snap
            .update_info
            .as_ref()
            .ok_or_else(|| "请先检查更新获取新版本信息".to_string())?;
        let url = info
            .asset_api_url
            .clone()
            .ok_or_else(|| "当前新版本未找到 .exe 安装包附件".to_string())?;
        let name = info
            .asset_name
            .clone()
            .unwrap_or_else(|| "Hear-Win-Update.exe".to_string());
        (snap.update_config.github_token.clone(), url, name)
    };

    let app_clone = app.clone();
    let mut last_emit = std::time::Instant::now();
    let path = updater::download_and_launch_installer(&asset_url, &asset_name, &token, |done, total| {
        if last_emit.elapsed().as_millis() >= 120 || (total > 0 && done >= total) {
            last_emit = std::time::Instant::now();
            let _ = app_clone.emit(
                "update:progress",
                serde_json::json!({ "downloaded": done, "total": total }),
            );
        }
    })
    .await?;

    Ok(path.to_string_lossy().to_string())
}

#[tauri::command]
async fn open_github_url(url: String) -> Result<(), String> {
    updater::open_github_url(&url)
}

#[tauri::command]
async fn set_tts_settings(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    settings: TtsOutputSettings,
) -> Result<(), String> {
    rt.snapshot.lock().await.tts_settings = settings;
    rt.persist(&app).await;
    Ok(())
}

#[tauri::command]
async fn set_glossary(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    glossary: String,
) -> Result<(), String> {
    rt.snapshot.lock().await.glossary = glossary;
    rt.persist(&app).await;
    Ok(())
}

#[tauri::command]
async fn retranslate_segment(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
    new_source: String,
) -> Result<(), String> {
    let (base_url, token, target_lang) = {
        let snap = rt.snapshot.lock().await;
        let (addr, tok) = match snap.service_config.mt_source {
            EngineSource::Local => (
                snap.service_config.local_service_address.clone(),
                snap.service_config.local_access_token.clone(),
            ),
            EngineSource::Cloud => (
                snap.service_config.cloud_service_address.clone(),
                snap.service_config.cloud_access_token.clone(),
            ),
        };
        (addr, tok, snap.target_lang.clone())
    };

    let prompt = format!("Translate to {}: {}", target_lang, new_source);
    let translated = rt
        .cloud
        .translate_stream(
            &base_url,
            &prompt,
            false,
            if token.trim().is_empty() {
                None
            } else {
                Some(&token)
            },
            |_| {},
        )
        .await?;

    let mut updated = None;
    {
        let mut snap = rt.snapshot.lock().await;
        if let Some(seg) = snap.segments.iter_mut().find(|s| s.id == id) {
            seg.source_text = new_source;
            seg.translated_text = translated;
            seg.status = "final".into();
            seg.is_edited = Some(true);
            updated = Some(seg.clone());
        }
    }
    if let Some(seg) = updated {
        let _ = app.emit("segment:upsert", seg);
    }
    Ok(())
}

#[tauri::command]
async fn generate_summary(
    _rt: State<'_, Arc<AppRuntime>>,
    template_id: String,
) -> Result<String, String> {
    Ok(format!(
        "### 一键总结预览（模板：{}）\n\n- [00:00] 当前为预览版框架输出，后续将接入完整流式 LLM 纪要生成与时间戳锚点。",
        template_id
    ))
}

#[tauri::command]
async fn import_media_file() -> Result<(), String> {
    Ok(())
}

fn show_main_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    if let Some(cfg) = app.config().app.windows.iter().find(|w| w.label == "main") {
        if let Ok(builder) = tauri::WebviewWindowBuilder::from_config(app, cfg) {
            if let Ok(w) = builder.build() {
                let _ = w.unminimize();
                let _ = w.show();
                let _ = w.set_focus();
            }
        }
    }
}

fn setup_tray(app: &AppHandle) -> tauri::Result<()> {
    let show_main = MenuItem::with_id(app, "show_main", "打开听见主工作台", true, None::<&str>)?;
    let toggle_sub = MenuItem::with_id(app, "toggle_sub", "显示 / 隐藏悬浮字幕", true, None::<&str>)?;
    let unlock_sub = MenuItem::with_id(app, "unlock_sub", "解锁悬浮字幕鼠标穿透", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "退出听见", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show_main, &toggle_sub, &unlock_sub, &quit])?;

    let mut builder = TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("听见 Hear — 桌面实时翻译与悬浮字幕")
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show_main" => {
                show_main_window(app);
            }
            "toggle_sub" => {
                if let Some(w) = app.get_webview_window("subtitle") {
                    if w.is_visible().unwrap_or(false) {
                        let _ = w.hide();
                    } else {
                        let _ = w.unminimize();
                        let _ = w.show();
                    }
                }
            }
            "unlock_sub" => {
                if let Some(w) = app.get_webview_window("subtitle") {
                    let _ = platform::apply_overlay_traits(&w, false, true);
                }
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| match event {
            TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            }
            | TrayIconEvent::DoubleClick {
                button: MouseButton::Left,
                ..
            } => {
                show_main_window(tray.app_handle());
            }
            _ => {}
        });
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    let _tray = builder.build(app)?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tracing_subscriber::fmt::init();
    let runtime = Arc::new(AppRuntime::new());
    let runtime_setup = runtime.clone();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(runtime)
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" || window.label() == "subtitle" {
                    // 点击关闭按钮时隐藏到系统托盘，避免窗口被销毁后无法从托盘重新打开
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .setup(move |app| {
            let loaded = load_config(app.handle());
            let initial_style = loaded.subtitle_style.clone();
            let auto_check = loaded.update_config.auto_check_on_startup;
            let update_cfg = loaded.update_config.clone();

            {
                let mut snap = runtime_setup.snapshot.blocking_lock();
                snap.service_config = loaded.service_config;
                snap.subtitle_style = loaded.subtitle_style;
                snap.tts_settings = loaded.tts_settings;
                snap.glossary = loaded.glossary;
                snap.update_config = loaded.update_config;
            }

            setup_tray(app.handle())?;
            if let Some(sub) = app.get_webview_window("subtitle") {
                if !initial_style.visible {
                    let _ = sub.hide();
                }
                let _ = platform::apply_overlay_traits(
                    &sub,
                    initial_style.click_through,
                    initial_style.exclude_from_capture,
                );
            }

            // 启动时后台自动检测 Windows 新版本（静默不阻塞启动）
            if auto_check {
                let handle = app.handle().clone();
                let rt_bg = runtime_setup.clone();
                tauri::async_runtime::spawn(async move {
                    let res = updater::check_for_updates(&update_cfg).await;
                    {
                        let mut snap = rt_bg.snapshot.lock().await;
                        snap.update_info = Some(res.clone());
                    }
                    let _ = handle.emit("update:info", &res);
                });
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            list_audio_sources,
            set_language_pair,
            set_capture_mode,
            toggle_recording,
            clear_recording,
            seek_playback,
            set_playback_playing,
            set_playback_speed,
            set_track_volumes,
            set_subtitle_style,
            save_service_config,
            test_service_connection,
            save_update_config,
            check_for_updates,
            download_and_install_update,
            open_github_url,
            set_tts_settings,
            set_glossary,
            retranslate_segment,
            generate_summary,
            import_media_file,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Hear Desktop");
}
