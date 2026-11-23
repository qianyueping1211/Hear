use crate::state::{RecordingPlaybackState, SubtitleSegment};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationMeta {
    pub id: String,
    pub title: String,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    #[serde(default)]
    pub duration_ms: u64,
    pub segment_count: usize,
    pub preview: String,
    pub lang_pair: String,
    pub has_audio: bool,
    pub has_summary: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedConversation {
    pub meta: ConversationMeta,
    pub segments: Vec<SubtitleSegment>,
    pub summary_markdown: String,
    pub playback: RecordingPlaybackState,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn conversations_dir(app: &AppHandle) -> PathBuf {
    let dir = app
        .path()
        .app_config_dir()
        .ok()
        .map(|d| d.join("conversations"))
        .unwrap_or_else(|| std::env::temp_dir().join("Hear-Conversations"));
    let _ = fs::create_dir_all(&dir);
    dir
}

fn index_path(dir: &Path) -> PathBuf {
    dir.join("index.json")
}

fn conv_json_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{}.json", id))
}

fn conv_wav_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{}.wav", id))
}

pub fn list_metas(app: &AppHandle) -> Vec<ConversationMeta> {
    let dir = conversations_dir(app);
    let idx = index_path(&dir);
    let Ok(raw) = fs::read_to_string(&idx) else {
        return Vec::new();
    };
    let mut list: Vec<ConversationMeta> = serde_json::from_str(&raw).unwrap_or_default();
    list.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms));
    list
}

fn write_index(dir: &Path, metas: &[ConversationMeta]) {
    let idx = index_path(dir);
    if let Ok(json) = serde_json::to_string_pretty(metas) {
        let tmp = idx.with_extension("json.tmp");
        if fs::write(&tmp, &json).is_ok() {
            if fs::rename(&tmp, &idx).is_err() {
                let _ = fs::write(&idx, &json);
                let _ = fs::remove_file(&tmp);
            }
        } else {
            let _ = fs::write(&idx, &json);
        }
    }
}

fn default_title_for(segments: &[SubtitleSegment]) -> String {
    if let Some(first) = segments.first() {
        let candidate = if !first.source_text.trim().is_empty() {
            first.source_text.trim()
        } else {
            first.translated_text.trim()
        };
        let snippet: String = candidate.chars().take(24).collect();
        if !snippet.is_empty() {
            return snippet;
        }
    }
    "未命名录音对话".to_string()
}

pub fn save_current_conversation(
    app: &AppHandle,
    conv_id: &str,
    source_lang: &str,
    target_lang: &str,
    segments: &[SubtitleSegment],
    summary_markdown: &str,
    playback: &mut RecordingPlaybackState,
) -> Vec<ConversationMeta> {
    let mut metas = list_metas(app);
    if segments.is_empty() && !playback.has_audio {
        return metas;
    }

    let dir = conversations_dir(app);
    // 将录音文件持久化同步复制到 conversations/<id>.wav，避免重启或清理临时目录后丢失原音
    let mut saved_playback = playback.clone();
    if playback.has_audio {
        if let Some(ref cur_path) = playback.audio_path {
            let src = PathBuf::from(cur_path);
            let dst = conv_wav_path(&dir, conv_id);
            if src != dst && src.is_file() {
                if fs::copy(&src, &dst).is_ok() {
                    saved_playback.audio_path = Some(dst.to_string_lossy().to_string());
                }
            }
        }
    }

    let ts = now_ms();
    let existing = metas.iter().find(|m| m.id == conv_id).cloned();
    let created_at_ms = existing.as_ref().map(|m| m.created_at_ms).unwrap_or(ts);
    let title = existing
        .as_ref()
        .map(|m| m.title.clone())
        .filter(|t| !t.trim().is_empty() && t != "未命名录音对话")
        .unwrap_or_else(|| default_title_for(segments));

    let preview: String = if !summary_markdown.trim().is_empty() {
        summary_markdown
            .lines()
            .map(|l| {
                l.trim()
                    .trim_start_matches('#')
                    .trim_start_matches('-')
                    .trim_start_matches('*')
                    .trim()
            })
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(180)
            .collect()
    } else {
        segments
            .iter()
            .take(6)
            .map(|s| {
                if !s.translated_text.trim().is_empty() && s.translated_text != "翻译中…" {
                    format!("{}（{}）", s.translated_text.trim(), s.source_text.trim())
                } else {
                    s.source_text.trim().to_string()
                }
            })
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(180)
            .collect()
    };

    let duration_ms = if playback.duration_ms > 0 {
        playback.duration_ms
    } else {
        segments.last().map(|s| s.end_ms).unwrap_or(0)
    };

    let meta = ConversationMeta {
        id: conv_id.to_string(),
        title,
        created_at_ms,
        updated_at_ms: ts,
        duration_ms,
        segment_count: segments.len(),
        preview,
        lang_pair: format!("{} → {}", source_lang.to_uppercase(), target_lang.to_uppercase()),
        has_audio: playback.has_audio && duration_ms > 0,
        has_summary: !summary_markdown.trim().is_empty(),
    };

    let saved = SavedConversation {
        meta: meta.clone(),
        segments: segments.to_vec(),
        summary_markdown: summary_markdown.to_string(),
        playback: saved_playback,
    };

    let conv_path = conv_json_path(&dir, conv_id);
    if let Ok(json) = serde_json::to_string(&saved) {
        let _ = fs::write(&conv_path, json);
    }

    if let Some(slot) = metas.iter_mut().find(|m| m.id == conv_id) {
        *slot = meta;
    } else {
        metas.push(meta);
    }
    metas.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms));
    write_index(&dir, &metas);
    metas
}

pub fn load_conversation(app: &AppHandle, id: &str) -> Result<SavedConversation, String> {
    let dir = conversations_dir(app);
    let path = conv_json_path(&dir, id);
    let raw = fs::read_to_string(&path).map_err(|e| format!("读取历史会话失败：{}", e))?;
    let mut conv: SavedConversation =
        serde_json::from_str(&raw).map_err(|e| format!("解析历史会话失败：{}", e))?;
    if let Some(ref audio_p) = conv.playback.audio_path {
        if !Path::new(audio_p).is_file() {
            conv.playback.has_audio = false;
            conv.playback.audio_path = None;
        }
    }
    Ok(conv)
}

pub fn rename_conversation(
    app: &AppHandle,
    id: &str,
    new_title: &str,
) -> Result<Vec<ConversationMeta>, String> {
    let trimmed = new_title.trim();
    if trimmed.is_empty() {
        return Err("会话标题不能为空".to_string());
    }
    let dir = conversations_dir(app);
    let mut metas = list_metas(app);
    if let Some(m) = metas.iter_mut().find(|m| m.id == id) {
        m.title = trimmed.to_string();
        m.updated_at_ms = now_ms();
    }
    if let Ok(mut conv) = load_conversation(app, id) {
        conv.meta.title = trimmed.to_string();
        conv.meta.updated_at_ms = now_ms();
        if let Ok(json) = serde_json::to_string(&conv) {
            let _ = fs::write(conv_json_path(&dir, id), json);
        }
    }
    metas.sort_by(|a, b| b.updated_at_ms.cmp(&a.updated_at_ms));
    write_index(&dir, &metas);
    Ok(metas)
}

pub fn delete_conversation(app: &AppHandle, id: &str) -> Result<Vec<ConversationMeta>, String> {
    let dir = conversations_dir(app);
    let _ = fs::remove_file(conv_json_path(&dir, id));
    let _ = fs::remove_file(conv_wav_path(&dir, id));
    let mut metas = list_metas(app);
    metas.retain(|m| m.id != id);
    write_index(&dir, &metas);
    Ok(metas)
}
