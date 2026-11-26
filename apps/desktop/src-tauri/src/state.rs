use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionMode {
    Idle,
    Recording,
    Paused,
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
#[serde(default, rename_all = "camelCase")]
pub struct SubtitleStyle {
    pub visible: bool,
    pub click_through: bool,
    pub exclude_from_capture: bool,
    pub layout: SubtitleLayoutMode,
    pub font_size: u32,
    pub max_lines: usize,
    pub background_color: String,
    pub background_opacity: f32,
    pub text_stroke: bool,
    pub auto_fade_seconds: u32,
    pub traditional_chinese: bool,
    pub sync_with_playback: bool,
}

impl Default for SubtitleStyle {
    fn default() -> Self {
        Self {
            visible: false,
            click_through: false,
            exclude_from_capture: true,
            layout: SubtitleLayoutMode::Bilingual,
            font_size: 22,
            max_lines: 2,
            background_color: "#0b0f17".to_string(),
            background_opacity: 0.72,
            text_stroke: true,
            auto_fade_seconds: 0,
            traditional_chinese: false,
            sync_with_playback: true,
        }
    }
}

/// 客户端服务连接配置（服务端由服务端独立启动管理，客户端仅保存地址/口令与路由选择）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ServiceConfig {
    pub local_service_address: String,
    pub local_access_token: String,
    pub cloud_service_address: String,
    pub cloud_access_token: String,
    pub asr_source: EngineSource,
    pub mt_source: EngineSource,
    pub clone_source: EngineSource,
    /// 是否记录本地运行日志并允许后端日志打印原文/译文（默认 false，保护隐私）
    #[serde(default)]
    pub log_content_enabled: bool,
}

impl Default for ServiceConfig {
    fn default() -> Self {
        Self {
            local_service_address: "https://127.0.0.1:8000".to_string(),
            local_access_token: String::new(),
            cloud_service_address: String::new(),
            cloud_access_token: String::new(),
            asr_source: EngineSource::Local,
            mt_source: EngineSource::Local,
            clone_source: EngineSource::Local,
            log_content_enabled: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceProbeResult {
    pub ok: bool,
    pub address: String,
    pub latency_ms: u64,
    pub summary: String,
    pub asr_ready: bool,
    pub asr_detail: String,
    pub mt_ready: bool,
    pub mt_detail: String,
    pub clone_ready: bool,
    pub clone_detail: String,
    pub auth_mode: String,
    pub auth_ok: Option<bool>,
    pub auth_detail: Option<String>,
    pub streaming_mt: bool,
    pub error: Option<String>,
}

impl Default for ServiceProbeResult {
    fn default() -> Self {
        Self {
            ok: false,
            address: String::new(),
            latency_ms: 0,
            summary: "尚未检测连接".to_string(),
            asr_ready: false,
            asr_detail: "未检测".to_string(),
            mt_ready: false,
            mt_detail: "未检测".to_string(),
            clone_ready: false,
            clone_detail: "未检测".to_string(),
            auth_mode: "unknown".to_string(),
            auth_ok: None,
            auth_detail: None,
            streaming_mt: false,
            error: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TtsOutputSettings {
    pub enabled: bool,
    pub use_voice_clone: bool,
    /// 使用场景："face_to_face"（面对面交流，播给身边人听并静音麦防回声）| "meeting"（会议同传，对方译文送耳机，我的克隆译文送虚拟麦克风）
    pub routing_mode: String,
    /// 本地收听输出设备名（"default" 表示系统默认耳机/扬声器）
    pub output_device_id: String,
    /// 麦克风输入设备名（"default" 表示自动优先使用耳机/系统默认通信麦克风）
    pub input_device_id: String,
    /// 会议同传时把「克隆我的译文」送给对方（腾讯会议/Teams/微信）的虚拟麦克风输入设备（如 CABLE Input）
    pub meeting_mic_output_device_id: String,
    /// 会议同传时采集对方会议声音的指定输出设备（空=系统默认输出；设为虚拟声卡如 CABLE Input 可 100% 屏蔽对方原声）
    #[serde(default)]
    pub meeting_loopback_device_id: String,
    /// 面对面播报译文时自动静音麦克风，避免喇叭声回环录入
    pub mute_mic_while_speaking: bool,
    /// 我说的话翻译完成后自动克隆并播报（面对面播给老外，会议模式送给虚拟麦克风）
    pub auto_speak_my_mic: bool,
    /// 对方说的话翻译完成后自动播报到我的耳机
    pub auto_speak_other: bool,
    pub duck_original_audio: bool,
    pub duck_ratio: f32,
    /// 系统朗读声音偏好："auto"（自动识别说话人性别）| "female"（女声）| "male"（男声）
    #[serde(default = "default_system_voice_preference")]
    pub system_voice_preference: String,
    /// 声音克隆 / 神经语音引擎："qwen3"（Qwen3-TTS 原声克隆）| "edge_tts"（微软 Edge-TTS 神经语音）
    #[serde(default = "default_clone_engine")]
    pub clone_engine: String,
}

fn default_system_voice_preference() -> String {
    "auto".to_string()
}

fn default_clone_engine() -> String {
    "qwen3".to_string()
}

impl Default for TtsOutputSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            use_voice_clone: true,
            routing_mode: "face_to_face".to_string(),
            output_device_id: "default".to_string(),
            input_device_id: "default".to_string(),
            meeting_mic_output_device_id: String::new(),
            meeting_loopback_device_id: String::new(),
            mute_mic_while_speaking: false,
            auto_speak_my_mic: false,
            auto_speak_other: false,
            duck_original_audio: true,
            duck_ratio: 0.25,
            system_voice_preference: "auto".to_string(),
            clone_engine: "qwen3".to_string(),
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
#[serde(default, rename_all = "camelCase")]
pub struct UpdateConfig {
    pub repo: String,
    pub github_token: String,
    pub auto_check_on_startup: bool,
}

impl Default for UpdateConfig {
    fn default() -> Self {
        Self {
            repo: "qianyueping1211/Hear".to_string(),
            github_token: String::new(),
            auto_check_on_startup: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCheckResult {
    pub current_version: String,
    pub latest_version: Option<String>,
    pub has_update: bool,
    pub tag_name: Option<String>,
    pub release_title: Option<String>,
    pub release_notes: String,
    pub published_at: Option<String>,
    pub release_url: Option<String>,
    pub repo_url: String,
    pub asset_name: Option<String>,
    pub asset_api_url: Option<String>,
    pub asset_browser_url: Option<String>,
    pub asset_size: Option<u64>,
    pub error: Option<String>,
}

impl Default for UpdateCheckResult {
    fn default() -> Self {
        Self {
            current_version: env!("CARGO_PKG_VERSION").to_string(),
            latest_version: None,
            has_update: false,
            tag_name: None,
            release_title: None,
            release_notes: String::new(),
            published_at: None,
            release_url: None,
            repo_url: "https://github.com/qianyueping1211/Hear".to_string(),
            asset_name: None,
            asset_api_url: None,
            asset_browser_url: None,
            asset_size: None,
            error: None,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct LocalServerInstallStatus {
    pub installed: bool,
    pub install_dir: String,
    pub installed_version: Option<String>,
    pub has_bundled_runtime: bool,
    pub has_models: bool,
    pub launcher_path: Option<String>,
}

/// 外部大模型 API 配置（仅用于会议纪要总结与自动标题提炼，不参与实时翻译链路）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct LlmApiConfig {
    pub enabled: bool,
    /// "openai"（兼容 OpenAI / DeepSeek / 通义千问 / Kimi / OpenRouter / Ollama）或 "anthropic"
    pub provider: String,
    pub base_url: String,
    pub api_key: String,
    pub model: String,
}

impl Default for LlmApiConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            provider: "openai".to_string(),
            base_url: "https://api.deepseek.com/v1".to_string(),
            api_key: String::new(),
            model: "deepseek-chat".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSnapshot {
    pub app_version: String,
    pub active_conversation_id: String,
    pub conversations: Vec<crate::history_store::ConversationMeta>,
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
    pub service_config: ServiceConfig,
    pub local_status: ServiceProbeResult,
    pub cloud_status: ServiceProbeResult,
    pub local_server_install: LocalServerInstallStatus,
    pub tts_settings: TtsOutputSettings,
    pub playback: RecordingPlaybackState,
    pub glossary: String,
    pub llm_config: LlmApiConfig,
    pub update_config: UpdateConfig,
    pub update_info: Option<UpdateCheckResult>,
}

impl Default for AppSnapshot {
    fn default() -> Self {
        Self {
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            active_conversation_id: format!("conv-{}", uuid::Uuid::new_v4()),
            conversations: Vec::new(),
            mode: SessionMode::Idle,
            source_lang: "en".to_string(),
            target_lang: "zh".to_string(),
            lock_source_lang: false,
            capture_mode: AudioCaptureMode::DualMix,
            selected_app_pid: None,
            selected_mic_id: None,
            segments: Vec::new(),
            live_partial_source: String::new(),
            live_partial_translation: String::new(),
            subtitle_style: SubtitleStyle::default(),
            service_config: ServiceConfig::default(),
            local_status: ServiceProbeResult::default(),
            cloud_status: ServiceProbeResult::default(),
            local_server_install: LocalServerInstallStatus::default(),
            tts_settings: TtsOutputSettings::default(),
            playback: RecordingPlaybackState::default(),
            glossary: String::new(),
            llm_config: LlmApiConfig::default(),
            update_config: UpdateConfig::default(),
            update_info: None,
        }
    }
}
