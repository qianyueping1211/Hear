pub mod cloud;
pub mod platform;
pub mod recorder;
pub mod sidecar;
pub mod state;
pub mod vad;

use cloud::HearCloudClient;
use sidecar::LocalEngineManager;
use state::{
    AppSnapshot, AudioCaptureMode, AudioSourceOption, ServerSwitches, ServiceStatus, SessionMode,
    SubtitleStyle, TtsOutputSettings,
};
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::sync::Mutex;

pub struct AppRuntime {
    pub snapshot: Mutex<AppSnapshot>,
    pub engine: Mutex<LocalEngineManager>,
    pub cloud: HearCloudClient,
}

impl AppRuntime {
    pub fn new() -> Self {
        Self {
            snapshot: Mutex::new(AppSnapshot::default()),
            engine: Mutex::new(LocalEngineManager::new(8000)),
            cloud: HearCloudClient::new(),
        }
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
    let _ = app.emit("subtitle:style", style);
    Ok(())
}

#[tauri::command]
async fn update_server_switches(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    mut switches: ServerSwitches,
) -> Result<ServiceStatus, String> {
    if !switches.local_server_enabled {
        switches.lan_share_enabled = false;
    }
    {
        let mut snap = rt.snapshot.lock().await;
        snap.switches = switches.clone();
    }
    let status = {
        let mut eng = rt.engine.lock().await;
        if switches.local_server_enabled {
            eng.start(&switches)?
        } else {
            eng.stop();
            ServiceStatus::default()
        }
    };
    {
        let mut snap = rt.snapshot.lock().await;
        snap.service_status = status.clone();
    }
    let _ = app.emit("service:status", &status);
    Ok(status)
}

#[tauri::command]
async fn start_local_server(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<ServiceStatus, String> {
    let switches = rt.snapshot.lock().await.switches.clone();
    let status = rt.engine.lock().await.start(&switches)?;
    rt.snapshot.lock().await.service_status = status.clone();
    let _ = app.emit("service:status", &status);
    Ok(status)
}

#[tauri::command]
async fn stop_local_server(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<ServiceStatus, String> {
    rt.engine.lock().await.stop();
    let status = ServiceStatus::default();
    rt.snapshot.lock().await.service_status = status.clone();
    let _ = app.emit("service:status", &status);
    Ok(status)
}

#[tauri::command]
async fn probe_server_health(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<ServiceStatus, String> {
    let status = rt.engine.lock().await.probe_status(&rt.cloud).await;
    rt.snapshot.lock().await.service_status = status.clone();
    let _ = app.emit("service:status", &status);
    Ok(status)
}

#[tauri::command]
async fn set_tts_settings(
    rt: State<'_, Arc<AppRuntime>>,
    settings: TtsOutputSettings,
) -> Result<(), String> {
    rt.snapshot.lock().await.tts_settings = settings;
    Ok(())
}

#[tauri::command]
async fn set_glossary(rt: State<'_, Arc<AppRuntime>>, glossary: String) -> Result<(), String> {
    rt.snapshot.lock().await.glossary = glossary;
    Ok(())
}

#[tauri::command]
async fn retranslate_segment(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
    new_source: String,
) -> Result<(), String> {
    let (base_url, secret, token, target_lang) = {
        let snap = rt.snapshot.lock().await;
        let eng = rt.engine.lock().await;
        let base = if snap.switches.mt_source == state::EngineSource::Local {
            eng.local_base_url()
        } else {
            snap.switches.remote_cloud_address.clone()
        };
        (
            base,
            eng.local_secret().to_string(),
            snap.switches.remote_access_token.clone(),
            snap.target_lang.clone(),
        )
    };

    let prompt = format!("Translate to {}: {}", target_lang, new_source);
    let translated = rt
        .cloud
        .translate_stream(
            &base_url,
            &prompt,
            false,
            if token.is_empty() { None } else { Some(&token) },
            Some(&secret),
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
    // Sprint 4 接入完整流式 LLMClient（OpenAI / Anthropic / 本地模型）
    Ok(format!(
        "### 一键总结预览（模板：{}）\n\n- [00:00] 当前为 Sprint 1 框架联调占位输出，Sprint 4 将接入完整流式 LLM 纪要生成与时间戳锚点。",
        template_id
    ))
}

#[tauri::command]
async fn import_media_file() -> Result<(), String> {
    // Sprint 4 接入文件选择对话框 + symphonia/ffmpeg 音频提取 + 离线批量转译管线
    Ok(())
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
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.show();
                    let _ = w.set_focus();
                }
            }
            "toggle_sub" => {
                if let Some(w) = app.get_webview_window("subtitle") {
                    if w.is_visible().unwrap_or(false) {
                        let _ = w.hide();
                    } else {
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
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                ..
            } = event
            {
                if let Some(w) = tray.app_handle().get_webview_window("main") {
                    let _ = w.show();
                    let _ = w.set_focus();
                }
            }
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

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(runtime)
        .setup(|app| {
            setup_tray(app.handle())?;
            if let Some(sub) = app.get_webview_window("subtitle") {
                let _ = platform::apply_overlay_traits(&sub, false, true);
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
            update_server_switches,
            start_local_server,
            stop_local_server,
            probe_server_health,
            set_tts_settings,
            set_glossary,
            retranslate_segment,
            generate_summary,
            import_media_file,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Hear Desktop");
}
