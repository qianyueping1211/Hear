pub mod audio;
pub mod cloud;
pub mod config_store;
pub mod history_store;
pub mod local_server;
pub mod logger;
pub mod platform;
pub mod recorder;
pub mod state;
pub mod updater;
pub mod vad;

use cloud::HearCloudClient;
use config_store::{load_config, save_config, PersistedConfig};
use state::{
    AppSnapshot, AudioCaptureMode, AudioChannel, AudioSourceOption, EngineSource,
    LocalServerInstallStatus, ServiceConfig, ServiceProbeResult, SessionMode, SubtitleLayoutMode,
    SubtitleSegment, SubtitleStyle, TtsOutputSettings, UpdateCheckResult, UpdateConfig,
};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tokio::sync::Mutex;

pub struct AppRuntime {
    pub snapshot: Mutex<AppSnapshot>,
    pub cloud: HearCloudClient,
    pub capture: Mutex<Option<audio::LiveCaptureHandle>>,
    pub summary_markdown: Mutex<String>,
    pub segment_wavs: Mutex<std::collections::HashMap<String, Vec<u8>>>,
    /// 声音克隆单并发闸门：防止多句预克隆或用户点击并发打到服务端触发 503 SERVICE_BUSY
    pub clone_gate: Mutex<()>,
    /// 强制静音全路采集（仅在用户手动勾选「播报时完全静音麦克风」时启用）
    pub mic_muted: Arc<AtomicBool>,
    /// 播报译文到本机扬声器/耳机时，仅静音 System 系统内录通道（防 WASAPI Loopback 自回环），麦克风保持开启并走 AEC 回声消除
    pub system_tts_muted: Arc<AtomicBool>,
    /// 实时声学回声消除（NLMS AEC）远端参考缓冲：接收本机 TTS 播放的 16kHz 音频用于麦克风实时消回声
    pub aec_far_end: Arc<audio::aec::FarEndReference>,
    /// 串行播放闸门：保证多句连续自动播报按顺序逐句播放且不互相提前解除静音
    pub tts_play_gate: Mutex<()>,
    /// 进程级自动播报去重集合：防止主窗口与悬浮字幕窗或重复事件对同一句触发两次自动播报
    pub auto_spoken_ids: Mutex<std::collections::HashSet<String>>,
    /// 当前正在通过指定输出设备（如虚拟麦克风）播放的 TTS 取消标记
    pub tts_cancel: Mutex<Option<Arc<AtomicBool>>>,
    pub import_cancel: AtomicBool,
}

impl AppRuntime {
    pub fn new() -> Self {
        Self {
            snapshot: Mutex::new(AppSnapshot::default()),
            cloud: HearCloudClient::new(),
            capture: Mutex::new(None),
            summary_markdown: Mutex::new(String::new()),
            segment_wavs: Mutex::new(std::collections::HashMap::new()),
            clone_gate: Mutex::new(()),
            mic_muted: Arc::new(AtomicBool::new(false)),
            system_tts_muted: Arc::new(AtomicBool::new(false)),
            aec_far_end: Arc::new(audio::aec::FarEndReference::new()),
            tts_play_gate: Mutex::new(()),
            auto_spoken_ids: Mutex::new(std::collections::HashSet::new()),
            tts_cancel: Mutex::new(None),
            import_cancel: AtomicBool::new(false),
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
                aec_migrated_v1: true,
            }
        };
        save_config(app, &cfg);
    }

    pub async fn save_history(&self, app: &AppHandle) {
        let summary_md = self.summary_markdown.lock().await.clone();
        let metas = {
            let mut snap = self.snapshot.lock().await;
            if snap.segments.is_empty() && !snap.playback.has_audio {
                return;
            }
            let conv_id = snap.active_conversation_id.clone();
            let src_lang = snap.source_lang.clone();
            let dst_lang = snap.target_lang.clone();
            let segs = snap.segments.clone();
            let updated = history_store::save_current_conversation(
                app,
                &conv_id,
                &src_lang,
                &dst_lang,
                &segs,
                &summary_md,
                &mut snap.playback,
            );
            snap.conversations = updated.clone();
            updated
        };
        let _ = app.emit("history:updated", &metas);
    }

    /// 后台自动调用大模型根据对话内容提炼 10~18 字正式会议标题并回写到历史列表
    pub fn spawn_auto_title(self: &Arc<Self>, app: AppHandle) {
        let rt = self.clone();
        tauri::async_runtime::spawn(async move {
            let summary_md = rt.summary_markdown.lock().await.clone();
            let (conv_id, base_url, token, body_snippet) = {
                let snap = rt.snapshot.lock().await;
                if snap.segments.len() < 2 && summary_md.trim().is_empty() {
                    return;
                }
                let cid = snap.active_conversation_id.clone();
                // 仅当标题仍是默认首句截断或未命名时才自动提炼，避免覆盖已提炼或用户手动重命名的标题
                let default_first: String = snap
                    .segments
                    .first()
                    .map(|s| {
                        if !s.source_text.trim().is_empty() {
                            s.source_text.trim()
                        } else {
                            s.translated_text.trim()
                        }
                    })
                    .unwrap_or("")
                    .chars()
                    .take(24)
                    .collect();
                if let Some(meta) = snap.conversations.iter().find(|m| m.id == cid) {
                    if meta.title != "未命名录音对话" && meta.title != default_first {
                        return;
                    }
                }
                let (addr, tok) = match snap.service_config.mt_source {
                    EngineSource::Local => (
                        snap.service_config.local_service_address.trim().to_string(),
                        snap.service_config.local_access_token.clone(),
                    ),
                    EngineSource::Cloud => (
                        snap.service_config.cloud_service_address.trim().to_string(),
                        snap.service_config.cloud_access_token.clone(),
                    ),
                };
                if addr.is_empty() {
                    return;
                }
                let snippet = if !summary_md.trim().is_empty() {
                    summary_md.chars().take(600).collect::<String>()
                } else {
                    snap.segments
                        .iter()
                        .take(10)
                        .map(|s| {
                            if !s.translated_text.trim().is_empty() {
                                format!("{} ({})", s.translated_text.trim(), s.source_text.trim())
                            } else {
                                s.source_text.trim().to_string()
                            }
                        })
                        .collect::<Vec<_>>()
                        .join("\n")
                };
                (cid, addr, tok, snippet)
            };

            let prompt = format!(
                "请根据以下对话记录，提炼一个 10 到 18 个字的正式中文会议或对话标题（例如：数据中心项目技术澄清与报价对齐会议）。注意：只输出标题本身，不要带引号、书名号、标点符号或任何多余解释：\n\n{}",
                body_snippet
            );
            let tok_opt = if token.trim().is_empty() {
                None
            } else {
                Some(token.as_str())
            };
            if let Ok(raw) = rt
                .cloud
                .translate_stream(&base_url, &prompt, false, tok_opt, |_| {})
                .await
            {
                let cleaned = audio::clean_translation_output(&raw);
                let first_line = cleaned.lines().next().unwrap_or("").trim();
                let stripped = first_line
                    .trim_matches(|c: char| {
                        c == '"'
                            || c == '\''
                            || c == '“'
                            || c == '”'
                            || c == '《'
                            || c == '》'
                            || c == '#'
                            || c == '*'
                            || c == '。'
                            || c.is_whitespace()
                    })
                    .chars()
                    .take(26)
                    .collect::<String>();
                if stripped.chars().count() >= 4 {
                    if let Ok(metas) = history_store::rename_conversation(&app, &conv_id, &stripped)
                    {
                        rt.snapshot.lock().await.conversations = metas.clone();
                        let _ = app.emit("history:updated", &metas);
                    }
                }
            }
        });
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

async fn start_recording_impl(
    app: &AppHandle,
    rt: &Arc<AppRuntime>,
) -> Result<SessionMode, String> {
    let mut cap_guard = rt.capture.lock().await;
    if let Some(ref handle) = *cap_guard {
        handle.set_paused(false);
        let mut snap = rt.snapshot.lock().await;
        snap.mode = SessionMode::Recording;
        snap.playback.is_playing = false;
        let _ = app.emit("session:mode", SessionMode::Recording);
        return Ok(SessionMode::Recording);
    }

    // 启动前校验路由对应的语音识别与文本翻译服务地址是否已配置
    let (capture_mode, asr_url, mt_url, asr_is_cloud, mt_is_cloud) = {
        let snap = rt.snapshot.lock().await;
        let a_url = match snap.service_config.asr_source {
            EngineSource::Local => snap.service_config.local_service_address.trim().to_string(),
            EngineSource::Cloud => snap.service_config.cloud_service_address.trim().to_string(),
        };
        let m_url = match snap.service_config.mt_source {
            EngineSource::Local => snap.service_config.local_service_address.trim().to_string(),
            EngineSource::Cloud => snap.service_config.cloud_service_address.trim().to_string(),
        };
        (
            snap.capture_mode,
            a_url,
            m_url,
            snap.service_config.asr_source == EngineSource::Cloud,
            snap.service_config.mt_source == EngineSource::Cloud,
        )
    };

    if asr_url.is_empty() {
        return Err(if asr_is_cloud {
            "语音识别当前路由到「远端云端服务」，请先在「设置 → 模型服务」填写远端服务地址".to_string()
        } else {
            "请先在「设置 → 模型服务」配置本机语音识别服务地址".to_string()
        });
    }
    if mt_url.is_empty() {
        return Err(if mt_is_cloud {
            "文本翻译当前路由到「远端云端服务」，请先在「设置 → 模型服务」填写远端服务地址".to_string()
        } else {
            "请先在「设置 → 模型服务」配置本机文本翻译服务地址".to_string()
        });
    }

    let handle = audio::LiveCaptureHandle::start(app.clone(), rt.clone(), capture_mode)?;
    *cap_guard = Some(handle);
    {
        let mut snap = rt.snapshot.lock().await;
        snap.mode = SessionMode::Recording;
        snap.playback = Default::default();
    }
    let _ = app.emit("session:mode", SessionMode::Recording);
    Ok(SessionMode::Recording)
}

async fn pause_recording_impl(
    app: &AppHandle,
    rt: &Arc<AppRuntime>,
) -> Result<SessionMode, String> {
    let cap_guard = rt.capture.lock().await;
    if let Some(ref handle) = *cap_guard {
        handle.set_paused(true);
        let mut snap = rt.snapshot.lock().await;
        snap.mode = SessionMode::Paused;
        let _ = app.emit("session:mode", SessionMode::Paused);
        return Ok(SessionMode::Paused);
    }
    Ok(SessionMode::Idle)
}

async fn stop_recording_impl(
    app: &AppHandle,
    rt: &Arc<AppRuntime>,
) -> Result<SessionMode, String> {
    let mut cap_guard = rt.capture.lock().await;
    if let Some(handle) = cap_guard.take() {
        let _ = tokio::task::spawn_blocking(move || handle.stop()).await;
    }
    let pb = {
        let mut snap = rt.snapshot.lock().await;
        snap.mode = SessionMode::Idle;
        if snap.playback.duration_ms == 0 && !snap.segments.is_empty() {
            snap.playback.duration_ms = snap.segments.last().map(|s| s.end_ms).unwrap_or(0);
        }
        if snap.playback.peaks.is_empty() && !snap.segments.is_empty() {
            snap.playback.peaks = history_store::synthesize_peaks_from_segments(
                &snap.segments,
                snap.playback.duration_ms,
            );
        }
        snap.playback.clone()
    };
    let _ = app.emit("session:mode", SessionMode::Idle);
    let _ = app.emit("recording:ready", &pb);
    rt.save_history(app).await;
    rt.spawn_auto_title(app.clone());
    Ok(SessionMode::Idle)
}

async fn toggle_recording_impl(
    app: &AppHandle,
    rt: &Arc<AppRuntime>,
) -> Result<SessionMode, String> {
    let current_mode = rt.snapshot.lock().await.mode;
    match current_mode {
        SessionMode::Recording => pause_recording_impl(app, rt).await,
        SessionMode::Paused => start_recording_impl(app, rt).await,
        _ => start_recording_impl(app, rt).await,
    }
}

#[tauri::command]
async fn start_recording(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<SessionMode, String> {
    start_recording_impl(&app, rt.inner()).await
}

#[tauri::command]
async fn pause_recording(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<SessionMode, String> {
    pause_recording_impl(&app, rt.inner()).await
}

#[tauri::command]
async fn resume_recording(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<SessionMode, String> {
    start_recording_impl(&app, rt.inner()).await
}

#[tauri::command]
async fn stop_recording(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<SessionMode, String> {
    stop_recording_impl(&app, rt.inner()).await
}

#[tauri::command]
async fn toggle_recording(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<SessionMode, String> {
    toggle_recording_impl(&app, rt.inner()).await
}

#[tauri::command]
async fn read_recording_audio(
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<tauri::ipc::Response, String> {
    let path = {
        let snap = rt.snapshot.lock().await;
        snap.playback
            .audio_path
            .clone()
            .ok_or_else(|| "当前没有可回放的录音文件".to_string())?
    };
    let bytes = tokio::task::spawn_blocking(move || std::fs::read(&path))
        .await
        .map_err(|e| format!("读取录音任务异常：{}", e))?
        .map_err(|e| format!("读取录音文件失败：{}", e))?;
    Ok(tauri::ipc::Response::new(bytes))
}

#[tauri::command]
async fn clear_recording(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<(), String> {
    rt.save_history(&app).await;
    *rt.summary_markdown.lock().await = String::new();
    rt.segment_wavs.lock().await.clear();
    rt.auto_spoken_ids.lock().await.clear();
    let mut snap = rt.snapshot.lock().await;
    snap.active_conversation_id = format!("conv-{}", uuid::Uuid::new_v4());
    snap.segments.clear();
    snap.live_partial_source.clear();
    snap.live_partial_translation.clear();
    snap.playback = Default::default();
    Ok(())
}

#[tauri::command]
async fn list_conversations(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<Vec<history_store::ConversationMeta>, String> {
    let metas = history_store::list_metas(&app);
    rt.snapshot.lock().await.conversations = metas.clone();
    Ok(metas)
}

#[tauri::command]
async fn load_conversation(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
) -> Result<history_store::SavedConversation, String> {
    // 若当前正在录音，先停止并保存当前会话
    {
        let mut cap = rt.capture.lock().await;
        if let Some(handle) = cap.take() {
            let _ = tokio::task::spawn_blocking(move || handle.stop()).await;
        }
    }
    rt.save_history(&app).await;
    rt.segment_wavs.lock().await.clear();
    rt.auto_spoken_ids.lock().await.clear();

    let conv = history_store::load_conversation(&app, &id)?;
    *rt.summary_markdown.lock().await = conv.summary_markdown.clone();
    {
        let mut snap = rt.snapshot.lock().await;
        snap.mode = SessionMode::Idle;
        snap.active_conversation_id = conv.meta.id.clone();
        snap.segments = conv.segments.clone();
        snap.live_partial_source.clear();
        snap.live_partial_translation.clear();
        snap.playback = conv.playback.clone();
        snap.playback.is_playing = false;
        snap.playback.position_ms = 0;
    }
    let _ = app.emit("session:mode", SessionMode::Idle);
    let _ = app.emit("recording:ready", &conv.playback);
    Ok(conv)
}

#[tauri::command]
async fn rename_conversation(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
    title: String,
) -> Result<Vec<history_store::ConversationMeta>, String> {
    let metas = history_store::rename_conversation(&app, &id, &title)?;
    rt.snapshot.lock().await.conversations = metas.clone();
    let _ = app.emit("history:updated", &metas);
    Ok(metas)
}

#[tauri::command]
async fn delete_conversation(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
) -> Result<Vec<history_store::ConversationMeta>, String> {
    let metas = history_store::delete_conversation(&app, &id)?;
    {
        let mut snap = rt.snapshot.lock().await;
        snap.conversations = metas.clone();
        if snap.active_conversation_id == id {
            snap.active_conversation_id = format!("conv-{}", uuid::Uuid::new_v4());
            snap.segments.clear();
            snap.live_partial_source.clear();
            snap.live_partial_translation.clear();
            snap.playback = Default::default();
        }
    }
    let _ = app.emit("history:updated", &metas);
    Ok(metas)
}

fn my_voice_ref_paths(app: &AppHandle) -> Option<(std::path::PathBuf, std::path::PathBuf)> {
    let dir = app.path().app_data_dir().ok()?;
    let _ = std::fs::create_dir_all(&dir);
    Some((dir.join("my_voice_ref.wav"), dir.join("my_voice_ref.txt")))
}

async fn synthesize_cloned_segment_wav(
    app: &AppHandle,
    rt: &Arc<AppRuntime>,
    id: &str,
    text: &str,
    lang: &str,
) -> Result<Vec<u8>, String> {
    let trimmed = text.trim().to_string();
    if trimmed.is_empty() {
        return Err("朗读文本为空".to_string());
    }
    let (primary_url, primary_tok, fallback_url, fallback_tok, audio_path_opt, seg_info, same_ch_candidates) = {
        let snap = rt.snapshot.lock().await;
        let local_pair = (
            snap.service_config.local_service_address.trim().to_string(),
            snap.service_config.local_access_token.clone(),
        );
        let cloud_pair = (
            snap.service_config.cloud_service_address.trim().to_string(),
            snap.service_config.cloud_access_token.clone(),
        );
        // 若 clone_source 仍为默认 Local 但本机未就绪、而远端云端已配置，则优先路由到云端 Qwen3-TTS
        let prefer_cloud = snap.service_config.clone_source == EngineSource::Cloud
            || (!snap.local_status.ok && !cloud_pair.0.is_empty());
        let ((p_url, p_tok), (f_url, f_tok)) = if prefer_cloud {
            (cloud_pair, local_pair)
        } else {
            (local_pair, cloud_pair)
        };
        if p_url.is_empty() && f_url.is_empty() {
            return Err("未配置声音复刻服务地址".to_string());
        }
        let seg = snap.segments.iter().find(|s| s.id == id).cloned();
        let target_ch = seg.as_ref().map(|s| s.channel);
        let candidates: Vec<(String, String)> = snap
            .segments
            .iter()
            .rev()
            .filter(|s| Some(s.channel) == target_ch && !s.source_text.trim().is_empty())
            .take(8)
            .map(|s| (s.id.clone(), s.source_text.clone()))
            .collect();
        (
            p_url,
            p_tok,
            f_url,
            f_tok,
            snap.playback.audio_path.clone(),
            seg,
            candidates,
        )
    };

    // 0. 若该句来自我的麦克风，且用户已锁定「我的声纹样本」，优先复用该高质固定参考音
    let mut ref_wav: Option<Vec<u8>> = None;
    let mut ref_text = seg_info
        .as_ref()
        .map(|s| s.source_text.clone())
        .unwrap_or_default();
    if seg_info.as_ref().map(|s| s.channel) == Some(AudioChannel::Mic) {
        if let Some((wav_p, txt_p)) = my_voice_ref_paths(app) {
            if let Ok(bytes) = std::fs::read(&wav_p) {
                if bytes.len() > 19_200 {
                    ref_wav = Some(bytes);
                    if let Ok(t) = std::fs::read_to_string(&txt_p) {
                        if !t.trim().is_empty() {
                            ref_text = t.trim().to_string();
                        }
                    }
                }
            }
        }
    }

    // 1. 优先从内存 segment_wavs 取本句（或同声道最近一句 >= 0.6s）的纯净 16kHz 单声道 WAV
    if ref_wav.is_none() {
        let wav_map = rt.segment_wavs.lock().await;
        if let Some(w) = wav_map.get(id) {
            if w.len() >= 19_200 {
                ref_wav = Some(w.clone());
            }
        }
        if ref_wav.is_none() {
            for (cid, ctext) in &same_ch_candidates {
                if let Some(w) = wav_map.get(cid) {
                    if w.len() >= 19_200 {
                        ref_wav = Some(w.clone());
                        ref_text = ctext.clone();
                        break;
                    }
                }
            }
        }
        if ref_wav.is_none() {
            if let Some(w) = wav_map.get(id) {
                if w.len() > 44 {
                    ref_wav = Some(w.clone());
                }
            }
        }
    }

    // 2. 若内存中未缓存（例如从历史记录加载的会话），则从磁盘 WAV 切片
    if ref_wav.is_none() {
        if let (Some(audio_path), Some(seg)) = (audio_path_opt, seg_info) {
            let start_ms = seg.start_ms;
            let end_ms = seg.end_ms;
            let pref_ch = match seg.channel {
                AudioChannel::System => Some(0usize),
                AudioChannel::Mic => Some(1usize),
                AudioChannel::File => None,
            };
            ref_wav = tokio::task::spawn_blocking(move || {
                recorder::slice_wav_range_16k_mono(Path::new(&audio_path), start_ms, end_ms, pref_ch)
                    .or_else(|| {
                        recorder::slice_wav_range_16k_mono(Path::new(&audio_path), start_ms, end_ms, None)
                    })
            })
            .await
            .ok()
            .flatten();
        }
    }

    let p_tok_opt = if primary_tok.trim().is_empty() {
        None
    } else {
        Some(primary_tok.as_str())
    };
    let primary_target = if !primary_url.is_empty() {
        &primary_url
    } else {
        &fallback_url
    };
    let primary_token = if !primary_url.is_empty() {
        p_tok_opt
    } else if fallback_tok.trim().is_empty() {
        None
    } else {
        Some(fallback_tok.as_str())
    };

    // 串行排队调用服务端克隆，避免多句并发导致服务端返回 503 SERVICE_BUSY
    let _clone_guard = rt.clone_gate.lock().await;

    match rt
        .cloud
        .clone_voice(
            primary_target,
            &trimmed,
            lang,
            ref_wav.clone(),
            &ref_text,
            primary_token,
        )
        .await
    {
        Ok(wav_bytes) => Ok(wav_bytes),
        Err(first_err) => {
            if !primary_url.is_empty() && !fallback_url.is_empty() && primary_url != fallback_url {
                let f_tok_opt = if fallback_tok.trim().is_empty() {
                    None
                } else {
                    Some(fallback_tok.as_str())
                };
                if let Ok(wav_bytes) = rt
                    .cloud
                    .clone_voice(&fallback_url, &trimmed, lang, ref_wav, &ref_text, f_tok_opt)
                    .await
                {
                    return Ok(wav_bytes);
                }
            }
            Err(first_err)
        }
    }
}

#[tauri::command]
async fn clone_segment_speech(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
    text: String,
    lang: String,
) -> Result<tauri::ipc::Response, String> {
    if !rt.snapshot.lock().await.tts_settings.use_voice_clone {
        return Err("声音克隆已关闭".to_string());
    }
    let wav = synthesize_cloned_segment_wav(&app, rt.inner(), &id, &text, &lang).await?;
    Ok(tauri::ipc::Response::new(wav))
}

#[tauri::command]
async fn list_output_devices() -> Result<Vec<audio::output::OutputAudioDevice>, String> {
    tokio::task::spawn_blocking(audio::output::list_output_devices)
        .await
        .map_err(|e| format!("枚举输出设备失败：{}", e))
}

#[tauri::command]
async fn list_input_devices() -> Result<Vec<audio::output::OutputAudioDevice>, String> {
    tokio::task::spawn_blocking(audio::output::list_input_devices)
        .await
        .map_err(|e| format!("枚举麦克风设备失败：{}", e))
}

#[tauri::command]
async fn set_mic_muted(rt: State<'_, Arc<AppRuntime>>, muted: bool) -> Result<(), String> {
    rt.mic_muted.store(muted, Ordering::Relaxed);
    Ok(())
}

#[tauri::command]
async fn stop_device_tts(rt: State<'_, Arc<AppRuntime>>) -> Result<(), String> {
    if let Some(flag) = rt.tts_cancel.lock().await.take() {
        flag.store(true, Ordering::Relaxed);
    }
    rt.mic_muted.store(false, Ordering::Relaxed);
    rt.system_tts_muted.store(false, Ordering::Relaxed);
    rt.aec_far_end.clear();
    Ok(())
}

/// 合成克隆语音并直接输出到指定声卡设备（支持会议同传将我的克隆译文送到 VB-Cable 虚拟麦，或本机播报时仅静音系统内录 + 麦克风实时 NLMS AEC 全双工防回声）
#[tauri::command]
async fn play_cloned_segment_to_device(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
    text: String,
    lang: String,
    target: String,
    is_auto: Option<bool>,
) -> Result<(), String> {
    if !rt.snapshot.lock().await.tts_settings.use_voice_clone {
        return Err("声音克隆已关闭".to_string());
    }
    if is_auto == Some(true) {
        let mut spoken = rt.auto_spoken_ids.lock().await;
        if !spoken.insert(id.clone()) {
            return Ok(());
        }
    }
    let _ = app.emit(
        "tts:state",
        serde_json::json!({ "id": id, "state": "cloning" }),
    );
    let wav_bytes = match synthesize_cloned_segment_wav(&app, rt.inner(), &id, &text, &lang).await {
        Ok(b) => b,
        Err(e) => {
            let _ = app.emit(
                "tts:state",
                serde_json::json!({ "id": id, "state": "ready" }),
            );
            return Err(e);
        }
    };
    // 克隆耗时期间若用户已关闭「声音克隆」，立即中止播放，绝不放出克隆音
    if !rt.snapshot.lock().await.tts_settings.use_voice_clone {
        let _ = app.emit(
            "tts:state",
            serde_json::json!({ "id": id, "state": "ready" }),
        );
        return Ok(());
    }
    let (device_name, mute_system_loopback, hard_mute_all) = {
        let snap = rt.snapshot.lock().await;
        let seg_ch = snap.segments.iter().find(|s| s.id == id).map(|s| s.channel);
        let tts = &snap.tts_settings;
        let is_meeting = tts.routing_mode == "meeting";
        let dev = match target.as_str() {
            "meeting_mic" => {
                if !tts.meeting_mic_output_device_id.trim().is_empty() {
                    tts.meeting_mic_output_device_id.clone()
                } else {
                    tts.output_device_id.clone()
                }
            }
            "local" => tts.output_device_id.clone(),
            _ => {
                if is_meeting && seg_ch == Some(AudioChannel::Mic) && !tts.meeting_mic_output_device_id.trim().is_empty() {
                    tts.meeting_mic_output_device_id.clone()
                } else {
                    tts.output_device_id.clone()
                }
            }
        };
        // 会议模式发到独立虚拟麦时不静音采集也不走扬声器 AEC；
        // 发往本机扬声器/耳机时：默认仅静音 System 内录通道（防 WASAPI Loopback 自回环），麦克风保持开启并走 NLMS AEC 全双工消回声；
        // 仅当用户手动勾选「播报时完全静音麦克风」时才启用硬静音全路。
        let routed_to_virtual_mic =
            is_meeting && target == "meeting_mic" && !tts.meeting_mic_output_device_id.trim().is_empty()
            || (is_meeting && target == "auto" && seg_ch == Some(AudioChannel::Mic) && !tts.meeting_mic_output_device_id.trim().is_empty());
        let mute_sys = !routed_to_virtual_mic;
        let hard_mute = !routed_to_virtual_mic && tts.mute_mic_while_speaking;
        (dev, mute_sys, hard_mute)
    };

    // 串行排队播报：避免连续多句自动播报互相掐断或提前解除静音
    let _play_guard = rt.tts_play_gate.lock().await;

    let cancel = Arc::new(AtomicBool::new(false));
    {
        let mut slot = rt.tts_cancel.lock().await;
        if let Some(prev) = slot.replace(cancel.clone()) {
            prev.store(true, Ordering::Relaxed);
        }
    }

    if hard_mute_all {
        rt.mic_muted.store(true, Ordering::Relaxed);
        tokio::time::sleep(std::time::Duration::from_millis(40)).await;
    } else if mute_system_loopback {
        rt.system_tts_muted.store(true, Ordering::Relaxed);
        tokio::time::sleep(std::time::Duration::from_millis(30)).await;
    }
    let far_end_opt = if mute_system_loopback && !hard_mute_all {
        Some(rt.aec_far_end.clone())
    } else {
        None
    };

    let _ = app.emit(
        "tts:state",
        serde_json::json!({ "id": id, "state": "playing" }),
    );
    let cancel_for_play = cancel.clone();
    let res = tokio::task::spawn_blocking(move || {
        audio::output::play_wav_to_device(&wav_bytes, &device_name, cancel_for_play, far_end_opt)
    })
    .await
    .map_err(|e| format!("播放线程异常：{}", e));

    let _ = app.emit(
        "tts:state",
        serde_json::json!({ "id": id, "state": "ready" }),
    );

    if hard_mute_all {
        tokio::time::sleep(std::time::Duration::from_millis(450)).await;
        rt.mic_muted.store(false, Ordering::Relaxed);
    } else if mute_system_loopback {
        // 留 350ms 声卡回环缓冲消散窗口再恢复 System 内录；麦克风全程开启（AEC 自身带 400ms 尾音窗口）
        tokio::time::sleep(std::time::Duration::from_millis(350)).await;
        rt.system_tts_muted.store(false, Ordering::Relaxed);
    }
    res?
}

/// 将指定（或最近一条 >= 1 秒的我的麦克风）录音片段锁定为「我的声纹样本」，开会同传时从第一句起直接复用
#[tauri::command]
async fn save_my_voice_sample(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    segment_id: Option<String>,
) -> Result<bool, String> {
    let (wav_p, txt_p) = my_voice_ref_paths(&app).ok_or_else(|| "无法访问应用数据目录".to_string())?;
    let (chosen_id, chosen_text, audio_path_opt, seg_opt) = {
        let snap = rt.snapshot.lock().await;
        let seg = if let Some(ref sid) = segment_id {
            snap.segments.iter().find(|s| &s.id == sid).cloned()
        } else {
            snap.segments
                .iter()
                .rev()
                .find(|s| s.channel == AudioChannel::Mic && s.end_ms.saturating_sub(s.start_ms) >= 1000)
                .or_else(|| snap.segments.iter().rev().find(|s| s.channel == AudioChannel::Mic))
                .cloned()
        };
        match seg {
            Some(s) => (s.id.clone(), s.source_text.clone(), snap.playback.audio_path.clone(), Some(s)),
            None => return Err("当前会话中还没有你的麦克风录音片段，请先说一句 2~5 秒的话".to_string()),
        }
    };

    let mut wav_bytes = rt.segment_wavs.lock().await.get(&chosen_id).cloned();
    if wav_bytes.as_ref().map(|w| w.len()).unwrap_or(0) <= 44 {
        if let (Some(ap), Some(seg)) = (audio_path_opt, seg_opt) {
            wav_bytes = tokio::task::spawn_blocking(move || {
                recorder::slice_wav_range_16k_mono(Path::new(&ap), seg.start_ms, seg.end_ms, Some(1))
                    .or_else(|| recorder::slice_wav_range_16k_mono(Path::new(&ap), seg.start_ms, seg.end_ms, None))
            })
            .await
            .ok()
            .flatten();
        }
    }
    let bytes = wav_bytes.filter(|w| w.len() > 19_200).ok_or_else(|| {
        "未找到足够长的麦克风音频片段（建议 2~5 秒）".to_string()
    })?;
    std::fs::write(&wav_p, &bytes).map_err(|e| format!("保存声纹样本失败：{}", e))?;
    let _ = std::fs::write(&txt_p, chosen_text.trim());
    logger::info(format!("[voice] 已保存我的固定声纹样本：{} bytes", bytes.len()));
    Ok(true)
}

#[tauri::command]
async fn save_recorded_my_voice_sample(
    app: AppHandle,
    wav_bytes: Vec<u8>,
    ref_text: String,
) -> Result<bool, String> {
    let trimmed_text = ref_text.trim();
    if trimmed_text.is_empty() {
        return Err("参考朗读文本不能为空".to_string());
    }
    // 16kHz 16-bit mono PCM: 32,000 bytes/sec; 要求 3~10 秒（留 0.5 秒容差）
    let min_bytes = 44 + 16_000 * 2 * 3 - 4_000;
    let max_bytes = 44 + 16_000 * 2 * 11;
    if wav_bytes.len() < min_bytes {
        return Err("录制时长不足 3 秒，不符合 Qwen3-TTS 最佳声纹样本要求，请重新录制 3~10 秒".to_string());
    }
    if wav_bytes.len() > max_bytes {
        return Err("录制时长超过 10 秒，请重新录制 3~10 秒".to_string());
    }
    if wav_bytes.len() < 12 || &wav_bytes[0..4] != b"RIFF" || &wav_bytes[8..12] != b"WAVE" {
        return Err("音频格式无效，需要 16kHz 单声道 WAV".to_string());
    }
    let (wav_p, txt_p) = my_voice_ref_paths(&app).ok_or_else(|| "无法访问应用数据目录".to_string())?;
    std::fs::write(&wav_p, &wav_bytes).map_err(|e| format!("保存声纹样本失败：{}", e))?;
    std::fs::write(&txt_p, trimmed_text).map_err(|e| format!("保存参考文本失败：{}", e))?;
    logger::info(format!(
        "[voice] 已保存弹出录制的固定声纹样本：{} bytes ({:.1}s), text_chars={}",
        wav_bytes.len(),
        (wav_bytes.len().saturating_sub(44)) as f32 / 32_000.0,
        trimmed_text.chars().count()
    ));
    Ok(true)
}

#[tauri::command]
async fn read_my_voice_sample_wav(app: AppHandle) -> Result<tauri::ipc::Response, String> {
    let (wav_p, _) = my_voice_ref_paths(&app).ok_or_else(|| "无法访问应用数据目录".to_string())?;
    let bytes = std::fs::read(&wav_p).map_err(|_| "尚未录制固定声纹样本".to_string())?;
    if bytes.len() <= 44 {
        return Err("声纹样本文件无效".to_string());
    }
    Ok(tauri::ipc::Response::new(bytes))
}

#[tauri::command]
async fn get_my_voice_sample_status(app: AppHandle) -> Result<bool, String> {
    if let Some((wav_p, _)) = my_voice_ref_paths(&app) {
        if let Ok(meta) = std::fs::metadata(&wav_p) {
            return Ok(meta.len() > 19_200);
        }
    }
    Ok(false)
}

#[tauri::command]
async fn clear_my_voice_sample(app: AppHandle) -> Result<(), String> {
    if let Some((wav_p, txt_p)) = my_voice_ref_paths(&app) {
        let _ = std::fs::remove_file(&wav_p);
        let _ = std::fs::remove_file(&txt_p);
    }
    Ok(())
}

#[tauri::command]
async fn read_segment_original_wav(
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
) -> Result<tauri::ipc::Response, String> {
    if let Some(w) = rt.segment_wavs.lock().await.get(&id).cloned() {
        if w.len() > 44 {
            return Ok(tauri::ipc::Response::new(w));
        }
    }
    let (audio_path, start_ms, end_ms, pref_ch) = {
        let snap = rt.snapshot.lock().await;
        let wav_path = snap
            .playback
            .audio_path
            .clone()
            .ok_or_else(|| "当前没有该句的原始录音文件".to_string())?;
        let seg = snap
            .segments
            .iter()
            .find(|s| s.id == id)
            .ok_or_else(|| "未找到对应的字幕段落".to_string())?;
        let ch = match seg.channel {
            AudioChannel::System => Some(0usize),
            AudioChannel::Mic => Some(1usize),
            AudioChannel::File => None,
        };
        (wav_path, seg.start_ms, seg.end_ms, ch)
    };
    let sliced = tokio::task::spawn_blocking(move || {
        recorder::slice_wav_range_16k_mono(Path::new(&audio_path), start_ms, end_ms, pref_ch)
            .or_else(|| {
                recorder::slice_wav_range_16k_mono(Path::new(&audio_path), start_ms, end_ms, None)
            })
    })
    .await
    .map_err(|e| format!("切片原音异常：{}", e))?
    .ok_or_else(|| "未能截取该句原音".to_string())?;
    Ok(tauri::ipc::Response::new(sliced))
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
async fn get_local_server_install_status(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<LocalServerInstallStatus, String> {
    let dir = local_server::default_install_dir(&app);
    let status = local_server::inspect_install_dir(&dir);
    {
        let mut snap = rt.snapshot.lock().await;
        snap.local_server_install = status.clone();
    }
    Ok(status)
}

#[tauri::command]
async fn install_local_server(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<LocalServerInstallStatus, String> {
    let dir = local_server::default_install_dir(&app);
    let update_cfg = rt.snapshot.lock().await.update_config.clone();
    let app_clone = app.clone();
    let status = local_server::install_or_reinstall(&dir, &update_cfg, false, |progress| {
        let _ = app_clone.emit("local_server:progress", &progress);
    })
    .await?;
    {
        let mut snap = rt.snapshot.lock().await;
        snap.local_server_install = status.clone();
    }
    let _ = app.emit("local_server:install_status", &status);
    Ok(status)
}

#[tauri::command]
async fn reinstall_local_server(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
) -> Result<LocalServerInstallStatus, String> {
    let dir = local_server::default_install_dir(&app);
    let update_cfg = rt.snapshot.lock().await.update_config.clone();
    let app_clone = app.clone();
    let status = local_server::install_or_reinstall(&dir, &update_cfg, true, |progress| {
        let _ = app_clone.emit("local_server:progress", &progress);
    })
    .await?;
    {
        let mut snap = rt.snapshot.lock().await;
        snap.local_server_install = status.clone();
    }
    let _ = app.emit("local_server:install_status", &status);
    Ok(status)
}

#[tauri::command]
async fn uninstall_local_server(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    remove_models: bool,
) -> Result<LocalServerInstallStatus, String> {
    let dir = local_server::default_install_dir(&app);
    let status = tokio::task::spawn_blocking(move || local_server::uninstall(&dir, remove_models))
        .await
        .map_err(|e| format!("卸载任务异常：{}", e))??;
    {
        let mut snap = rt.snapshot.lock().await;
        snap.local_server_install = status.clone();
    }
    let _ = app.emit("local_server:install_status", &status);
    Ok(status)
}

#[tauri::command]
async fn open_local_server_dir(app: AppHandle) -> Result<(), String> {
    let dir = local_server::default_install_dir(&app);
    local_server::open_install_dir(&dir)
}

#[tauri::command]
async fn open_logs_dir(app: AppHandle) -> Result<(), String> {
    logger::open_log_dir(&app)
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
    let (base_url, token, source_lang, target_lang, glossary, existing_seg) = {
        let mut snap = rt.snapshot.lock().await;
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
        let mut seg_snapshot = None;
        let mut seg_langs = (snap.source_lang.clone(), snap.target_lang.clone());
        if let Some(seg) = snap.segments.iter_mut().find(|s| s.id == id) {
            if seg.baseline_translated.is_none() && !seg.translated_text.trim().is_empty() {
                seg.baseline_translated = Some(seg.translated_text.clone());
            }
            seg.source_text = new_source.clone();
            seg.status = "correcting".into();
            seg.is_edited = Some(true);
            seg_langs = (seg.source_lang.clone(), seg.target_lang.clone());
            seg_snapshot = Some(seg.clone());
        }
        (addr, tok, seg_langs.0, seg_langs.1, snap.glossary.clone(), seg_snapshot)
    };

    if let Some(ref seg) = existing_seg {
        let _ = app.emit("segment:upsert", seg);
    }

    let prompt = audio::build_translation_prompt(&new_source, &source_lang, &target_lang, &glossary);
    let app_stream = app.clone();
    let mut seg_cb = existing_seg.clone();
    let translated_raw = rt
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
            |partial_raw| {
                let cleaned = audio::clean_translation_output(partial_raw);
                if !cleaned.is_empty() {
                    if let Some(ref mut s) = seg_cb {
                        s.translated_text = cleaned;
                        let _ = app_stream.emit("segment:upsert", &*s);
                    }
                }
            },
        )
        .await?;
    let translated = audio::clean_translation_output(&translated_raw);

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
    rt.save_history(&app).await;
    Ok(())
}

#[tauri::command]
async fn update_segment_translation(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
    new_translation: String,
) -> Result<(), String> {
    let trimmed = new_translation.trim().to_string();
    let mut updated = None;
    {
        let mut snap = rt.snapshot.lock().await;
        if let Some(seg) = snap.segments.iter_mut().find(|s| s.id == id) {
            if seg.baseline_translated.is_none() && !seg.translated_text.trim().is_empty() {
                seg.baseline_translated = Some(seg.translated_text.clone());
            }
            seg.translated_text = trimmed;
            seg.status = "final".into();
            seg.is_edited = Some(true);
            updated = Some(seg.clone());
        }
    }
    if let Some(seg) = updated {
        let _ = app.emit("segment:upsert", seg);
    }
    rt.save_history(&app).await;
    Ok(())
}

#[tauri::command]
async fn update_segment_speaker(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    id: String,
    speaker_label: String,
    apply_to_same_speaker: bool,
) -> Result<(), String> {
    let clean = speaker_label.trim().to_string();
    let next_label = if clean.is_empty() { None } else { Some(clean) };
    let mut changed: Vec<SubtitleSegment> = Vec::new();
    {
        let mut snap = rt.snapshot.lock().await;
        let target_info = snap
            .segments
            .iter()
            .find(|s| s.id == id)
            .map(|s| (s.speaker_label.clone(), s.channel));

        if let Some((old_label, old_channel)) = target_info {
            for seg in &mut snap.segments {
                let is_target = seg.id == id
                    || (apply_to_same_speaker
                        && seg.channel == old_channel
                        && seg.speaker_label == old_label);
                if is_target {
                    seg.speaker_label = next_label.clone();
                    changed.push(seg.clone());
                }
            }
        }
    }
    for seg in changed {
        let _ = app.emit("segment:upsert", seg);
    }
    rt.save_history(&app).await;
    Ok(())
}

#[tauri::command]
async fn speak_text_sapi(text: String) -> Result<(), String> {
    let trimmed = text.trim().to_string();
    if trimmed.is_empty() {
        return Ok(());
    }
    #[cfg(target_os = "windows")]
    {
        tokio::task::spawn_blocking(move || {
            use std::os::windows::process::CommandExt;
            let mut cmd = std::process::Command::new("powershell");
            cmd.args([
                "-NoProfile",
                "-Command",
                "Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.Speak($env:HEAR_SPEAK_TEXT)",
            ])
            .env("HEAR_SPEAK_TEXT", trimmed)
            .creation_flags(0x0800_0000);
            let _ = cmd.status();
        })
        .await
        .map_err(|e| format!("系统朗读任务异常：{}", e))?;
    }
    Ok(())
}

fn format_mm_ss(ms: u64) -> String {
    let total_secs = ms / 1000;
    format!("{:02}:{:02}", total_secs / 60, total_secs % 60)
}

#[tauri::command]
async fn generate_summary(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    template_id: String,
) -> Result<String, String> {
    let (base_url, token, transcript) = {
        let snap = rt.snapshot.lock().await;
        if snap.segments.is_empty() {
            return Err("当前还没有可总结的字幕记录".to_string());
        }
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
        if addr.trim().is_empty() {
            return Err("请先在「设置 → 模型服务」配置文本翻译/大模型服务地址".to_string());
        }
        let mut lines = Vec::with_capacity(snap.segments.len());
        let mut char_budget = 0usize;
        for seg in &snap.segments {
            let speaker = seg.speaker_label.as_deref().unwrap_or("说话人");
            let line = if seg.translated_text.trim().is_empty()
                || seg.translated_text.trim() == seg.source_text.trim()
            {
                format!("[{}] {}: {}", format_mm_ss(seg.start_ms), speaker, seg.source_text)
            } else {
                format!(
                    "[{}] {}: {}（译：{}）",
                    format_mm_ss(seg.start_ms),
                    speaker,
                    seg.source_text,
                    seg.translated_text
                )
            };
            char_budget += line.chars().count();
            if char_budget > 12_000 {
                break;
            }
            lines.push(line);
        }
        (addr, tok, lines.join("\n"))
    };

    let instruction = match template_id.as_str() {
        "bilingual" => {
            "请将以下带时间戳的语音记录提炼为中英双语核心要点（Markdown 列表），每条要点前务必保留对应原句的时间戳（如 [01:23]），简洁准确、不要编造未提及的内容。"
        }
        "qa" => {
            "请从以下带时间戳的语音记录中整理出「关键问答」与「行动待办清单」（Markdown 列表），每条尽量附带对应时间戳（如 [01:23]），明确提出人/负责人（若提及）。"
        }
        _ => {
            "请将以下带时间戳的语音记录整理为结构化中文会议纪要，包含「核心议题」「关键结论」「后续行动项」，每条要点尽量保留原文对应的 [mm:ss] 时间戳以便回听跳转。"
        }
    };

    let prompt = format!("{}\n\n<transcript>\n{}\n</transcript>", instruction, transcript);
    let tok_opt = if token.trim().is_empty() {
        None
    } else {
        Some(token.as_str())
    };
    let app_stream = app.clone();
    let raw = rt
        .cloud
        .translate_stream(&base_url, &prompt, false, tok_opt, |partial| {
            let cleaned = audio::clean_translation_output(partial);
            if !cleaned.is_empty() {
                let _ = app_stream.emit("summary:delta", cleaned);
            }
        })
        .await?;

    let final_md = audio::clean_translation_output(&raw);
    if final_md.is_empty() {
        return Err("模型未返回总结内容，请检查模型服务状态".to_string());
    }
    *rt.summary_markdown.lock().await = final_md.clone();
    let _ = app.emit("summary:delta", &final_md);
    rt.save_history(&app).await;
    rt.inner().spawn_auto_title(app.clone());
    Ok(final_md)
}

#[tauri::command]
async fn cancel_import_media(rt: State<'_, Arc<AppRuntime>>) -> Result<(), String> {
    rt.import_cancel.store(true, Ordering::Relaxed);
    Ok(())
}

#[tauri::command]
async fn export_recording_wav(
    rt: State<'_, Arc<AppRuntime>>,
    dest_path: String,
) -> Result<String, String> {
    let trimmed = dest_path.trim().to_string();
    if trimmed.is_empty() {
        return Err("未指定导出文件路径".to_string());
    }
    let src_path = {
        let snap = rt.snapshot.lock().await;
        snap.playback
            .audio_path
            .clone()
            .ok_or_else(|| "当前没有可导出的原始录音文件".to_string())?
    };
    tokio::task::spawn_blocking(move || std::fs::copy(&src_path, &trimmed))
        .await
        .map_err(|e| format!("导出音频任务异常：{}", e))?
        .map_err(|e| format!("导出 WAV 文件失败：{}", e))?;
    Ok(dest_path)
}

fn load_media_as_16k_wav(src_path: &Path) -> Result<(Vec<f32>, u64, Vec<f32>, Vec<u8>), String> {
    let ext = src_path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let wav_bytes = if ext == "wav" {
        std::fs::read(src_path).map_err(|e| format!("读取音频文件失败：{}", e))?
    } else {
        // 非 WAV 格式自动调用系统 ffmpeg 转码为 16 kHz 单声道 16-bit PCM WAV
        let tmp_wav = std::env::temp_dir().join(format!("hear-ff-{}.wav", uuid::Uuid::new_v4()));
        let mut cmd = std::process::Command::new("ffmpeg");
        cmd.arg("-y")
            .arg("-i")
            .arg(src_path)
            .args(["-vn", "-ac", "1", "-ar", "16000", "-f", "wav"])
            .arg(&tmp_wav);
        #[cfg(target_os = "windows")]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let output = cmd.output().map_err(|_| {
            format!(
                "暂未检测到 ffmpeg，无法直接解码 .{} 格式；请安装 ffmpeg 到系统 PATH，或先转换为 .wav 再导入",
                if ext.is_empty() { "媒体" } else { &ext }
            )
        })?;
        if !output.status.success() {
            let _ = std::fs::remove_file(&tmp_wav);
            let stderr = String::from_utf8_lossy(&output.stderr);
            let tail: String = stderr.chars().rev().take(240).collect::<String>().chars().rev().collect();
            return Err(format!("ffmpeg 解码失败：{}", tail.trim()));
        }
        let bytes = std::fs::read(&tmp_wav).map_err(|e| format!("读取转码后的 WAV 失败：{}", e))?;
        let _ = std::fs::remove_file(&tmp_wav);
        bytes
    };

    let (samples_16k, duration_ms, peaks) = recorder::decode_wav_to_16k_mono(&wav_bytes)?;
    let normalized_wav = recorder::encode_wav_16k_mono(&samples_16k);
    Ok((samples_16k, duration_ms, peaks, normalized_wav))
}

#[tauri::command]
async fn import_media_file(
    app: AppHandle,
    rt: State<'_, Arc<AppRuntime>>,
    file_path: String,
) -> Result<(), String> {
    let trimmed = file_path.trim().to_string();
    if trimmed.is_empty() {
        return Err("未选择音视频文件".to_string());
    }

    // 校验语音识别与翻译服务地址已配置
    let (asr_url, asr_tok, mt_url, mt_tok, src_lang, dst_lang, lock_src, glossary) = {
        let snap = rt.snapshot.lock().await;
        let (a_url, a_tok) = match snap.service_config.asr_source {
            EngineSource::Local => (
                snap.service_config.local_service_address.trim().to_string(),
                snap.service_config.local_access_token.clone(),
            ),
            EngineSource::Cloud => (
                snap.service_config.cloud_service_address.trim().to_string(),
                snap.service_config.cloud_access_token.clone(),
            ),
        };
        let (m_url, m_tok) = match snap.service_config.mt_source {
            EngineSource::Local => (
                snap.service_config.local_service_address.trim().to_string(),
                snap.service_config.local_access_token.clone(),
            ),
            EngineSource::Cloud => (
                snap.service_config.cloud_service_address.trim().to_string(),
                snap.service_config.cloud_access_token.clone(),
            ),
        };
        if a_url.is_empty() || m_url.is_empty() {
            return Err("请先在「设置 → 模型服务」配置语音识别与文本翻译服务地址".to_string());
        }
        (
            a_url,
            a_tok,
            m_url,
            m_tok,
            snap.source_lang.clone(),
            snap.target_lang.clone(),
            snap.lock_source_lang,
            snap.glossary.clone(),
        )
    };

    // 若当前正在实时录音，先停录并清空旧会话片段 WAV 缓存
    {
        let mut cap = rt.capture.lock().await;
        if let Some(handle) = cap.take() {
            let _ = tokio::task::spawn_blocking(move || handle.stop()).await;
        }
    }
    rt.segment_wavs.lock().await.clear();

    let path_for_decode = trimmed.clone();
    let (samples_16k, duration_ms, peaks, normalized_wav) =
        tokio::task::spawn_blocking(move || load_media_as_16k_wav(Path::new(&path_for_decode)))
            .await
            .map_err(|e| format!("音频解码任务异常：{}", e))??;

    // 持久化归一化 WAV 供波形播放器回放与点句跳转
    let saved_path = std::env::temp_dir()
        .join("Hear-Recordings")
        .join(format!("import-{}.wav", uuid::Uuid::new_v4()));
    if let Some(parent) = saved_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&saved_path, &normalized_wav)
        .map_err(|e| format!("写入导入音频缓存失败：{}", e))?;
    let saved_path_str = saved_path.to_string_lossy().to_string();

    // 若当前已有会话内容，先保存历史并切换到新会话 ID
    rt.save_history(&app).await;
    *rt.summary_markdown.lock().await = String::new();

    let pb = {
        let mut snap = rt.snapshot.lock().await;
        snap.active_conversation_id = format!("conv-{}", uuid::Uuid::new_v4());
        snap.mode = SessionMode::BatchProcessing;
        snap.segments.clear();
        snap.live_partial_source.clear();
        snap.live_partial_translation.clear();
        snap.playback = state::RecordingPlaybackState {
            has_audio: true,
            audio_path: Some(saved_path_str),
            duration_ms,
            position_ms: 0,
            is_playing: false,
            speed: snap.playback.speed,
            system_volume: snap.playback.system_volume,
            mic_volume: snap.playback.mic_volume,
            peaks,
        };
        snap.playback.clone()
    };
    let _ = app.emit("session:mode", SessionMode::BatchProcessing);
    let _ = app.emit("recording:ready", pb);

    let chunks = audio::segment_offline_16k_mono(&samples_16k);
    if chunks.is_empty() {
        let mut snap = rt.snapshot.lock().await;
        snap.mode = SessionMode::Idle;
        let _ = app.emit("session:mode", SessionMode::Idle);
        return Err("音频中未检测到有效人声片段".to_string());
    }

    let rt_bg = rt.inner().clone();
    rt_bg.import_cancel.store(false, Ordering::Relaxed);
    let app_bg = app.clone();
    tauri::async_runtime::spawn(async move {
        let total = chunks.len();
        let mut voice_clusterer = audio::VoiceprintClusterer::new();
        let mut recent_ctx: Vec<(String, String)> = Vec::new();
        let languages_hdr = if lock_src {
            src_lang.clone()
        } else {
            format!("{},{}", src_lang, dst_lang)
        };
        let asr_tok_opt = if asr_tok.trim().is_empty() {
            None
        } else {
            Some(asr_tok.as_str())
        };
        let mt_tok_opt = if mt_tok.trim().is_empty() {
            None
        } else {
            Some(mt_tok.as_str())
        };

        for (idx, (start_ms, end_ms, seg_samples)) in chunks.into_iter().enumerate() {
            if rt_bg.import_cancel.load(Ordering::Relaxed) {
                break;
            }
            let _ = app_bg.emit(
                "import:progress",
                serde_json::json!({
                    "current": idx + 1,
                    "total": total,
                    "active": true
                }),
            );
            let _ = app_bg.emit(
                "subtitle:partial",
                serde_json::json!({
                    "source": format!("正在批量识别导入文件（{}/{}）…", idx + 1, total),
                    "translation": ""
                }),
            );
            let speaker_label = voice_clusterer.assign_speaker(&seg_samples, "发言人");
            let wav = recorder::encode_wav_16k_mono(&seg_samples);
            let (source_text, detected_lang) = match rt_bg
                .cloud
                .transcribe_wav(&asr_url, wav, &languages_hdr, &src_lang, false, asr_tok_opt)
                .await
            {
                Ok(pair) => pair,
                Err(err) => {
                    let _ = app_bg.emit("session:error", err);
                    break;
                }
            };
            if source_text.trim().is_empty() {
                continue;
            }

            let (actual_src, actual_dst) = audio::resolve_translation_direction(
                &source_text,
                &detected_lang,
                &src_lang,
                &dst_lang,
                lock_src,
            );

            let seg_id = format!("imp-{}-{}", idx + 1, uuid::Uuid::new_v4());
            let mut seg = SubtitleSegment {
                id: seg_id.clone(),
                seq: (idx + 1) as u64,
                start_ms,
                end_ms,
                channel: AudioChannel::File,
                speaker_label: Some(speaker_label),
                source_lang: actual_src.clone(),
                target_lang: actual_dst.clone(),
                source_text: source_text.clone(),
                translated_text: "翻译中…".to_string(),
                baseline_translated: None,
                status: "preview".to_string(),
                is_edited: None,
            };
            {
                let mut snap = rt_bg.snapshot.lock().await;
                snap.segments.push(seg.clone());
            }
            let _ = app_bg.emit("segment:upsert", &seg);

            let prompt = audio::build_translation_prompt_with_context(
                &source_text,
                &actual_src,
                &actual_dst,
                &glossary,
                &recent_ctx,
            );
            match rt_bg
                .cloud
                .translate_stream(&mt_url, &prompt, false, mt_tok_opt, |_| {})
                .await
            {
                Ok(raw_tr) => {
                    let cleaned = audio::clean_translation_output(&raw_tr);
                    seg.translated_text = if cleaned.is_empty() {
                        source_text.clone()
                    } else {
                        cleaned
                    };
                    seg.status = "final".to_string();
                    recent_ctx.push((seg.source_text.clone(), seg.translated_text.clone()));
                    if recent_ctx.len() > 2 {
                        recent_ctx.remove(0);
                    }
                }
                Err(err) => {
                    seg.translated_text = format!("（翻译失败：{}）", err);
                    seg.status = "error".to_string();
                    let _ = app_bg.emit("session:error", err);
                }
            }
            {
                let mut snap = rt_bg.snapshot.lock().await;
                if let Some(s) = snap.segments.iter_mut().find(|s| s.id == seg_id) {
                    *s = seg.clone();
                }
            }
            let _ = app_bg.emit("segment:upsert", &seg);
        }

        {
            let mut snap = rt_bg.snapshot.lock().await;
            snap.mode = SessionMode::Idle;
            snap.live_partial_source.clear();
            snap.live_partial_translation.clear();
        }
        let _ = app_bg.emit(
            "import:progress",
            serde_json::json!({
                "current": total,
                "total": total,
                "active": false
            }),
        );
        rt_bg.save_history(&app_bg).await;
        rt_bg.spawn_auto_title(app_bg.clone());
        let _ = app_bg.emit(
            "subtitle:partial",
            serde_json::json!({ "source": "", "translation": "" }),
        );
        let _ = app_bg.emit("session:mode", SessionMode::Idle);
    });

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
            logger::init(app.handle());
            let loaded = load_config(app.handle());
            let initial_style = loaded.subtitle_style.clone();
            let auto_check = loaded.update_config.auto_check_on_startup;
            let update_cfg = loaded.update_config.clone();

            let install_status =
                local_server::inspect_install_dir(&local_server::default_install_dir(app.handle()));
            let initial_conversations = history_store::list_metas(app.handle());
            {
                let mut snap = runtime_setup.snapshot.blocking_lock();
                snap.service_config = loaded.service_config;
                snap.subtitle_style = loaded.subtitle_style;
                snap.tts_settings = loaded.tts_settings;
                snap.glossary = loaded.glossary;
                snap.update_config = loaded.update_config;
                snap.local_server_install = install_status;
                snap.conversations = initial_conversations;
            }

            setup_tray(app.handle())?;
            if let Some(sub) = app.get_webview_window("subtitle") {
                if initial_style.visible {
                    let _ = sub.show();
                } else {
                    let _ = sub.hide();
                }
                let _ = platform::apply_overlay_traits(
                    &sub,
                    initial_style.click_through,
                    initial_style.exclude_from_capture,
                );
            }

            // 注册全局快捷键（如与其他软件冲突则静默忽略，不影响应用启动）
            {
                let rt_hk = runtime_setup.clone();
                let _ = app.global_shortcut().on_shortcut(
                    "CommandOrControl+Shift+H",
                    move |app_h, _, ev| {
                        if ev.state() == ShortcutState::Pressed {
                            let app_c = app_h.clone();
                            let rt_c = rt_hk.clone();
                            tauri::async_runtime::spawn(async move {
                                if let Err(err) = toggle_recording_impl(&app_c, &rt_c).await {
                                    let _ = app_c.emit("session:error", err);
                                }
                            });
                        }
                    },
                );
                let rt_hk = runtime_setup.clone();
                let _ = app.global_shortcut().on_shortcut(
                    "CommandOrControl+Shift+S",
                    move |app_h, _, ev| {
                        if ev.state() == ShortcutState::Pressed {
                            let app_c = app_h.clone();
                            let rt_c = rt_hk.clone();
                            tauri::async_runtime::spawn(async move {
                                let style = {
                                    let mut snap = rt_c.snapshot.lock().await;
                                    snap.subtitle_style.visible = !snap.subtitle_style.visible;
                                    snap.subtitle_style.clone()
                                };
                                if let Some(w) = app_c.get_webview_window("subtitle") {
                                    if style.visible {
                                        let _ = w.unminimize();
                                        let _ = w.show();
                                    } else {
                                        let _ = w.hide();
                                    }
                                }
                                rt_c.persist(&app_c).await;
                                let _ = app_c.emit("subtitle:style", style);
                            });
                        }
                    },
                );
                let rt_hk = runtime_setup.clone();
                let _ = app.global_shortcut().on_shortcut(
                    "CommandOrControl+Shift+L",
                    move |app_h, _, ev| {
                        if ev.state() == ShortcutState::Pressed {
                            let app_c = app_h.clone();
                            let rt_c = rt_hk.clone();
                            tauri::async_runtime::spawn(async move {
                                let style = {
                                    let mut snap = rt_c.snapshot.lock().await;
                                    snap.subtitle_style.click_through =
                                        !snap.subtitle_style.click_through;
                                    snap.subtitle_style.clone()
                                };
                                if let Some(w) = app_c.get_webview_window("subtitle") {
                                    let _ = platform::apply_overlay_traits(
                                        &w,
                                        style.click_through,
                                        style.exclude_from_capture,
                                    );
                                }
                                rt_c.persist(&app_c).await;
                                let _ = app_c.emit("subtitle:style", style);
                            });
                        }
                    },
                );
                let rt_hk = runtime_setup.clone();
                let _ = app.global_shortcut().on_shortcut(
                    "CommandOrControl+Shift+B",
                    move |app_h, _, ev| {
                        if ev.state() == ShortcutState::Pressed {
                            let app_c = app_h.clone();
                            let rt_c = rt_hk.clone();
                            tauri::async_runtime::spawn(async move {
                                let style = {
                                    let mut snap = rt_c.snapshot.lock().await;
                                    snap.subtitle_style.layout = match snap.subtitle_style.layout {
                                        SubtitleLayoutMode::Bilingual => {
                                            SubtitleLayoutMode::TranslationFocus
                                        }
                                        SubtitleLayoutMode::TranslationFocus => {
                                            SubtitleLayoutMode::TranslationOnly
                                        }
                                        SubtitleLayoutMode::TranslationOnly => {
                                            SubtitleLayoutMode::Bilingual
                                        }
                                    };
                                    snap.subtitle_style.clone()
                                };
                                rt_c.persist(&app_c).await;
                                let _ = app_c.emit("subtitle:style", style);
                            });
                        }
                    },
                );
                let _ = app.global_shortcut().on_shortcut(
                    "CommandOrControl+Shift+C",
                    move |app_h, _, ev| {
                        if ev.state() == ShortcutState::Pressed {
                            let _ = app_h.emit("shortcut:copy_latest", ());
                        }
                    },
                );
            }

            // 启动时后台自动对已配置的「本机服务」与「远端云端服务」做一次只读 /health 检测（不启动任何进程）
            {
                let (local_addr, local_tok, cloud_addr, cloud_tok) = {
                    let snap = runtime_setup.snapshot.blocking_lock();
                    (
                        snap.service_config.local_service_address.clone(),
                        snap.service_config.local_access_token.clone(),
                        snap.service_config.cloud_service_address.clone(),
                        snap.service_config.cloud_access_token.clone(),
                    )
                };
                if !local_addr.trim().is_empty() {
                    let handle = app.handle().clone();
                    let rt_bg = runtime_setup.clone();
                    tauri::async_runtime::spawn(async move {
                        let res = rt_bg.cloud.test_connection(&local_addr, &local_tok).await;
                        {
                            let mut snap = rt_bg.snapshot.lock().await;
                            snap.local_status = res.clone();
                        }
                        let _ = handle.emit("service:local_status", &res);
                    });
                }
                if !cloud_addr.trim().is_empty() {
                    let handle = app.handle().clone();
                    let rt_bg = runtime_setup.clone();
                    tauri::async_runtime::spawn(async move {
                        let res = rt_bg.cloud.test_connection(&cloud_addr, &cloud_tok).await;
                        {
                            let mut snap = rt_bg.snapshot.lock().await;
                            snap.cloud_status = res.clone();
                        }
                        let _ = handle.emit("service:cloud_status", &res);
                    });
                }
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
            start_recording,
            pause_recording,
            resume_recording,
            stop_recording,
            toggle_recording,
            read_recording_audio,
            clear_recording,
            list_conversations,
            load_conversation,
            rename_conversation,
            delete_conversation,
            clone_segment_speech,
            list_output_devices,
            list_input_devices,
            set_mic_muted,
            stop_device_tts,
            play_cloned_segment_to_device,
            save_my_voice_sample,
            save_recorded_my_voice_sample,
            read_my_voice_sample_wav,
            get_my_voice_sample_status,
            clear_my_voice_sample,
            read_segment_original_wav,
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
            get_local_server_install_status,
            install_local_server,
            reinstall_local_server,
            uninstall_local_server,
            open_local_server_dir,
            open_logs_dir,
            set_tts_settings,
            set_glossary,
            retranslate_segment,
            update_segment_translation,
            update_segment_speaker,
            speak_text_sapi,
            generate_summary,
            import_media_file,
            cancel_import_media,
            export_recording_wav,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Hear Desktop");
}
