use crate::state::{ServiceConfig, SubtitleStyle, TtsOutputSettings, UpdateConfig};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersistedConfig {
    #[serde(default)]
    pub service_config: ServiceConfig,
    #[serde(default)]
    pub subtitle_style: SubtitleStyle,
    #[serde(default)]
    pub tts_settings: TtsOutputSettings,
    #[serde(default)]
    pub glossary: String,
    #[serde(default)]
    pub update_config: UpdateConfig,
}

fn config_file_path(app: &AppHandle) -> Option<PathBuf> {
    let dir = app.path().app_config_dir().ok()?;
    let _ = std::fs::create_dir_all(&dir);
    Some(dir.join("config.json"))
}

pub fn load_config(app: &AppHandle) -> PersistedConfig {
    let Some(path) = config_file_path(app) else {
        return PersistedConfig::default();
    };
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return PersistedConfig::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

pub fn save_config(app: &AppHandle, cfg: &PersistedConfig) {
    let Some(path) = config_file_path(app) else {
        return;
    };
    if let Ok(json) = serde_json::to_string_pretty(cfg) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}
