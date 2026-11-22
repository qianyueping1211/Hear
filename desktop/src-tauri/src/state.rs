use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionMode {
    Idle,
    Recording,
    Playing,
    BatchProcessing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AudioChannel {
    System,
    Mic,
    File,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AudioCaptureMode {
    SystemLoopback,
    AppLoopback,
    Microphone,
    DualMix,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubtitleLayoutMode {
    Bilingual,
    TranslationFocus,
    TranslationOnly,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineSource {
    Local,
    Cloud,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleSegment {
    pub id: String,
    pub seq: u64,
    pub start_ms: u64,
    pub end_ms: u64,
    pub channel: AudioChannel,
    pub speaker_label: Option<String>,
    pub source_lang: String,
    pub target_lang: String,
    pub source_text: String,
    pub translated_text: String,
    pub baseline_translated: Option<String>,
    pub status: String,
    pub is_edited: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioSourceOption {
    pub id: String,
    pub label: String,
    pub kind: AudioCaptureMode,
    pub process_id: Option<u32>,
    pub process_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleStyle {
    pub visible: bool,
    pub click_through: bool,
    pub exclude_from_capture: bool,
    pub layout: SubtitleLayoutMode,
    pub font_size: u32,
    pub max_lines: usize,
    pub background_opacity: f32,
    pub text_stroke: bool,
    pub auto_fade_seconds: u32,
    pub traditional_chinese: bool,
    pub sync_with_playback: bool,
}

impl Default for SubtitleStyle {
    fn default() -> Self {
        Self {
            visible: true,
            click_through: false,
            exclude_from_capture: true,
            layout: SubtitleLayoutMode::Bilingual,
            font_size: 22,
            max_lines: 2,
            background_opacity: 0.72,
            text_stroke: true,
            auto_fade_seconds: 0,
            traditional_chinese: false,
            sync_with_playback: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerSwitches {
    /// 开关 1：本机托管模型服务（默认仅 127.0.0.1）
    pub local_server_enabled: bool,
    /// 开关 2：局域网共享给 iPhone / 其他电脑（切换 0.0.0.0 + 强制 HTTPS 与口令）
    pub lan_share_enabled: bool,
    pub asr_source: EngineSource,
    pub mt_source: EngineSource,
    pub clone_source: EngineSource,
    pub remote_cloud_address: String,
    pub remote_access_token: String,
    pub remote_strict_fingerprint: String,
}

impl Default for ServerSwitches {
    fn default() -> Self {
        Self {
            local_server_enabled: true,
            lan_share_enabled: false,
            asr_source: EngineSource::Local,
            mt_source: EngineSource::Local,
            clone_source: EngineSource::Local,
            remote_cloud_address: String::new(),
            remote_access_token: String::new(),
            remote_strict_fingerprint: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceStatus {
    pub running: bool,
    pub bind_host: String,
    pub port: u16,
    pub lan_shared: bool,
    pub lan_addresses: Vec<String>,
    pub pairing_address: String,
    pub access_token_masked: String,
    pub asr_ready: bool,
    pub asr_detail: String,
    pub mt_ready: bool,
    pub mt_detail: String,
    pub clone_ready: bool,
    pub clone_detail: String,
    pub streaming_mt: bool,
    pub last_error: Option<String>,
}

impl Default for ServiceStatus {
    fn default() -> Self {
        Self {
            running: false,
            bind_host: "127.0.0.1".to_string(),
            port: 8000,
            lan_shared: false,
            lan_addresses: Vec::new(),
            pairing_address: String::new(),
            access_token_masked: String::new(),
            asr_ready: false,
            asr_detail: "未启动".to_string(),
            mt_ready: false,
            mt_detail: "未启动".to_string(),
            clone_ready: false,
            clone_detail: "未启动".to_string(),
            streaming_mt: true,
            last_error: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TtsOutputSettings {
    pub enabled: bool,
    pub use_voice_clone: bool,
    pub output_device_id: String,
    pub duck_original_audio: bool,
    pub duck_ratio: f32,
}

impl Default for TtsOutputSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            use_voice_clone: false,
            output_device_id: "default".to_string(),
            duck_original_audio: true,
            duck_ratio: 0.25,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingPlaybackState {
    pub has_audio: bool,
    pub audio_path: Option<String>,
    pub duration_ms: u64,
    pub position_ms: u64,
    pub is_playing: bool,
    pub speed: f32,
    pub system_volume: f32,
    pub mic_volume: f32,
    pub peaks: Vec<f32>,
}

impl Default for RecordingPlaybackState {
    fn default() -> Self {
        Self {
            has_audio: false,
            audio_path: None,
            duration_ms: 0,
            position_ms: 0,
            is_playing: false,
            speed: 1.0,
            system_volume: 1.0,
            mic_volume: 1.0,
            peaks: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSnapshot {
    pub mode: SessionMode,
    pub source_lang: String,
    pub target_lang: String,
    pub lock_source_lang: bool,
    pub capture_mode: AudioCaptureMode,
    pub selected_app_pid: Option<u32>,
    pub selected_mic_id: Option<String>,
    pub segments: Vec<SubtitleSegment>,
    pub live_partial_source: String,
    pub live_partial_translation: String,
    pub subtitle_style: SubtitleStyle,
    pub switches: ServerSwitches,
    pub service_status: ServiceStatus,
    pub tts_settings: TtsOutputSettings,
    pub playback: RecordingPlaybackState,
    pub glossary: String,
}

impl Default for AppSnapshot {
    fn default() -> Self {
        Self {
            mode: SessionMode::Idle,
            source_lang: "en".to_string(),
            target_lang: "zh".to_string(),
            lock_source_lang: false,
            capture_mode: AudioCaptureMode::SystemLoopback,
            selected_app_pid: None,
            selected_mic_id: None,
            segments: Vec::new(),
            live_partial_source: String::new(),
            live_partial_translation: String::new(),
            subtitle_style: SubtitleStyle::default(),
            switches: ServerSwitches::default(),
            service_status: ServiceStatus::default(),
            tts_settings: TtsOutputSettings::default(),
            playback: RecordingPlaybackState::default(),
            glossary: String::new(),
        }
    }
}
