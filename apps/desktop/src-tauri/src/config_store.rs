use crate::state::{ServiceConfig, SubtitleStyle, TtsOutputSettings, UpdateConfig};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
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

/// 独立于 Tauri `com.hear.desktop` 目录之外的用户配置镜像路径（`%APPDATA%\Hear-UserConfig\config.json`），
/// 防止 Windows NSIS 卸载/覆盖安装流程清理默认应用数据目录时意外丢失用户的服务地址与 Token。
fn resilient_mirror_path(app: &AppHandle) -> Option<PathBuf> {
    let dir = app.path().app_config_dir().ok()?;
    let parent = dir.parent()?;
    let mirror_dir = parent.join("Hear-UserConfig");
    let _ = std::fs::create_dir_all(&mirror_dir);
    Some(mirror_dir.join("config.json"))
}

fn has_meaningful_credentials(cfg: &PersistedConfig) -> bool {
    !cfg.service_config.cloud_service_address.trim().is_empty()
        || !cfg.service_config.local_access_token.trim().is_empty()
        || !cfg.service_config.cloud_access_token.trim().is_empty()
        || !cfg.update_config.github_token.trim().is_empty()
        || !cfg.glossary.trim().is_empty()
}

/// 容错按区块解析配置：即使未来某个嵌套结构体新增/变更字段，也不会牵连清空服务地址与 Token
pub(crate) fn parse_config_resilient(raw: &str) -> Result<PersistedConfig, String> {
    let val: serde_json::Value =
        serde_json::from_str(raw).map_err(|e| format!("JSON 语法解析失败：{}", e))?;
    let Some(obj) = val.as_object() else {
        return Err("配置根节点不是 JSON 对象".to_string());
    };

    let mut cfg = PersistedConfig::default();

    if let Some(sc_val) = obj.get("serviceConfig") {
        if let Ok(sc) = serde_json::from_value::<ServiceConfig>(sc_val.clone()) {
            cfg.service_config = sc;
        } else if let Some(sc_obj) = sc_val.as_object() {
            if let Some(v) = sc_obj.get("localServiceAddress").and_then(|v| v.as_str()) {
                cfg.service_config.local_service_address = v.to_string();
            }
            if let Some(v) = sc_obj.get("localAccessToken").and_then(|v| v.as_str()) {
                cfg.service_config.local_access_token = v.to_string();
            }
            if let Some(v) = sc_obj.get("cloudServiceAddress").and_then(|v| v.as_str()) {
                cfg.service_config.cloud_service_address = v.to_string();
            }
            if let Some(v) = sc_obj.get("cloudAccessToken").and_then(|v| v.as_str()) {
                cfg.service_config.cloud_access_token = v.to_string();
            }
        }
    }

    if let Some(st_val) = obj.get("subtitleStyle") {
        if let Ok(st) = serde_json::from_value::<SubtitleStyle>(st_val.clone()) {
            cfg.subtitle_style = st;
        }
    }

    if let Some(tts_val) = obj.get("ttsSettings") {
        if let Ok(tts) = serde_json::from_value::<TtsOutputSettings>(tts_val.clone()) {
            cfg.tts_settings = tts;
        }
    }

    if let Some(g) = obj.get("glossary").and_then(|v| v.as_str()) {
        cfg.glossary = g.to_string();
    }

    if let Some(uc_val) = obj.get("updateConfig") {
        if let Ok(uc) = serde_json::from_value::<UpdateConfig>(uc_val.clone()) {
            cfg.update_config = uc;
        } else if let Some(uc_obj) = uc_val.as_object() {
            if let Some(v) = uc_obj.get("repo").and_then(|v| v.as_str()) {
                cfg.update_config.repo = v.to_string();
            }
            if let Some(v) = uc_obj.get("githubToken").and_then(|v| v.as_str()) {
                cfg.update_config.github_token = v.to_string();
            }
            if let Some(v) = uc_obj.get("autoCheckOnStartup").and_then(|v| v.as_bool()) {
                cfg.update_config.auto_check_on_startup = v;
            }
        }
    }

    if let Some(m) = obj.get("aecMigratedV1").and_then(|v| v.as_bool()) {
        cfg.aec_migrated_v1 = m;
    }

    Ok(cfg)
}

fn write_json_atomic(path: &Path, json: &str) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, json).is_ok() {
        if std::fs::rename(&tmp, path).is_err() {
            // Windows 上若杀软/索引短暂占用目标文件，退回直接覆盖写并清理临时文件
            let _ = std::fs::write(path, json);
            let _ = std::fs::remove_file(&tmp);
        }
    } else {
        let _ = std::fs::write(path, json);
    }
}

fn load_from_path(path: &Path) -> Option<PersistedConfig> {
    let raw = std::fs::read_to_string(path).ok()?;
    match parse_config_resilient(&raw) {
        Ok(cfg) => Some(cfg),
        Err(err) => {
            crate::logger::error(format!(
                "解析配置文件 {} 失败（已备份，不会覆盖原文件）：{}",
                path.display(),
                err
            ));
            let bak = path.with_extension("json.corrupt.bak");
            let _ = std::fs::copy(path, &bak);
            None
        }
    }
}

pub fn load_config(app: &AppHandle) -> PersistedConfig {
    let primary_path = config_file_path(app);
    let mirror_path = resilient_mirror_path(app);

    let primary_cfg = primary_path.as_deref().and_then(load_from_path);
    let mirror_cfg = mirror_path.as_deref().and_then(load_from_path);

    let (mut cfg, restored_from_mirror) = match (primary_cfg, mirror_cfg) {
        (Some(p), Some(m)) => {
            // 若主配置凭据意外为空而镜像备份里有完整凭据，自动补全恢复
            if !has_meaningful_credentials(&p) && has_meaningful_credentials(&m) {
                crate::logger::info("检测到主配置凭据为空，已自动从 Hear-UserConfig 镜像恢复配置");
                (m, true)
            } else {
                let mut merged = p;
                if merged.update_config.github_token.trim().is_empty()
                    && !m.update_config.github_token.trim().is_empty()
                {
                    merged.update_config.github_token = m.update_config.github_token;
                    (merged, true)
                } else {
                    (merged, false)
                }
            }
        }
        (Some(p), None) => (p, false),
        (None, Some(m)) => {
            crate::logger::info("主配置文件缺失，已自动从 Hear-UserConfig 镜像恢复全部地址与 Token");
            (m, true)
        }
        (None, None) => {
            return PersistedConfig {
                aec_migrated_v1: true,
                ..PersistedConfig::default()
            };
        }
    };

    let mut need_save = restored_from_mirror;
    if !cfg.aec_migrated_v1 {
        cfg.tts_settings.mute_mic_while_speaking = false;
        cfg.aec_migrated_v1 = true;
        need_save = true;
    }

    if need_save {
        save_config(app, &cfg);
    } else if has_meaningful_credentials(&cfg) {
        // 确保镜像目录始终同步最新有效配置
        if let (Some(mp), Ok(json)) = (mirror_path.as_deref(), serde_json::to_string_pretty(&cfg)) {
            if !mp.is_file() {
                write_json_atomic(mp, &json);
            }
        }
    }

    cfg
}

pub fn save_config(app: &AppHandle, cfg: &PersistedConfig) {
    let Ok(json) = serde_json::to_string_pretty(cfg) else {
        return;
    };
    if let Some(path) = config_file_path(app) {
        write_json_atomic(&path, &json);
    }
    // 同步一份到独立用户配置镜像目录，避免 NSIS 卸载/覆盖安装误清默认目录导致地址与 Token 丢失
    if let Some(mirror) = resilient_mirror_path(app) {
        write_json_atomic(&mirror, &json);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resilient_parser_preserves_tokens_when_unrelated_section_is_malformed() {
        let raw = r#"{
            "serviceConfig": {
                "localServiceAddress": "https://127.0.0.1:8000",
                "localAccessToken": "tok_local_123",
                "cloudServiceAddress": "https://hear.example.com",
                "cloudAccessToken": "tok_cloud_456",
                "asrSource": "cloud",
                "mtSource": "cloud",
                "cloneSource": "cloud"
            },
            "ttsSettings": "corrupted_legacy_value",
            "updateConfig": {
                "repo": "qianyueping1211/Hear",
                "githubToken": "ghp_secret_789",
                "autoCheckOnStartup": true
            }
        }"#;
        let cfg = parse_config_resilient(raw).expect("should parse resiliently");
        assert_eq!(cfg.service_config.cloud_service_address, "https://hear.example.com");
        assert_eq!(cfg.service_config.cloud_access_token, "tok_cloud_456");
        assert_eq!(cfg.service_config.local_access_token, "tok_local_123");
        assert_eq!(cfg.update_config.github_token, "ghp_secret_789");
    }
}
