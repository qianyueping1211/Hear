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
    /// v0.1.21 一次性迁移标记：老版本默认勾选了「播报时静音麦克风」，升级到带 NLMS AEC 的版本后自动切为全双工
    #[serde(default)]
    pub aec_migrated_v1: bool,
}

fn config_file_path(app: &AppHandle) -> Option<PathBuf> {
    let dir = app.path().app_config_dir().ok()?;
    let _ = std::fs::create_dir_all(&dir);
    Some(dir.join("config.json"))
}

pub fn load_config(app: &AppHandle) -> PersistedConfig {
    let Some(path) = config_file_path(app) else {
        return PersistedConfig {
            aec_migrated_v1: true,
            ..PersistedConfig::default()
        };
    };
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return PersistedConfig {
            aec_migrated_v1: true,
            ..PersistedConfig::default()
        };
    };
    let mut cfg: PersistedConfig = serde_json::from_str(&raw).unwrap_or_default();
    if !cfg.aec_migrated_v1 {
        cfg.tts_settings.mute_mic_while_speaking = false;
        cfg.aec_migrated_v1 = true;
        save_config(app, &cfg);
    }
    cfg
}

pub fn save_config(app: &AppHandle, cfg: &PersistedConfig) {
    let Some(path) = config_file_path(app) else {
        return;
    };
    if let Ok(json) = serde_json::to_string_pretty(cfg) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, &json).is_ok() {
            if std::fs::rename(&tmp, &path).is_err() {
                // Windows 上若杀软/索引短暂占用目标文件，退回直接覆盖写并清理临时文件
                let _ = std::fs::write(&path, &json);
                let _ = std::fs::remove_file(&tmp);
            }
        } else {
            let _ = std::fs::write(&path, &json);
        }
    }
}
