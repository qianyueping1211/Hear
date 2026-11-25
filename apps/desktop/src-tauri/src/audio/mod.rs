pub mod aec;
pub mod output;

use crate::logger;
use crate::recorder::{encode_wav_16k_mono, StreamingWavRecorder};
use crate::state::{AudioCaptureMode, AudioChannel, EngineSource, SubtitleSegment};
use crate::vad::{SegmentEvent, Segmenter, VAD_SAMPLE_RATE, VAD_WINDOW_SAMPLES};
use crate::AppRuntime;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use tokio::sync::mpsc as tokio_mpsc;

/// 语言名称映射（与 iOS PromptBuilder 保持完全一致，适配 Hy-MT2 官方提示词）
pub fn lang_zh_name(code: &str) -> &'static str {
    match code {
        "zh" => "中文",
        "en" => "英语",
        "ja" => "日语",
        "ko" => "韩语",
        "fr" => "法语",
        "de" => "德语",
        "es" => "西班牙语",
        _ => "中文",
    }
}

pub fn lang_en_name(code: &str) -> &'static str {
    match code {
        "zh" => "Chinese",
        "en" => "English",
        "ja" => "Japanese",
        "ko" => "Korean",
        "fr" => "French",
        "de" => "German",
        "es" => "Spanish",
        _ => "English",
    }
}

/// 将 ASR 返回的语言标签归一化为标准 2 字母代码（如 zh-CN / chinese -> zh, en-US -> en）
pub fn normalize_lang_code(raw: &str) -> String {
    let s = raw.trim().to_ascii_lowercase();
    if s.is_empty() || s == "auto" {
        return String::new();
    }
    if s.starts_with("zh") || s == "chinese" || s == "yue" || s == "cantonese" || s == "mandarin" {
        return "zh".to_string();
    }
    if s.starts_with("en") || s == "english" {
        return "en".to_string();
    }
    if s.starts_with("ja") || s == "jp" || s == "japanese" {
        return "ja".to_string();
    }
    if s.starts_with("ko") || s == "kr" || s == "korean" {
        return "ko".to_string();
    }
    if s.starts_with("fr") || s == "french" {
        return "fr".to_string();
    }
    if s.starts_with("de") || s == "german" {
        return "de".to_string();
    }
    if s.starts_with("es") || s == "spanish" {
        return "es".to_string();
    }
    s
}

/// 根据文本实际字形统计推断语言（避免 ASR 误把中文标为 en/空导致中译中）
pub fn infer_text_script_lang(text: &str) -> Option<&'static str> {
    let mut cjk = 0usize;
    let mut kana = 0usize;
    let mut hangul = 0usize;
    let mut latin = 0usize;
    for ch in text.chars() {
        let u = ch as u32;
        if (0x3040..=0x30FF).contains(&u) {
            kana += 1;
        } else if (0xAC00..=0xD7AF).contains(&u) || (0x1100..=0x11FF).contains(&u) {
            hangul += 1;
        } else if (0x4E00..=0x9FFF).contains(&u) || (0x3400..=0x4DBF).contains(&u) {
            cjk += 1;
        } else if ch.is_ascii_alphabetic() {
            latin += 1;
        }
    }
    if kana >= 2 {
        return Some("ja");
    }
    if hangul >= 2 {
        return Some("ko");
    }
    if cjk >= 2 && cjk * 2 >= latin {
        return Some("zh");
    }
    if cjk == 0 && latin >= 4 {
        return Some("en");
    }
    None
}

/// 解析最终翻译方向，彻底杜绝「原文中文、译文还是中文」等同语种翻译
pub fn resolve_translation_direction(
    text: &str,
    detected_lang: &str,
    src_lang: &str,
    dst_lang: &str,
    lock_src: bool,
) -> (String, String) {
    let norm_src = normalize_lang_code(src_lang);
    let norm_dst = {
        let d = normalize_lang_code(dst_lang);
        if d.is_empty() { "zh".to_string() } else { d }
    };
    let norm_det = normalize_lang_code(detected_lang);

    // 字形强判定：若原文明显是中文/日文/韩文，优先以字形为准纠正 ASR 误判
    let effective_src = match infer_text_script_lang(text) {
        Some("zh") => "zh".to_string(),
        Some("ja") => "ja".to_string(),
        Some("ko") => "ko".to_string(),
        Some("en") => {
            if matches!(norm_det.as_str(), "fr" | "de" | "es") {
                norm_det
            } else if !norm_det.is_empty() && norm_det != "zh" && norm_det != "ja" && norm_det != "ko" {
                norm_det
            } else if matches!(norm_src.as_str(), "fr" | "de" | "es" | "en") {
                norm_src.clone()
            } else {
                "en".to_string()
            }
        }
        _ => {
            if !norm_det.is_empty() {
                norm_det
            } else if !norm_src.is_empty() {
                norm_src.clone()
            } else {
                "en".to_string()
            }
        }
    };

    // 若识别出的语种与目标语种相同（例如用户说中文但当前目标语是中文），必须自动翻转目标语，绝不出现中译中
    if effective_src == norm_dst {
        if !norm_src.is_empty() && norm_src != norm_dst {
            return (norm_dst, norm_src);
        }
        let fallback_dst = if norm_dst == "zh" { "en" } else { "zh" };
        return (effective_src, fallback_dst.to_string());
    }

    if !lock_src && effective_src == norm_dst && !norm_src.is_empty() && norm_src != norm_dst {
        (norm_dst, norm_src)
    } else {
        (effective_src, norm_dst)
    }
}

/// 过滤纯标点/空白噪声（如 ASR 对短杂音输出 "."、"。"、"?"，避免送给翻译模型引发上下文幻觉复读上一句）
pub fn has_real_speech_text(text: &str) -> bool {
    text.chars().any(|c| c.is_alphanumeric())
}

/// 文本级回声相似度判定：若扬声器刚播报过译文，且麦克风识别出的文本与该译文高度重合，则判定为扬声器回声复录
pub fn is_likely_tts_echo(recognized: &str, spoken_tts: &str) -> bool {
    let norm = |s: &str| -> String {
        s.chars()
            .filter(|c| c.is_alphanumeric() || c.is_whitespace())
            .flat_map(|c| c.to_lowercase())
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    };
    let a = norm(recognized);
    let b = norm(spoken_tts);
    if a.is_empty() || b.is_empty() {
        return false;
    }
    if a == b || (a.len() >= 4 && b.contains(&a)) || (b.len() >= 4 && a.contains(&b)) {
        return true;
    }
    let a_words: Vec<&str> = a.split_whitespace().collect();
    let b_words: std::collections::HashSet<&str> = b.split_whitespace().collect();
    if a_words.len() >= 2 && !b_words.is_empty() {
        let hits = a_words.iter().filter(|w| b_words.contains(**w)).count();
        if hits * 2 >= a_words.len() {
            return true;
        }
    }
    // 中文/CJK 字符级重合度检测
    let a_chars: Vec<char> = a.chars().filter(|c| !c.is_whitespace()).collect();
    let b_chars: std::collections::HashSet<char> =
        b.chars().filter(|c| !c.is_whitespace()).collect();
    if a_chars.len() >= 3 && !b_chars.is_empty() {
        let hits = a_chars.iter().filter(|c| b_chars.contains(*c)).count();
        if hits * 10 >= a_chars.len() * 6 {
            return true;
        }
    }
    false
}

/// 构造与 Hy-MT2 官方推荐一致的翻译提示词（附带匹配的自定义术语表）
pub fn build_translation_prompt(text: &str, src: &str, dst: &str, glossary_raw: &str) -> String {
    build_translation_prompt_with_context(text, src, dst, glossary_raw, &[])
}

/// 构造带前文滑动窗口上下文（最多前 2 句）与自定义术语表的翻译提示词，提升指代消解与断句连贯度
pub fn build_translation_prompt_with_context(
    text: &str,
    src: &str,
    dst: &str,
    glossary_raw: &str,
    recent_context: &[(String, String)],
) -> String {
    let lower_text = text.to_lowercase();
    let mut matched_terms: Vec<(String, String)> = Vec::new();
    for line in glossary_raw.lines() {
        if let Some((lhs, rhs)) = line.split_once('=') {
            let trans = rhs.trim();
            if trans.is_empty() {
                continue;
            }
            for alias in lhs.split('|').map(str::trim).filter(|s| !s.is_empty()) {
                if lower_text.contains(&alias.to_lowercase()) {
                    matched_terms.push((alias.to_string(), trans.to_string()));
                    break;
                }
            }
        }
    }

    if src == "zh" || dst == "zh" {
        let mut prefix = String::new();
        if !matched_terms.is_empty() {
            let rows: Vec<String> = matched_terms
                .iter()
                .map(|(a, b)| format!("{} 翻译成 {}", a, b))
                .collect();
            prefix.push_str(&format!("参考下面的翻译：\n{}\n\n", rows.join("\n")));
        }
        if !recent_context.is_empty() {
            let ctx_rows: Vec<String> = recent_context
                .iter()
                .rev()
                .take(2)
                .rev()
                .map(|(s, t)| format!("- 原文：{}\n  译文：{}", s.trim(), t.trim()))
                .collect();
            prefix.push_str(&format!(
                "前文语境参考（仅供理解上下文与指代，严禁重复输出前文）：\n{}\n\n",
                ctx_rows.join("\n")
            ));
        }
        format!(
            "{}将以下文本翻译为{}，注意只需要输出翻译后的结果，不要额外解释：\n\n{}",
            prefix,
            lang_zh_name(dst),
            text
        )
    } else {
        let mut prefix = String::new();
        if !matched_terms.is_empty() {
            let rows: Vec<String> = matched_terms
                .iter()
                .map(|(a, b)| format!("{} translates to {}", a, b))
                .collect();
            prefix.push_str(&format!(
                "Refer to the following translations:\n{}\n\n",
                rows.join("\n")
            ));
        }
        if !recent_context.is_empty() {
            let ctx_rows: Vec<String> = recent_context
                .iter()
                .rev()
                .take(2)
                .rev()
                .map(|(s, t)| format!("- Source: {}\n  Translation: {}", s.trim(), t.trim()))
                .collect();
            prefix.push_str(&format!(
                "Preceding context (for reference only, do not repeat):\n{}\n\n",
                ctx_rows.join("\n")
            ));
        }
        format!(
            "{}Translate the following segment into {}, without additional explanation.\n\n{}",
            prefix,
            lang_en_name(dst),
            text
        )
    }
}

/// 轻量级实时声纹特征聚类器（基于过零率 ZCR、一阶差分频谱质心与低频共振能量比，自动区分多位远端发言人）
pub struct VoiceprintClusterer {
    centroids: Vec<([f32; 3], usize)>,
}

impl VoiceprintClusterer {
    pub fn new() -> Self {
        Self {
            centroids: Vec::new(),
        }
    }

    pub fn extract_features(samples: &[f32]) -> Option<[f32; 3]> {
        if samples.len() < 3200 {
            return None;
        }
        let mut zcr_sum = 0.0f32;
        let mut diff_sum = 0.0f32;
        let mut low_sum = 0.0f32;
        let mut voiced_frames = 0usize;

        for frame in samples.chunks(320) {
            if frame.len() < 320 {
                break;
            }
            let energy: f32 = frame.iter().map(|&x| x * x).sum::<f32>() / 320.0;
            if energy < 0.00018 {
                continue;
            }
            let mut zc = 0usize;
            let mut diff_e = 0.0f32;
            let mut lp = frame[0];
            let mut low_e = 0.0f32;
            for i in 1..frame.len() {
                if (frame[i] >= 0.0) != (frame[i - 1] >= 0.0) {
                    zc += 1;
                }
                let d = frame[i] - frame[i - 1];
                diff_e += d * d;
                lp = 0.86 * lp + 0.14 * frame[i];
                low_e += lp * lp;
            }
            let total_e = (energy * 320.0).max(1e-6);
            zcr_sum += (zc as f32) / 320.0;
            diff_sum += (diff_e / total_e).sqrt().clamp(0.0, 2.0) * 0.5;
            low_sum += (low_e / total_e).sqrt().clamp(0.0, 1.5);
            voiced_frames += 1;
        }

        if voiced_frames < 3 {
            return None;
        }
        let inv = 1.0 / (voiced_frames as f32);
        Some([zcr_sum * inv, diff_sum * inv, low_sum * inv])
    }

    pub fn assign_speaker(&mut self, samples: &[f32], prefix: &str) -> String {
        let Some(feat) = Self::extract_features(samples) else {
            return prefix.to_string();
        };
        if self.centroids.is_empty() {
            self.centroids.push((feat, 1));
            return prefix.to_string();
        }
        let mut best_idx = 0usize;
        let mut best_dist = f32::MAX;
        for (i, (c, _)) in self.centroids.iter().enumerate() {
            let d0 = (feat[0] - c[0]) * 2.4;
            let d1 = (feat[1] - c[1]) * 1.8;
            let d2 = (feat[2] - c[2]) * 1.6;
            let dist = (d0 * d0 + d1 * d1 + d2 * d2).sqrt();
            if dist < best_dist {
                best_dist = dist;
                best_idx = i;
            }
        }
        let idx = if best_dist > 0.24 && self.centroids.len() < 4 {
            self.centroids.push((feat, 1));
            self.centroids.len() - 1
        } else {
            let (ref mut c, ref mut count) = self.centroids[best_idx];
            let n = (*count as f32).min(12.0);
            for k in 0..3 {
                c[k] = (c[k] * n + feat[k]) / (n + 1.0);
            }
            *count += 1;
            best_idx
        };

        if idx == 0 {
            prefix.to_string()
        } else {
            format!("{} {}", prefix, idx + 1)
        }
    }
}

/// 去掉模型偶尔输出的 <think>...</think> 思考块与多余首尾空白
pub fn clean_translation_output(raw: &str) -> String {
    let mut s = raw.to_string();
    while let Some(start) = s.find("<think>") {
        if let Some(end_rel) = s[start..].find("</think>") {
            let end = start + end_rel + "</think>".len();
            s.replace_range(start..end, "");
        } else {
            s.truncate(start);
            break;
        }
    }
    s.trim().to_string()
}

/// 构造 15 阶 Hamming 窗 Sinc 低通抗混叠 FIR 核（用于 48kHz/44.1kHz 降采样到 16kHz 前滤除 8kHz 以上高频，避免混叠进人声频段）
fn build_antialias_fir(src_rate: u32, dst_rate: u32) -> Vec<f32> {
    if src_rate <= dst_rate {
        return Vec::new();
    }
    const TAPS: usize = 15;
    let half = (TAPS - 1) / 2;
    let fc = (dst_rate as f64 * 0.44) / src_rate as f64;
    let mut kernel = Vec::with_capacity(TAPS);
    let mut sum = 0.0f64;
    for i in 0..TAPS {
        let m = i as f64 - half as f64;
        let sinc = if m.abs() < 1e-9 {
            2.0 * fc
        } else {
            let x = std::f64::consts::PI * m;
            (2.0 * fc * x).sin() / x
        };
        let window = 0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / (TAPS - 1) as f64).cos();
        let coeff = sinc * window;
        kernel.push(coeff);
        sum += coeff;
    }
    kernel
        .into_iter()
        .map(|c| (c / sum.max(1e-12)) as f32)
        .collect()
}

/// 将任意采样率/声道数的实时输入下混为单声道并经低通抗混叠滤波后重采样到 16 kHz，再按 512 采样帧喂入 VAD 与断句器
struct LaneProcessor {
    src_rate: u32,
    channels: usize,
    pos: f64,
    prev_sample: Option<f32>,
    fir_kernel: Vec<f32>,
    fir_tail: Vec<f32>,
    frame_buf: Vec<f32>,
    segmenter: Segmenter,
    noise_floor: f32,
    hangover: usize,
    onset_count: usize,
    aec: Option<aec::AcousticEchoCanceller>,
}

impl LaneProcessor {
    fn new(src_rate: u32, channels: usize) -> Self {
        let clamped_rate = src_rate.max(8_000);
        let fir_kernel = build_antialias_fir(clamped_rate, VAD_SAMPLE_RATE);
        let tail_len = fir_kernel.len().saturating_sub(1);
        Self {
            src_rate: clamped_rate,
            channels: channels.max(1),
            pos: 0.0,
            prev_sample: None,
            fir_kernel,
            fir_tail: vec![0.0; tail_len],
            frame_buf: Vec::with_capacity(VAD_WINDOW_SAMPLES * 2),
            segmenter: Segmenter::new(520, 12),
            noise_floor: 0.0015,
            hangover: 0,
            onset_count: 0,
            aec: None,
        }
    }

    fn enable_aec(&mut self) {
        if self.aec.is_none() {
            self.aec = Some(aec::AcousticEchoCanceller::new());
        }
    }

    fn discard_current(&mut self) {
        self.frame_buf.clear();
        self.hangover = 0;
        self.onset_count = 0;
        self.segmenter.discard_current();
    }

    fn push_interleaved<F>(&mut self, interleaved: &[f32], on_frame: F)
    where
        F: FnMut(&[f32], bool, f32, Option<SegmentEvent>),
    {
        self.push_interleaved_with_aec(interleaved, None, on_frame);
    }

    fn push_interleaved_with_aec<F>(
        &mut self,
        interleaved: &[f32],
        far_end: Option<&aec::FarEndReference>,
        mut on_frame: F,
    )
    where
        F: FnMut(&[f32], bool, f32, Option<SegmentEvent>),
    {
        if interleaved.is_empty() {
            return;
        }
        let ch = self.channels;
        let frames = interleaved.len() / ch;
        if frames == 0 {
            return;
        }

        // 多声道转单声道：对 4 通道及以上笔记本/耳机阵列麦（如 Intel SST），统计各声道能量并优先取最强有效声道，避免平均除以 4 导致音量过低
        let mut mono = Vec::with_capacity(frames);
        let mut avg_energy = 0.0f32;
        let mut ch_energies = vec![0.0f32; ch];
        for i in 0..frames {
            let base = i * ch;
            let mut sum = 0.0f32;
            for c in 0..ch {
                let s = interleaved[base + c];
                sum += s;
                ch_energies[c] += s * s;
            }
            let avg = sum / ch as f32;
            avg_energy += avg * avg;
            mono.push(avg);
        }
        if ch >= 2 {
            let mut best_c = 0usize;
            let mut best_energy = 0.0f32;
            for (c, &e) in ch_energies.iter().enumerate() {
                if e > best_energy {
                    best_energy = e;
                    best_c = c;
                }
            }
            if best_energy > 1e-8 && avg_energy < best_energy * 0.55 {
                mono.clear();
                for i in 0..frames {
                    mono.push(interleaved[i * ch + best_c]);
                }
            }
        }

        // 抗混叠低通滤波 + 重采样到 16 kHz
        if self.src_rate == VAD_SAMPLE_RATE {
            self.frame_buf.extend_from_slice(&mono);
        } else {
            let filtered = if !self.fir_kernel.is_empty() {
                let taps = self.fir_kernel.len();
                let tail_len = taps - 1;
                let mut padded = Vec::with_capacity(tail_len + mono.len());
                padded.extend_from_slice(&self.fir_tail);
                padded.extend_from_slice(&mono);
                let mut out = Vec::with_capacity(mono.len());
                for i in 0..mono.len() {
                    let mut acc = 0.0f32;
                    for k in 0..taps {
                        acc += padded[i + k] * self.fir_kernel[k];
                    }
                    out.push(acc);
                }
                let start = padded.len() - tail_len;
                self.fir_tail.copy_from_slice(&padded[start..]);
                out
            } else {
                mono
            };
            let step = self.src_rate as f64 / VAD_SAMPLE_RATE as f64;
            let mut input = Vec::with_capacity(filtered.len() + 1);
            if let Some(prev) = self.prev_sample {
                input.push(prev);
            } else {
                input.push(filtered[0]);
            }
            input.extend_from_slice(&filtered);
            let max_idx = (input.len() - 1) as f64;
            while self.pos < max_idx {
                let idx = self.pos.floor() as usize;
                let frac = (self.pos - idx as f64) as f32;
                let a = input[idx];
                let b = input[(idx + 1).min(input.len() - 1)];
                self.frame_buf.push(a + (b - a) * frac);
                self.pos += step;
            }
            self.pos -= filtered.len() as f64;
            if self.pos < 0.0 {
                self.pos = 0.0;
            }
            self.prev_sample = filtered.last().copied();
        }

        // 按严格 512 采样帧做自适应能量 VAD + 断句（若麦克风启用全双工 AEC 且扬声器正在播报，先实时抵消回声）
        while self.frame_buf.len() >= VAD_WINDOW_SAMPLES {
            let mut frame: Vec<f32> = self.frame_buf.drain(..VAD_WINDOW_SAMPLES).collect();
            if let (Some(ref mut canceller), Some(fe)) = (self.aec.as_mut(), far_end) {
                if fe.is_active() {
                    let far_frame = fe.pop_frame(frame.len());
                    canceller.process_frame(&mut frame, &far_frame);
                }
            }
            let energy: f32 = frame.iter().map(|s| s * s).sum::<f32>() / frame.len() as f32;
            let rms = energy.sqrt();

            // 抗键盘敲击与瞬态点击：依赖连续 3 帧（~96ms）持续过门限，同时保持 0.0022 低底限以兼容蓝牙/USB 耳机小音量麦克风
            let thresh = (self.noise_floor * 2.8).max(0.0022).min(0.04);
            let speech_now = rms > thresh;
            let has_speech = if speech_now {
                self.onset_count = self.onset_count.saturating_add(1);
                if self.onset_count >= 3 || self.hangover > 0 {
                    self.hangover = 7; // ~224ms 拖尾保护，防止吞尾音
                    true
                } else {
                    false
                }
            } else if self.hangover > 0 {
                self.hangover -= 1;
                if self.hangover == 0 {
                    self.onset_count = 0;
                }
                true
            } else {
                self.onset_count = 0;
                // 仅在静音时缓慢更新底噪估计
                self.noise_floor = (self.noise_floor * 0.96 + rms * 0.04).clamp(0.0003, 0.015);
                false
            };

            let ev = self.segmenter.push_frame(&frame, has_speech);
            let level = (rms * 24.0).clamp(0.0, 1.0);
            on_frame(&frame, has_speech, level, ev);
        }
    }

    fn flush_final(&mut self) -> Option<SegmentEvent> {
        self.segmenter.flush_final()
    }
}

struct CapturedSegment {
    channel: AudioChannel,
    event: SegmentEvent,
}

#[cfg(target_os = "windows")]
mod win_wasapi {
    use super::*;
    use std::ffi::c_void;
    use windows::core::GUID;
    use windows::Win32::Media::Audio::{
        eCapture, eCommunications, eConsole, eRender, IAudioCaptureClient, IAudioClient,
        IMMDeviceEnumerator, MMDeviceEnumerator, AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK, WAVEFORMATEX, WAVEFORMATEXTENSIBLE,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL,
        COINIT_MULTITHREADED,
    };

    const FLAG_SILENT: u32 = 0x2;
    const WAVE_FORMAT_PCM: u16 = 1;
    const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;
    const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

    const GUID_PCM: GUID = GUID::from_u128(0x00000001_0000_0010_8000_00aa00389b71);
    const GUID_IEEE_FLOAT: GUID = GUID::from_u128(0x00000003_0000_0010_8000_00aa00389b71);

    #[derive(Clone, Copy, Debug)]
    enum SampleEncoding {
        F32,
        I16,
        I24,
        I32,
    }

    struct WasapiLane {
        channel: AudioChannel,
        is_loopback: bool,
        audio_client: Option<IAudioClient>,
        capture_client: Option<IAudioCaptureClient>,
        cpal_stream: Option<cpal::Stream>,
        cpal_buf: Option<Arc<std::sync::Mutex<Vec<f32>>>>,
        cpal_broken: Option<Arc<AtomicBool>>,
        needs_reopen: bool,
        reopen_after: Option<Instant>,
        last_packet_at: Instant,
        encoding: SampleEncoding,
        channels: usize,
        sample_rate: u32,
        processor: LaneProcessor,
        rec_queue: std::collections::VecDeque<f32>,
        stat_frames: u64,
        stat_speech_frames: u64,
        stat_peak: f32,
    }

    impl WasapiLane {
        /// 按名称匹配一个活跃的输出设备（用于会议同传时直接监听虚拟声卡如 CABLE Input，实现 100% 屏蔽对方原声）
        unsafe fn find_render_device_by_name(
            enumerator: &IMMDeviceEnumerator,
            target_name: &str,
        ) -> Option<windows::Win32::Media::Audio::IMMDevice> {
            use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
            use windows::Win32::Media::Audio::DEVICE_STATE_ACTIVE;
            use windows::Win32::System::Com::STGM_READ;

            let needle = target_name.trim().to_lowercase();
            if needle.is_empty() || needle == "default" {
                return None;
            }
            let collection = enumerator
                .EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)
                .ok()?;
            let count = collection.GetCount().ok()?;
            let mut partial_match = None;
            for i in 0..count {
                let Ok(dev) = collection.Item(i) else {
                    continue;
                };
                let Ok(store) = dev.OpenPropertyStore(STGM_READ) else {
                    continue;
                };
                let Ok(prop) = store.GetValue(&PKEY_Device_FriendlyName) else {
                    continue;
                };
                let friendly = prop.to_string().trim().to_lowercase();
                if friendly == needle {
                    return Some(dev);
                }
                if partial_match.is_none()
                    && (friendly.contains(&needle) || needle.contains(&friendly))
                    && !friendly.is_empty()
                {
                    partial_match = Some(dev);
                }
            }
            partial_match
        }

        unsafe fn open(
            enumerator: &IMMDeviceEnumerator,
            channel: AudioChannel,
            is_loopback: bool,
            preferred_render: Option<&str>,
        ) -> Result<Self, String> {
            let flow = if is_loopback { eRender } else { eCapture };
            // 麦克风优先取 eCommunications（插上蓝牙/USB 耳机时 Windows 通常把耳机麦设为默认通信设备），失败再退回 eConsole
            let device = if !is_loopback {
                enumerator
                    .GetDefaultAudioEndpoint(flow, eCommunications)
                    .or_else(|_| enumerator.GetDefaultAudioEndpoint(flow, eConsole))
            } else if let Some(target_name) = preferred_render.filter(|s| !s.trim().is_empty() && *s != "default") {
                if let Some(matched) = Self::find_render_device_by_name(enumerator, target_name) {
                    logger::info(format!(
                        "[audio] 会议同传：已绑定指定监听输出设备（虚拟声卡静音监听）：{}",
                        target_name
                    ));
                    Ok(matched)
                } else {
                    logger::warn(format!(
                        "[audio] 未找到指定的会议监听设备「{}」，回退系统默认播放设备",
                        target_name
                    ));
                    enumerator.GetDefaultAudioEndpoint(flow, eConsole)
                }
            } else {
                enumerator.GetDefaultAudioEndpoint(flow, eConsole)
            }
            .map_err(|e| {
                if is_loopback {
                    format!("未找到系统默认播放设备（{:?}）", e)
                } else {
                    format!("未找到默认麦克风设备（{:?}）", e)
                }
            })?;

            let audio_client: IAudioClient = device
                .Activate(CLSCTX_ALL, None)
                .map_err(|e| format!("激活 WASAPI 音频客户端失败：{:?}", e))?;

            let mix_ptr = audio_client
                .GetMixFormat()
                .map_err(|e| format!("获取 WASAPI 混音格式失败：{:?}", e))?;
            if mix_ptr.is_null() {
                return Err("WASAPI 返回空的混音格式".to_string());
            }

            let wf: WAVEFORMATEX = std::ptr::read_unaligned(mix_ptr);
            let tag = wf.wFormatTag;
            let channels = wf.nChannels as usize;
            let sample_rate = wf.nSamplesPerSec;
            let bits = wf.wBitsPerSample;

            let encoding = if tag == WAVE_FORMAT_IEEE_FLOAT && bits == 32 {
                SampleEncoding::F32
            } else if tag == WAVE_FORMAT_PCM && bits == 16 {
                SampleEncoding::I16
            } else if tag == WAVE_FORMAT_PCM && bits == 24 {
                SampleEncoding::I24
            } else if tag == WAVE_FORMAT_PCM && bits == 32 {
                SampleEncoding::I32
            } else if tag == WAVE_FORMAT_EXTENSIBLE {
                let wfe: WAVEFORMATEXTENSIBLE =
                    std::ptr::read_unaligned(mix_ptr as *const WAVEFORMATEXTENSIBLE);
                let sub = wfe.SubFormat;
                if sub == GUID_IEEE_FLOAT && bits == 32 {
                    SampleEncoding::F32
                } else if sub == GUID_PCM && bits == 16 {
                    SampleEncoding::I16
                } else if sub == GUID_PCM && bits == 24 {
                    SampleEncoding::I24
                } else if sub == GUID_PCM && bits == 32 {
                    SampleEncoding::I32
                } else {
                    CoTaskMemFree(Some(mix_ptr as *const c_void));
                    return Err(format!(
                        "不支持的 WASAPI 扩展音频格式（bits={}，sub={:?}）",
                        bits, sub
                    ));
                }
            } else {
                CoTaskMemFree(Some(mix_ptr as *const c_void));
                return Err(format!(
                    "不支持的 WASAPI 音频格式（tag={}，bits={}）",
                    tag, bits
                ));
            };

            // 关键：系统内录严格使用纯轮询模式（不叠加 EVENTCALLBACK），规避 Windows 11 SoundWire/Intel 驱动事件丢失导致全零静音的问题
            let stream_flags = if is_loopback {
                AUDCLNT_STREAMFLAGS_LOOPBACK
            } else {
                0
            };
            let init_res = audio_client.Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                stream_flags,
                10_000_000, // 1.0 秒缓冲
                0,
                mix_ptr,
                None,
            );
            CoTaskMemFree(Some(mix_ptr as *const c_void));
            init_res.map_err(|e| format!("初始化 WASAPI 音频流失败：{:?}", e))?;

            let capture_client: IAudioCaptureClient = audio_client
                .GetService()
                .map_err(|e| format!("获取 WASAPI 采集客户端失败：{:?}", e))?;

            audio_client
                .Start()
                .map_err(|e| format!("启动 WASAPI 采集流失败：{:?}", e))?;

            logger::info(format!(
                "WASAPI 采集已启动: channel={:?} loopback={} sr={} ch={} bits={} enc={:?}",
                channel, is_loopback, sample_rate, channels, bits, encoding
            ));

            Ok(Self {
                channel,
                is_loopback,
                audio_client: Some(audio_client),
                capture_client: Some(capture_client),
                cpal_stream: None,
                cpal_buf: None,
                cpal_broken: None,
                needs_reopen: false,
                reopen_after: None,
                last_packet_at: Instant::now(),
                encoding,
                channels: channels.max(1),
                sample_rate: sample_rate.max(8_000),
                processor: LaneProcessor::new(sample_rate, channels),
                rec_queue: std::collections::VecDeque::with_capacity(VAD_SAMPLE_RATE as usize),
                stat_frames: 0,
                stat_speech_frames: 0,
                stat_peak: 0.0,
            })
        }

        fn open_cpal_mic(device_name: &str) -> Result<Self, String> {
            use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
            use cpal::SampleFormat;

            let host = cpal::default_host();
            let device = host
                .input_devices()
                .map_err(|e| format!("枚举麦克风设备失败：{}", e))?
                .find(|d| d.name().map(|n| n == device_name).unwrap_or(false))
                .ok_or_else(|| format!("未找到指定麦克风设备「{}」", device_name))?;

            let cfg = device
                .default_input_config()
                .map_err(|e| format!("读取麦克风「{}」配置失败：{}", device_name, e))?;
            let channels = cfg.channels() as usize;
            let sample_rate = cfg.sample_rate().0;
            let stream_cfg: cpal::StreamConfig = cfg.clone().into();
            let buf: Arc<std::sync::Mutex<Vec<f32>>> =
                Arc::new(std::sync::Mutex::new(Vec::with_capacity(8192)));
            let buf_cb = buf.clone();
            let broken = Arc::new(AtomicBool::new(false));
            let broken_cb = broken.clone();
            let err_fn = move |err| {
                logger::warn(format!("[cpal-mic] stream error (trigger reopen): {}", err));
                broken_cb.store(true, Ordering::Relaxed);
            };

            let stream = match cfg.sample_format() {
                SampleFormat::F32 => device.build_input_stream(
                    &stream_cfg,
                    move |data: &[f32], _| {
                        if let Ok(mut g) = buf_cb.lock() {
                            if g.len() < 48_000 * 4 {
                                g.extend_from_slice(data);
                            }
                        }
                    },
                    err_fn,
                    None,
                ),
                SampleFormat::I16 => device.build_input_stream(
                    &stream_cfg,
                    move |data: &[i16], _| {
                        if let Ok(mut g) = buf_cb.lock() {
                            if g.len() < 48_000 * 4 {
                                g.extend(data.iter().map(|&s| s as f32 / 32768.0));
                            }
                        }
                    },
                    err_fn,
                    None,
                ),
                SampleFormat::U16 => device.build_input_stream(
                    &stream_cfg,
                    move |data: &[u16], _| {
                        if let Ok(mut g) = buf_cb.lock() {
                            if g.len() < 48_000 * 4 {
                                g.extend(data.iter().map(|&s| (s as f32 - 32768.0) / 32768.0));
                            }
                        }
                    },
                    err_fn,
                    None,
                ),
                other => {
                    return Err(format!("不支持的麦克风采样格式：{:?}", other));
                }
            }
            .map_err(|e| format!("打开麦克风「{}」失败：{}", device_name, e))?;

            stream
                .play()
                .map_err(|e| format!("启动麦克风「{}」采集失败：{}", device_name, e))?;

            logger::info(format!(
                "CPAL 指定麦克风采集已启动: device={} sr={} ch={}",
                device_name, sample_rate, channels
            ));

            Ok(Self {
                channel: AudioChannel::Mic,
                is_loopback: false,
                audio_client: None,
                capture_client: None,
                cpal_stream: Some(stream),
                cpal_buf: Some(buf),
                cpal_broken: Some(broken),
                needs_reopen: false,
                reopen_after: None,
                last_packet_at: Instant::now(),
                encoding: SampleEncoding::F32,
                channels: channels.max(1),
                sample_rate: sample_rate.max(8_000),
                processor: LaneProcessor::new(sample_rate, channels),
                rec_queue: std::collections::VecDeque::with_capacity(VAD_SAMPLE_RATE as usize),
                stat_frames: 0,
                stat_speech_frames: 0,
                stat_peak: 0.0,
            })
        }

        /// 耳机插拔或设备失效时热重连采集流，保留 rec_queue 与时间戳连贯，无需重启录音
        unsafe fn reopen_in_place(
            &mut self,
            enumerator: &IMMDeviceEnumerator,
            chosen_mic: &str,
            preferred_render: Option<&str>,
        ) -> Result<(), String> {
            self.cpal_stream = None;
            if let Some(ref ac) = self.audio_client {
                let _ = ac.Stop();
            }
            self.audio_client = None;
            self.capture_client = None;

            let fresh = if self.channel == AudioChannel::Mic && !chosen_mic.is_empty() && chosen_mic != "default" {
                Self::open_cpal_mic(chosen_mic)
                    .or_else(|_| Self::open(enumerator, AudioChannel::Mic, false, None))?
            } else {
                Self::open(enumerator, self.channel, self.is_loopback, preferred_render)?
            };

            let had_aec = self.processor.aec.is_some();
            self.audio_client = fresh.audio_client;
            self.capture_client = fresh.capture_client;
            self.cpal_stream = fresh.cpal_stream;
            self.cpal_buf = fresh.cpal_buf;
            self.cpal_broken = fresh.cpal_broken;
            self.encoding = fresh.encoding;
            self.channels = fresh.channels;
            self.sample_rate = fresh.sample_rate;
            self.processor = fresh.processor;
            if had_aec {
                self.processor.enable_aec();
            }
            self.needs_reopen = false;
            self.reopen_after = None;
            self.last_packet_at = Instant::now();
            Ok(())
        }

        unsafe fn drain_packets(
            &mut self,
            seg_tx: &tokio_mpsc::UnboundedSender<CapturedSegment>,
            far_end: Option<&aec::FarEndReference>,
        ) -> f32 {
            let mut max_level = 0.0f32;
            let mut scratch: Vec<f32> = Vec::new();

            if let Some(ref cpal_buf) = self.cpal_buf {
                if self
                    .cpal_broken
                    .as_ref()
                    .map(|b| b.load(Ordering::Relaxed))
                    .unwrap_or(false)
                {
                    self.cpal_stream = None;
                    self.needs_reopen = true;
                    self.reopen_after = Some(Instant::now() + Duration::from_millis(250));
                    return 0.0;
                }
                if let Ok(mut g) = cpal_buf.lock() {
                    if !g.is_empty() {
                        std::mem::swap(&mut scratch, &mut *g);
                    }
                }
                if !scratch.is_empty() {
                    self.last_packet_at = Instant::now();
                    let nf = scratch.len() / self.channels.max(1);
                    for &s in &scratch {
                        let a = s.abs();
                        if a > self.stat_peak {
                            self.stat_peak = a;
                        }
                    }
                    self.stat_frames += nf as u64;
                    let ch = self.channel;
                    let mut speech_hits = 0u64;
                    let rec_q = &mut self.rec_queue;
                    self.processor.push_interleaved_with_aec(
                        &scratch,
                        far_end,
                        |frame, has_speech, level, ev| {
                            if has_speech {
                                speech_hits += 1;
                            }
                            if level > max_level {
                                max_level = level;
                            }
                            rec_q.extend(frame.iter().copied());
                            if let Some(event) = ev {
                                let _ = seg_tx.send(CapturedSegment { channel: ch, event });
                            }
                        },
                    );
                    self.stat_speech_frames += speech_hits;
                } else if self.last_packet_at.elapsed().as_millis() > 1800 {
                    // 麦克风超过 1.8 秒未吐包（常见于耳机中途拔出/断开），自动触发热重连
                    logger::warn("[cpal-mic] 超过 1.8 秒无数据包，自动热重连当前可用麦克风");
                    self.cpal_stream = None;
                    self.needs_reopen = true;
                    self.reopen_after = Some(Instant::now() + Duration::from_millis(250));
                }
                return max_level;
            }

            let Some(ref capture_client) = self.capture_client else {
                self.needs_reopen = true;
                return 0.0;
            };

            let mut got_any_packet = false;
            loop {
                let pkt = match capture_client.GetNextPacketSize() {
                    Ok(n) if n > 0 => n,
                    Ok(_) => break,
                    Err(e) => {
                        logger::warn(format!(
                            "[wasapi] channel={:?} 设备失效/断开 ({:?})，触发热重连",
                            self.channel, e
                        ));
                        self.audio_client = None;
                        self.capture_client = None;
                        self.needs_reopen = true;
                        self.reopen_after = Some(Instant::now() + Duration::from_millis(250));
                        break;
                    }
                };
                let _ = pkt;

                let mut data_ptr: *mut u8 = std::ptr::null_mut();
                let mut num_frames: u32 = 0;
                let mut buf_flags: u32 = 0;
                if let Err(e) = capture_client.GetBuffer(
                    &mut data_ptr,
                    &mut num_frames,
                    &mut buf_flags,
                    None,
                    None,
                ) {
                    logger::warn(format!(
                        "[wasapi] channel={:?} GetBuffer 失败 ({:?})，触发热重连",
                        self.channel, e
                    ));
                    self.audio_client = None;
                    self.capture_client = None;
                    self.needs_reopen = true;
                    self.reopen_after = Some(Instant::now() + Duration::from_millis(250));
                    break;
                }
                got_any_packet = true;
                self.last_packet_at = Instant::now();

                let nf = num_frames as usize;
                let sample_count = nf * self.channels;
                scratch.clear();
                scratch.reserve(sample_count);

                let is_silent = (buf_flags & FLAG_SILENT) != 0 || data_ptr.is_null();
                if is_silent {
                    scratch.resize(sample_count, 0.0f32);
                } else {
                    match self.encoding {
                        SampleEncoding::F32 => {
                            let bytes = std::slice::from_raw_parts(data_ptr, sample_count * 4);
                            for c in bytes.chunks_exact(4) {
                                let v = f32::from_le_bytes([c[0], c[1], c[2], c[3]]);
                                let clean = if v.is_finite() { v } else { 0.0 };
                                scratch.push(clean);
                            }
                        }
                        SampleEncoding::I16 => {
                            let bytes = std::slice::from_raw_parts(data_ptr, sample_count * 2);
                            for c in bytes.chunks_exact(2) {
                                let v = i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0;
                                scratch.push(v);
                            }
                        }
                        SampleEncoding::I24 => {
                            let bytes = std::slice::from_raw_parts(data_ptr, sample_count * 3);
                            for c in bytes.chunks_exact(3) {
                                let b0 = c[0] as i32;
                                let b1 = (c[1] as i32) << 8;
                                let b2 = ((c[2] as i8) as i32) << 16;
                                scratch.push((b0 | b1 | b2) as f32 / 8_388_608.0);
                            }
                        }
                        SampleEncoding::I32 => {
                            let bytes = std::slice::from_raw_parts(data_ptr, sample_count * 4);
                            for c in bytes.chunks_exact(4) {
                                let v = i32::from_le_bytes([c[0], c[1], c[2], c[3]]);
                                scratch.push((v as f64 / 2_147_483_648.0) as f32);
                            }
                        }
                    }
                }

                let _ = capture_client.ReleaseBuffer(num_frames);

                for &s in &scratch {
                    let a = s.abs();
                    if a > self.stat_peak {
                        self.stat_peak = a;
                    }
                }
                self.stat_frames += nf as u64;

                let ch = self.channel;
                let mut speech_hits = 0u64;
                let rec_q = &mut self.rec_queue;
                self.processor.push_interleaved_with_aec(
                    &scratch,
                    far_end,
                    |frame, has_speech, level, ev| {
                    if has_speech {
                        speech_hits += 1;
                    }
                    if level > max_level {
                        max_level = level;
                    }
                    rec_q.extend(frame.iter().copied());
                    if let Some(event) = ev {
                        let _ = seg_tx.send(CapturedSegment { channel: ch, event });
                    }
                });
                self.stat_speech_frames += speech_hits;
            }
            if !got_any_packet
                && !self.is_loopback
                && !self.needs_reopen
                && self.last_packet_at.elapsed().as_millis() > 1800
            {
                logger::warn("[wasapi] Mic 超过 1.8 秒无数据包（疑似耳机拔出），自动触发热重连");
                self.audio_client = None;
                self.capture_client = None;
                self.needs_reopen = true;
                self.reopen_after = Some(Instant::now() + Duration::from_millis(250));
            }
            max_level
        }

        unsafe fn discard_packets(&mut self) {
            if let Some(ref cpal_buf) = self.cpal_buf {
                if let Ok(mut g) = cpal_buf.lock() {
                    g.clear();
                }
                return;
            }
            let Some(ref capture_client) = self.capture_client else {
                return;
            };
            loop {
                let pkt = match capture_client.GetNextPacketSize() {
                    Ok(n) if n > 0 => n,
                    _ => break,
                };
                let _ = pkt;
                let mut data_ptr: *mut u8 = std::ptr::null_mut();
                let mut num_frames: u32 = 0;
                let mut buf_flags: u32 = 0;
                if capture_client
                    .GetBuffer(&mut data_ptr, &mut num_frames, &mut buf_flags, None, None)
                    .is_err()
                {
                    break;
                }
                let _ = capture_client.ReleaseBuffer(num_frames);
            }
        }

        unsafe fn stop_and_flush(
            &mut self,
            seg_tx: &tokio_mpsc::UnboundedSender<CapturedSegment>,
        ) {
            self.cpal_stream = None;
            if let Some(ref ac) = self.audio_client {
                let _ = ac.Stop();
            }
            if let Some(ev) = self.processor.flush_final() {
                let _ = seg_tx.send(CapturedSegment {
                    channel: self.channel,
                    event: ev,
                });
            }
            logger::info(format!(
                "WASAPI 采集已停止: channel={:?} total_frames={} speech_frames={} peak={:.5}",
                self.channel, self.stat_frames, self.stat_speech_frames, self.stat_peak
            ));
        }
    }

    fn flush_lanes_into_recorder(lanes: &mut [WasapiLane], rec: &mut StreamingWavRecorder) {
        if lanes.len() == 1 && !lanes[0].rec_queue.is_empty() {
            let buf: Vec<f32> = lanes[0].rec_queue.drain(..).collect();
            let _ = rec.write_f32(&buf);
        } else if lanes.len() >= 2 {
            let (first, rest) = lanes.split_at_mut(1);
            let q0 = &mut first[0].rec_queue;
            let q1 = &mut rest[0].rec_queue;
            let rem = q0.len().max(q1.len());
            if rem > 0 {
                // 双声道分轨交织写入：左声道(L)=系统内录(对方)，右声道(R)=麦克风(我)
                let mut stereo = Vec::with_capacity(rem * 2);
                for _ in 0..rem {
                    let a = q0.pop_front().unwrap_or(0.0);
                    let b = q1.pop_front().unwrap_or(0.0);
                    stereo.push(a.clamp(-1.0, 1.0));
                    stereo.push(b.clamp(-1.0, 1.0));
                }
                let _ = rec.write_f32(&stereo);
            }
        }
    }

    pub fn run_capture_thread(
        capture_mode: AudioCaptureMode,
        stop_flag: Arc<AtomicBool>,
        paused_flag: Arc<AtomicBool>,
        stop_rx: mpsc::Receiver<()>,
        ready_tx: mpsc::SyncSender<Result<(), String>>,
        seg_tx: tokio_mpsc::UnboundedSender<CapturedSegment>,
        app: AppHandle,
        rt: Arc<AppRuntime>,
    ) {
        unsafe {
            let hr = CoInitializeEx(None, COINIT_MULTITHREADED);
            let com_inited = hr.is_ok();

            let enumerator: IMMDeviceEnumerator =
                match CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) {
                    Ok(e) => e,
                    Err(e) => {
                        let msg = format!("初始化 Windows 音频设备枚举器失败：{:?}", e);
                        logger::error(&msg);
                        let _ = ready_tx.send(Err(msg));
                        if com_inited {
                            CoUninitialize();
                        }
                        return;
                    }
                };

            let want_system = matches!(
                capture_mode,
                AudioCaptureMode::SystemLoopback
                    | AudioCaptureMode::AppLoopback
                    | AudioCaptureMode::DualMix
            );
            let want_mic = matches!(
                capture_mode,
                AudioCaptureMode::Microphone | AudioCaptureMode::DualMix
            );

            let mut lanes: Vec<WasapiLane> = Vec::new();
            if want_system {
                let meeting_loopback = {
                    let tts = &rt.snapshot.blocking_lock().tts_settings;
                    if tts.routing_mode == "meeting"
                        && !tts.meeting_loopback_device_id.trim().is_empty()
                    {
                        Some(tts.meeting_loopback_device_id.trim().to_string())
                    } else {
                        None
                    }
                };
                match WasapiLane::open(
                    &enumerator,
                    AudioChannel::System,
                    true,
                    meeting_loopback.as_deref(),
                ) {
                    Ok(lane) => lanes.push(lane),
                    Err(e) => {
                        logger::error(&e);
                        let _ = ready_tx.send(Err(e));
                        if com_inited {
                            CoUninitialize();
                        }
                        return;
                    }
                }
            }
            if want_mic {
                let chosen_mic = rt
                    .snapshot
                    .blocking_lock()
                    .tts_settings
                    .input_device_id
                    .trim()
                    .to_string();
                let mic_res = if !chosen_mic.is_empty() && chosen_mic != "default" {
                    match WasapiLane::open_cpal_mic(&chosen_mic) {
                        Ok(lane) => Ok(lane),
                        Err(e) => {
                            logger::warn(format!("{}，自动回退到系统默认通信麦克风", e));
                            WasapiLane::open(&enumerator, AudioChannel::Mic, false, None)
                        }
                    }
                } else {
                    WasapiLane::open(&enumerator, AudioChannel::Mic, false, None)
                };
                match mic_res {
                    Ok(mut lane) => {
                        lane.processor.enable_aec();
                        lanes.push(lane);
                    }
                    Err(e) => {
                        for l in &mut lanes {
                            l.cpal_stream = None;
                            if let Some(ref ac) = l.audio_client {
                                let _ = ac.Stop();
                            }
                        }
                        logger::error(&e);
                        let _ = ready_tx.send(Err(e));
                        if com_inited {
                            CoUninitialize();
                        }
                        return;
                    }
                }
            }

            let rec_path = std::env::temp_dir()
                .join("Hear-Recordings")
                .join(format!("rec-{}.wav", uuid::Uuid::new_v4()));
            let rec_channels = if lanes.len() >= 2 { 2 } else { 1 };
            let mut recorder =
                StreamingWavRecorder::create(&rec_path, VAD_SAMPLE_RATE, rec_channels).ok();

            let _ = ready_tx.send(Ok(()));

            let mut last_level_emit = Instant::now();
            let mut last_live_tick = Instant::now();
            let mut last_stat_log = Instant::now();
            let started_at = Instant::now();
            let mut silence_warned = false;
            let mut was_paused = false;

            while !stop_flag.load(Ordering::Relaxed) {
                if stop_rx.try_recv().is_ok() {
                    break;
                }

                let is_paused = paused_flag.load(Ordering::Relaxed);
                if is_paused {
                    if !was_paused {
                        was_paused = true;
                        // 刚进入暂停：把当前未切完的句子和已录音频刷盘，允许暂停期间立即试听已录内容
                        for lane in &mut lanes {
                            if let Some(ev) = lane.processor.flush_final() {
                                let _ = seg_tx.send(CapturedSegment {
                                    channel: lane.channel,
                                    event: ev,
                                });
                            }
                        }
                        if let Some(ref mut rec) = recorder {
                            flush_lanes_into_recorder(&mut lanes, rec);
                            let (path, duration_ms, peaks) = rec.snapshot();
                            if duration_ms > 0 {
                                let rt_pause = rt.clone();
                                let app_pause = app.clone();
                                let path_str = path.to_string_lossy().to_string();
                                tauri::async_runtime::spawn(async move {
                                    let pb = {
                                        let mut snap = rt_pause.snapshot.lock().await;
                                        snap.playback.has_audio = true;
                                        snap.playback.audio_path = Some(path_str);
                                        snap.playback.duration_ms = duration_ms;
                                        snap.playback.peaks = peaks;
                                        snap.playback.clone()
                                    };
                                    let _ = app_pause.emit("recording:ready", pb);
                                    rt_pause.save_history(&app_pause).await;
                                });
                            }
                        }
                        let _ = app.emit("audio:level", 0.0f32);
                    }
                    for lane in &mut lanes {
                        lane.discard_packets();
                    }
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                } else if was_paused {
                    was_paused = false;
                    for lane in &mut lanes {
                        lane.last_packet_at = Instant::now();
                    }
                }

                let mut level = 0.0f32;
                let hard_muted_now = rt.mic_muted.load(Ordering::Relaxed);
                if hard_muted_now {
                    // 半双工硬静音模式：播报期间屏蔽所有采集通道并丢弃半截 VAD 缓冲
                    for lane in &mut lanes {
                        lane.discard_packets();
                        lane.processor.discard_current();
                    }
                    std::thread::sleep(Duration::from_millis(12));
                    continue;
                }
                let sys_tts_muted = rt.system_tts_muted.load(Ordering::Relaxed);
                for lane in &mut lanes {
                    // 耳机拔插/设备失效时自动热重连，确保录音声纹与时间持续推进不卡死
                    if lane.needs_reopen {
                        let ready = lane
                            .reopen_after
                            .map(|t| Instant::now() >= t)
                            .unwrap_or(true);
                        if ready {
                            let (chosen_mic, meeting_loopback) = {
                                let tts = &rt.snapshot.blocking_lock().tts_settings;
                                let mic = tts.input_device_id.trim().to_string();
                                let lb = if tts.routing_mode == "meeting"
                                    && !tts.meeting_loopback_device_id.trim().is_empty()
                                {
                                    Some(tts.meeting_loopback_device_id.trim().to_string())
                                } else {
                                    None
                                };
                                (mic, lb)
                            };
                            match lane.reopen_in_place(
                                &enumerator,
                                &chosen_mic,
                                meeting_loopback.as_deref(),
                            ) {
                                Ok(()) => {
                                    logger::info(format!(
                                        "[audio] 热重连成功: channel={:?} sr={} ch={}",
                                        lane.channel, lane.sample_rate, lane.channels
                                    ));
                                    let _ = app.emit(
                                        "session:notice",
                                        "检测到音频设备变化（耳机插拔），已自动重新连接并继续录制",
                                    );
                                }
                                Err(e) => {
                                    logger::warn(format!(
                                        "[audio] 热重连 {:?} 暂未就绪，400ms 后重试：{}",
                                        lane.channel, e
                                    ));
                                    lane.reopen_after =
                                        Some(Instant::now() + Duration::from_millis(400));
                                }
                            }
                        }
                        continue;
                    }
                    // 全双工模式：本地扬声器播报译文时只屏蔽 System（防止 WASAPI 内录回传听见自己的声音），
                    // 麦克风保持全程开启并通过 NLMS AEC 实时抵消扬声器回声，实现边播边说不漏录！
                    if lane.channel == AudioChannel::System && sys_tts_muted {
                        lane.discard_packets();
                        lane.processor.discard_current();
                        continue;
                    }
                    let fe = if lane.channel == AudioChannel::Mic {
                        Some(rt.aec_far_end.as_ref())
                    } else {
                        None
                    };
                    let l = lane.drain_packets(&seg_tx, fe);
                    if l > level {
                        level = l;
                    }
                }

                // 单路写入 1 声道 WAV；双路混合写入 2 声道立体声分轨 WAV（左声道=系统声/对方，右声道=麦克风/我）
                if let Some(ref mut rec) = recorder {
                    if lanes.len() == 1 {
                        if !lanes[0].rec_queue.is_empty() {
                            let buf: Vec<f32> = lanes[0].rec_queue.drain(..).collect();
                            let _ = rec.write_f32(&buf);
                        }
                    } else if lanes.len() >= 2 {
                        let (first, rest) = lanes.split_at_mut(1);
                        let q0 = &mut first[0].rec_queue;
                        let q1 = &mut rest[0].rec_queue;
                        let common = q0.len().min(q1.len());
                        if common > 0 {
                            let mut stereo = Vec::with_capacity(common * 2);
                            for _ in 0..common {
                                let a = q0.pop_front().unwrap_or(0.0);
                                let b = q1.pop_front().unwrap_or(0.0);
                                stereo.push(a.clamp(-1.0, 1.0));
                                stereo.push(b.clamp(-1.0, 1.0));
                            }
                            let _ = rec.write_f32(&stereo);
                        }
                        // 若其中一路暂停吐包（例如系统扬声器未播放任何声音），补零交织对齐另一路，防止积压超过 250ms
                        let max_lead = (VAD_SAMPLE_RATE as usize) / 4;
                        if q0.len() > max_lead {
                            let extra = q0.len() - max_lead;
                            let mut stereo = Vec::with_capacity(extra * 2);
                            for s in q0.drain(..extra) {
                                stereo.push(s.clamp(-1.0, 1.0));
                                stereo.push(0.0);
                            }
                            let _ = rec.write_f32(&stereo);
                        } else if q1.len() > max_lead {
                            let extra = q1.len() - max_lead;
                            let mut stereo = Vec::with_capacity(extra * 2);
                            for s in q1.drain(..extra) {
                                stereo.push(0.0);
                                stereo.push(s.clamp(-1.0, 1.0));
                            }
                            let _ = rec.write_f32(&stereo);
                        }
                    }

                    if last_live_tick.elapsed().as_millis() >= 300 {
                        last_live_tick = Instant::now();
                        let _ = rec.flush_header();
                        let dur = rec.duration_ms();
                        let full_peaks = rec.peaks.clone();
                        let tail_peaks: Vec<f32> = rec
                            .peaks
                            .iter()
                            .rev()
                            .take(180)
                            .copied()
                            .collect::<Vec<f32>>()
                            .into_iter()
                            .rev()
                            .collect();
                        let path_str = rec_path.to_string_lossy().to_string();
                        let rt_tick = rt.clone();
                        tauri::async_runtime::spawn(async move {
                            let mut snap = rt_tick.snapshot.lock().await;
                            snap.playback.has_audio = dur > 0;
                            snap.playback.audio_path = Some(path_str);
                            snap.playback.duration_ms = dur;
                            if !full_peaks.is_empty() {
                                snap.playback.peaks = full_peaks;
                            }
                        });
                        let _ = app.emit(
                            "recording:live_tick",
                            serde_json::json!({
                                "durationMs": dur,
                                "peaks": tail_peaks
                            }),
                        );
                    }
                }

                if last_level_emit.elapsed().as_millis() >= 66 {
                    last_level_emit = Instant::now();
                    let _ = app.emit("audio:level", level);
                }
                if last_stat_log.elapsed().as_secs() >= 3 {
                    last_stat_log = Instant::now();
                    for lane in &lanes {
                        logger::info(format!(
                            "[audio] channel={:?} sr={} ch={} frames={} peak={:.5} vad_speech={}",
                            lane.channel,
                            lane.sample_rate,
                            lane.channels,
                            lane.stat_frames,
                            lane.stat_peak,
                            lane.stat_speech_frames
                        ));
                    }
                    if !silence_warned && started_at.elapsed().as_secs() >= 7 {
                        let any_signal = lanes.iter().any(|l| l.stat_peak > 0.0005);
                        if !any_signal {
                            silence_warned = true;
                            let hint = if want_system && !want_mic {
                                "当前电脑扬声器未检测到正在播放的声音（系统内录仅录电脑播放音视频）；如果你是在对着麦克风说话，请点击右侧切换到「默认麦克风」或「双路混合」"
                            } else {
                                "已录音超过 7 秒但未检测到有效声音信号，请检查 Windows 默认音频设备是否静音或选错设备"
                            };
                            logger::warn(hint);
                            let _ = app.emit("session:notice", hint);
                        }
                    }
                }
                std::thread::sleep(Duration::from_millis(10));
            }

            // 停录前将残留的录音队列混合刷盘，避免丢掉最后 0.25s 录音
            if let Some(ref mut rec) = recorder {
                flush_lanes_into_recorder(&mut lanes, rec);
            }

            for lane in &mut lanes {
                lane.stop_and_flush(&seg_tx);
            }
            drop(lanes);
            drop(seg_tx);

            if let Some(rec) = recorder.take() {
                if let Ok((path, duration_ms, peaks)) = rec.finalize() {
                    if duration_ms > 0 {
                        let path_str = path.to_string_lossy().to_string();
                        let mut snap = rt.snapshot.blocking_lock();
                        snap.playback.has_audio = true;
                        snap.playback.audio_path = Some(path_str);
                        snap.playback.duration_ms = duration_ms;
                        snap.playback.peaks = peaks;
                        let pb = snap.playback.clone();
                        drop(snap);
                        let _ = app.emit("recording:ready", pb);
                    }
                }
            }
            let _ = app.emit("audio:level", 0.0f32);

            if com_inited {
                CoUninitialize();
            }
        }
    }
}

#[cfg(not(target_os = "windows"))]
mod cpal_fallback {
    use super::*;
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use cpal::{SampleFormat, Stream, StreamConfig};

    fn build_cpal_stream<F>(
        device: &cpal::Device,
        config: &StreamConfig,
        sample_format: SampleFormat,
        on_samples: F,
        err_app: AppHandle,
    ) -> Result<Stream, String>
    where
        F: FnMut(&[f32]) + Send + 'static,
    {
        let err_fn = move |err| {
            let msg = format!("音频采集流异常：{}", err);
            logger::error(&msg);
            let _ = err_app.emit("session:error", msg);
        };
        match sample_format {
            SampleFormat::F32 => {
                let mut cb = on_samples;
                device
                    .build_input_stream(config, move |data: &[f32], _| cb(data), err_fn, None)
                    .map_err(|e| format!("创建 F32 音频流失败：{}", e))
            }
            SampleFormat::I16 => {
                let mut cb = on_samples;
                device
                    .build_input_stream(
                        config,
                        move |data: &[i16], _| {
                            let f: Vec<f32> = data.iter().map(|&s| s as f32 / 32768.0).collect();
                            cb(&f);
                        },
                        err_fn,
                        None,
                    )
                    .map_err(|e| format!("创建 I16 音频流失败：{}", e))
            }
            other => Err(format!("不支持的音频采样格式：{:?}", other)),
        }
    }

    pub fn run_capture_thread(
        _capture_mode: AudioCaptureMode,
        stop_flag: Arc<AtomicBool>,
        paused_flag: Arc<AtomicBool>,
        stop_rx: mpsc::Receiver<()>,
        ready_tx: mpsc::SyncSender<Result<(), String>>,
        seg_tx: tokio_mpsc::UnboundedSender<CapturedSegment>,
        app: AppHandle,
        rt: Arc<AppRuntime>,
    ) {
        let host = cpal::default_host();
        let Some(dev) = host.default_input_device() else {
            let _ = ready_tx.send(Err("未找到默认输入音频设备".to_string()));
            return;
        };
        let supported = match dev.default_input_config() {
            Ok(s) => s,
            Err(e) => {
                let _ = ready_tx.send(Err(format!("获取输入设备参数失败：{}", e)));
                return;
            }
        };
        let fmt = supported.sample_format();
        let cfg: StreamConfig = supported.into();
        let proc = Arc::new(std::sync::Mutex::new(LaneProcessor::new(
            cfg.sample_rate.0,
            cfg.channels as usize,
        )));
        let rec_path = std::env::temp_dir()
            .join("Hear-Recordings")
            .join(format!("rec-{}.wav", uuid::Uuid::new_v4()));
        let recorder = StreamingWavRecorder::create(&rec_path, VAD_SAMPLE_RATE, 1)
            .ok()
            .map(|r| Arc::new(std::sync::Mutex::new(r)));

        let proc_cb = proc.clone();
        let tx_cb = seg_tx.clone();
        let app_cb = app.clone();
        let rec_cb = recorder.clone();
        let stop_cb = stop_flag.clone();
        let pause_cb = paused_flag.clone();
        let mut last_level_emit = Instant::now();

        let stream = match build_cpal_stream(
            &dev,
            &cfg,
            fmt,
            move |samples| {
                if stop_cb.load(Ordering::Relaxed) || pause_cb.load(Ordering::Relaxed) {
                    return;
                }
                if let Ok(mut p) = proc_cb.lock() {
                    p.push_interleaved(samples, |frame, _, level, ev| {
                        if let Some(ref rec) = rec_cb {
                            if let Ok(mut r) = rec.lock() {
                                let _ = r.write_f32(frame);
                            }
                        }
                        if last_level_emit.elapsed().as_millis() >= 66 {
                            last_level_emit = Instant::now();
                            let _ = app_cb.emit("audio:level", level);
                        }
                        if let Some(event) = ev {
                            let _ = tx_cb.send(CapturedSegment {
                                channel: AudioChannel::Mic,
                                event,
                            });
                        }
                    });
                }
            },
            app.clone(),
        ) {
            Ok(s) => s,
            Err(e) => {
                let _ = ready_tx.send(Err(e));
                return;
            }
        };
        if let Err(e) = stream.play() {
            let _ = ready_tx.send(Err(format!("启动音频采集失败：{}", e)));
            return;
        }
        let _ = ready_tx.send(Ok(()));
        let _ = stop_rx.recv();
        stop_flag.store(true, Ordering::Relaxed);
        drop(stream);

        if let Ok(mut p) = proc.lock() {
            if let Some(ev) = p.flush_final() {
                let _ = seg_tx.send(CapturedSegment {
                    channel: AudioChannel::Mic,
                    event: ev,
                });
            }
        }
        drop(seg_tx);

        if let Some(rec_arc) = recorder {
            if let Ok(rec_mutex) = Arc::try_unwrap(rec_arc) {
                if let Ok(rec) = rec_mutex.into_inner() {
                    if let Ok((path, duration_ms, peaks)) = rec.finalize() {
                        if duration_ms > 0 {
                            let rt_done = rt.clone();
                            let app_done = app.clone();
                            let path_str = path.to_string_lossy().to_string();
                            tauri::async_runtime::spawn(async move {
                                let pb = {
                                    let mut snap = rt_done.snapshot.lock().await;
                                    snap.playback.has_audio = true;
                                    snap.playback.audio_path = Some(path_str);
                                    snap.playback.duration_ms = duration_ms;
                                    snap.playback.peaks = peaks;
                                    snap.playback.clone()
                                };
                                let _ = app_done.emit("recording:ready", pb);
                            });
                        }
                    }
                }
            }
        }
        let _ = app.emit("audio:level", 0.0f32);
    }
}

/// 正在运行的实时采集与翻译会话句柄（支持暂停/继续/优雅结束）
pub struct LiveCaptureHandle {
    stop_flag: Arc<AtomicBool>,
    paused_flag: Arc<AtomicBool>,
    stop_tx: Option<mpsc::Sender<()>>,
    capture_thread: Option<JoinHandle<()>>,
    worker_task: tauri::async_runtime::JoinHandle<()>,
}

impl LiveCaptureHandle {
    pub fn start(
        app: AppHandle,
        rt: Arc<AppRuntime>,
        capture_mode: AudioCaptureMode,
    ) -> Result<Self, String> {
        let stop_flag = Arc::new(AtomicBool::new(false));
        let paused_flag = Arc::new(AtomicBool::new(false));
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::sync_channel::<Result<(), String>>(1);
        let (seg_tx, mut seg_rx) = tokio_mpsc::unbounded_channel::<CapturedSegment>();

        let app_capture = app.clone();
        let rt_capture = rt.clone();
        let stop_flag_capture = stop_flag.clone();
        let paused_flag_capture = paused_flag.clone();

        let capture_thread = std::thread::Builder::new()
            .name("hear-audio-capture".to_string())
            .spawn(move || {
                #[cfg(target_os = "windows")]
                win_wasapi::run_capture_thread(
                    capture_mode,
                    stop_flag_capture,
                    paused_flag_capture,
                    stop_rx,
                    ready_tx,
                    seg_tx,
                    app_capture,
                    rt_capture,
                );
                #[cfg(not(target_os = "windows"))]
                cpal_fallback::run_capture_thread(
                    capture_mode,
                    stop_flag_capture,
                    paused_flag_capture,
                    stop_rx,
                    ready_tx,
                    seg_tx,
                    app_capture,
                    rt_capture,
                );
            })
            .map_err(|e| format!("启动音频采集线程失败：{}", e))?;

        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => {}
            Ok(Err(msg)) => {
                let _ = capture_thread.join();
                return Err(msg);
            }
            Err(_) => {
                let _ = stop_tx.send(());
                return Err("音频采集初始化超时，请检查 Windows 音频设备权限".to_string());
            }
        }

        // 启动异步推理消费协程：VAD 片段 -> /v1/asr -> 流式/JSON /v1/translate -> 实时推送主窗与悬浮字幕
        let worker_task = tauri::async_runtime::spawn(async move {
            let mut last_preview_at: Option<Instant> = None;
            let mut voice_clusterer = VoiceprintClusterer::new();

            while let Some(mut item) = seg_rx.recv().await {
                // 合并/丢弃积压的旧 Partial 预览事件：若队列里已有更新的 Partial 或已到来的 Final，直接跳到最新事件，
                // 避免 Final 终稿翻译被旧预览请求堵在队列后面导致延迟比 iOS 慢数秒！
                if matches!(item.event, SegmentEvent::Partial { .. }) {
                    while let Ok(next) = seg_rx.try_recv() {
                        let is_final = matches!(next.event, SegmentEvent::Final { .. });
                        item = next;
                        if is_final {
                            break;
                        }
                    }
                }
                let (
                    asr_url,
                    asr_tok,
                    mt_url,
                    mt_tok,
                    src_lang,
                    dst_lang,
                    lock_src,
                    glossary,
                ) = {
                    let snap = rt.snapshot.lock().await;
                    let (a_url, a_tok) = match snap.service_config.asr_source {
                        EngineSource::Local => (
                            snap.service_config.local_service_address.clone(),
                            snap.service_config.local_access_token.clone(),
                        ),
                        EngineSource::Cloud => (
                            snap.service_config.cloud_service_address.clone(),
                            snap.service_config.cloud_access_token.clone(),
                        ),
                    };
                    let (m_url, m_tok) = match snap.service_config.mt_source {
                        EngineSource::Local => (
                            snap.service_config.local_service_address.clone(),
                            snap.service_config.local_access_token.clone(),
                        ),
                        EngineSource::Cloud => (
                            snap.service_config.cloud_service_address.clone(),
                            snap.service_config.cloud_access_token.clone(),
                        ),
                    };
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

                let languages_hdr = if lock_src {
                    src_lang.clone()
                } else {
                    format!("{},{}", src_lang, dst_lang)
                };
                let asr_token_opt = if asr_tok.trim().is_empty() {
                    None
                } else {
                    Some(asr_tok.as_str())
                };
                let mt_token_opt = if mt_tok.trim().is_empty() {
                    None
                } else {
                    Some(mt_tok.as_str())
                };

                match item.event {
                    SegmentEvent::Partial { samples, .. } => {
                        let throttled = last_preview_at
                            .map(|t| t.elapsed().as_millis() < 450)
                            .unwrap_or(false);
                        if throttled || samples.len() < (VAD_SAMPLE_RATE as usize / 2) {
                            continue;
                        }
                        last_preview_at = Some(Instant::now());
                        let wav = encode_wav_16k_mono(&samples);
                        if let Ok((text, detected_lang)) = rt
                            .cloud
                            .transcribe_wav(
                                &asr_url,
                                wav,
                                &languages_hdr,
                                &src_lang,
                                true,
                                asr_token_opt,
                            )
                            .await
                        {
                            let clean_src = text.trim().to_string();
                            if has_real_speech_text(&clean_src) {
                                // 预览阶段同样拦截 10 秒内扬声器刚播报的译文回声，避免实时预览框闪出回声复录
                                let is_partial_echo = {
                                    let guard = rt.last_spoken_tts.lock().await;
                                    guard.iter().any(|(spoken_text, spoken_at)| {
                                        spoken_at.elapsed().as_secs() <= 10
                                            && is_likely_tts_echo(&clean_src, spoken_text)
                                    })
                                };
                                if is_partial_echo {
                                    continue;
                                }
                                // 1. 检查原文是否与上一轮预览完全一致：若中文/原文未变且已有译文，直接跳过重复翻译，绝不反复重写！
                                let (same_src, has_existing_tr, keep_tr) = {
                                    let mut snap = rt.snapshot.lock().await;
                                    let prev_src = snap.live_partial_source.trim().to_string();
                                    let prev_tr = snap.live_partial_translation.trim().to_string();
                                    let has_tr = !prev_tr.is_empty()
                                        && prev_tr != "正在翻译…"
                                        && prev_tr != "翻译中…"
                                        && prev_tr != "正在识别…";
                                    let same = !prev_src.is_empty() && prev_src == clean_src;
                                    snap.live_partial_source = clean_src.clone();
                                    let display_tr = if has_tr {
                                        prev_tr
                                    } else {
                                        "正在翻译…".to_string()
                                    };
                                    (same, has_tr, display_tr)
                                };
                                if same_src && has_existing_tr {
                                    continue;
                                }
                                let _ = app.emit(
                                    "subtitle:partial",
                                    serde_json::json!({
                                        "source": clean_src,
                                        "translation": keep_tr
                                    }),
                                );
                                // 边说边译：
                                // - 首次尚无译文时，流式逐字输出保证最低首字延迟；
                                // - 已有译文时，不再在流式阶段用短前缀擦掉已显示译文，而是等新译文完整生成后一次性平滑修正替换！
                                let (p_src, p_dst) = resolve_translation_direction(
                                    &clean_src,
                                    &detected_lang,
                                    &src_lang,
                                    &dst_lang,
                                    lock_src,
                                );
                                let p_prompt =
                                    build_translation_prompt(&clean_src, &p_src, &p_dst, &glossary);
                                let app_p = app.clone();
                                let src_p = clean_src.clone();
                                if let Ok(raw_p) = rt
                                    .cloud
                                    .translate_stream(
                                        &mt_url,
                                        &p_prompt,
                                        true,
                                        mt_token_opt,
                                        |delta_p| {
                                            if has_existing_tr {
                                                // 已有完整预览译文时，禁止用流式短前缀反复清空重写
                                                return;
                                            }
                                            let c = clean_translation_output(delta_p);
                                            if !c.is_empty() {
                                                let _ = app_p.emit(
                                                    "subtitle:partial",
                                                    serde_json::json!({
                                                        "source": src_p,
                                                        "translation": c
                                                    }),
                                                );
                                            }
                                        },
                                    )
                                    .await
                                {
                                    let final_p = clean_translation_output(&raw_p);
                                    if !final_p.is_empty() && final_p != keep_tr {
                                        {
                                            let mut snap = rt.snapshot.lock().await;
                                            snap.live_partial_translation = final_p.clone();
                                        }
                                        let _ = app.emit(
                                            "subtitle:partial",
                                            serde_json::json!({
                                                "source": clean_src,
                                                "translation": final_p
                                            }),
                                        );
                                    }
                                }
                            }
                        }
                    }
                    SegmentEvent::Final {
                        segment_id,
                        start_ms,
                        end_ms,
                        samples,
                    } => {
                        if samples.len() < (VAD_SAMPLE_RATE as usize / 4) {
                            continue;
                        }
                        let t0 = Instant::now();
                        let wav = encode_wav_16k_mono(&samples);
                        let (source_text, detected_lang, can_correct) = match rt
                            .cloud
                            .transcribe_wav_staged(
                                &asr_url,
                                wav.clone(),
                                &languages_hdr,
                                &src_lang,
                                false,
                                Some("first"),
                                asr_token_opt,
                            )
                            .await
                        {
                            Ok(triple) => {
                                logger::info(format!(
                                    "[asr:first] seg={} ms={} lang={} chars={} can_correct={}",
                                    segment_id,
                                    t0.elapsed().as_millis(),
                                    triple.1,
                                    triple.0.chars().count(),
                                    triple.2
                                ));
                                triple
                            }
                            Err(err) => {
                                logger::error(format!("[asr] seg={} failed: {}", segment_id, err));
                                let _ = app.emit("session:error", err);
                                continue;
                            }
                        };

                        if !has_real_speech_text(&source_text) {
                            let mut snap = rt.snapshot.lock().await;
                            snap.live_partial_source.clear();
                            snap.live_partial_translation.clear();
                            let _ = app.emit(
                                "subtitle:partial",
                                serde_json::json!({ "source": "", "translation": "" }),
                            );
                            continue;
                        }

                        // 文本级回声防御：若正在播报或 10 秒内刚播报过高度重合的译文（最近 4 句队列），直接丢弃，杜绝自动朗读被再次收音翻译
                        {
                            let is_echo = {
                                let guard = rt.last_spoken_tts.lock().await;
                                guard.iter().any(|(spoken_text, spoken_at)| {
                                    spoken_at.elapsed().as_secs() <= 10
                                        && is_likely_tts_echo(&source_text, spoken_text)
                                })
                            };
                            if is_echo {
                                logger::info(format!(
                                    "[echo-filter] 丢弃疑似扬声器回声复录: {}",
                                    source_text.trim()
                                ));
                                let mut snap = rt.snapshot.lock().await;
                                snap.live_partial_source.clear();
                                snap.live_partial_translation.clear();
                                let _ = app.emit(
                                    "subtitle:partial",
                                    serde_json::json!({ "source": "", "translation": "" }),
                                );
                                continue;
                            }
                        }

                        let (actual_src, actual_dst) = resolve_translation_direction(
                            &source_text,
                            &detected_lang,
                            &src_lang,
                            &dst_lang,
                            lock_src,
                        );

                        let speaker_label = if item.channel == AudioChannel::Mic {
                            "我".to_string()
                        } else {
                            voice_clusterer.assign_speaker(&samples, "对方")
                        };

                        let seg_uuid = format!("seg-{}-{}", segment_id, uuid::Uuid::new_v4());
                        // 缓存本句原始 16kHz 单声道 WAV 字节，供录制过程中随时调用 Qwen3-TTS 原声克隆与单击播放原音（上限 64 条防止长会议内存膨胀）
                        {
                            let mut wav_map = rt.segment_wavs.lock().await;
                            if wav_map.len() >= 64 {
                                let keep_ids: std::collections::HashSet<String> = {
                                    let snap = rt.snapshot.lock().await;
                                    snap.segments
                                        .iter()
                                        .rev()
                                        .take(48)
                                        .map(|s| s.id.clone())
                                        .collect()
                                };
                                wav_map.retain(|k, _| keep_ids.contains(k));
                            }
                            wav_map.insert(seg_uuid.clone(), wav.clone());
                        }

                        let (recent_ctx, preview_baseline): (Vec<(String, String)>, Option<String>) = {
                            let snap = rt.snapshot.lock().await;
                            let ctx = snap
                                .segments
                                .iter()
                                .rev()
                                .filter(|s| {
                                    s.status == "final"
                                        && !s.source_text.trim().is_empty()
                                        && !s.translated_text.trim().is_empty()
                                })
                                .take(2)
                                .map(|s| (s.source_text.clone(), s.translated_text.clone()))
                                .collect::<Vec<_>>()
                                .into_iter()
                                .rev()
                                .collect();
                            let prev_tr = snap.live_partial_translation.trim().to_string();
                            let baseline = if !prev_tr.is_empty()
                                && prev_tr != "翻译中…"
                                && prev_tr != "正在翻译…"
                                && prev_tr != "正在识别…"
                            {
                                Some(prev_tr)
                            } else {
                                None
                            };
                            (ctx, baseline)
                        };

                        let mut seg = SubtitleSegment {
                            id: seg_uuid.clone(),
                            seq: segment_id,
                            start_ms,
                            end_ms,
                            channel: item.channel,
                            speaker_label: Some(speaker_label),
                            source_lang: actual_src.clone(),
                            target_lang: actual_dst.clone(),
                            source_text: source_text.clone(),
                            translated_text: preview_baseline
                                .clone()
                                .unwrap_or_else(|| "翻译中…".to_string()),
                            baseline_translated: preview_baseline,
                            status: "preview".to_string(),
                            is_edited: None,
                        };

                        {
                            let mut snap = rt.snapshot.lock().await;
                            snap.segments.push(seg.clone());
                            // 该句已转为正式对话卡片：立刻清空下方「实时识别中…」虚线预览框，避免上下同时显示重复原文
                            snap.live_partial_source.clear();
                            snap.live_partial_translation.clear();
                        }
                        let _ = app.emit("segment:upsert", &seg);
                        let _ = app.emit(
                            "subtitle:partial",
                            serde_json::json!({
                                "source": "",
                                "translation": ""
                            }),
                        );

                        let t_mt = Instant::now();
                        let prompt = build_translation_prompt_with_context(
                            &source_text,
                            &actual_src,
                            &actual_dst,
                            &glossary,
                            &recent_ctx,
                        );
                        let app_stream = app.clone();
                        let mut seg_cb = seg.clone();
                        let has_baseline = seg.baseline_translated.is_some();

                        match rt
                            .cloud
                            .translate_stream(&mt_url, &prompt, false, mt_token_opt, |partial_raw| {
                                // 若该句已有预览译文（baseline_translated），流式阶段不再用短前缀擦掉重打，
                                // 等终稿译文完成后一次性平滑替换为 diff 修正高亮！
                                if has_baseline {
                                    return;
                                }
                                let cleaned = clean_translation_output(partial_raw);
                                if !cleaned.is_empty() {
                                    seg_cb.translated_text = cleaned;
                                    let _ = app_stream.emit("segment:upsert", &seg_cb);
                                }
                            })
                            .await
                        {
                            Ok(full_raw) => {
                                let final_text = clean_translation_output(&full_raw);
                                logger::info(format!(
                                    "[mt] seg={} ms={} chars={}",
                                    segment_id,
                                    t_mt.elapsed().as_millis(),
                                    final_text.chars().count()
                                ));
                                seg.translated_text = if final_text.is_empty() {
                                    source_text.clone()
                                } else {
                                    final_text
                                };
                                seg.status = "final".to_string();
                                {
                                    let mut snap = rt.snapshot.lock().await;
                                    if let Some(s) = snap.segments.iter_mut().find(|s| s.id == seg_uuid) {
                                        *s = seg.clone();
                                    }
                                    snap.live_partial_source.clear();
                                    snap.live_partial_translation.clear();
                                }
                                let _ = app.emit("segment:upsert", &seg);
                                let _ = app.emit(
                                    "subtitle:partial",
                                    serde_json::json!({ "source": "", "translation": "" }),
                                );
                                rt.save_history(&app).await;

                                // 若服务端为 sensevoice+whisper 双阶段模式，对 >= 1.2s 且 >= 5 字符的句子后台静默触发 Whisper 二次精修（跳过极短词减少云端队列占用）
                                let seg_dur_ms = end_ms.saturating_sub(start_ms);
                                let char_count = source_text.trim().chars().count();
                                if can_correct && seg_dur_ms >= 1200 && char_count >= 5 {
                                    let rt_corr = rt.clone();
                                    let app_corr = app.clone();
                                    let asr_url_c = asr_url.clone();
                                    let asr_tok_c = asr_tok.clone();
                                    let mt_url_c = mt_url.clone();
                                    let mt_tok_c = mt_tok.clone();
                                    let langs_c = languages_hdr.clone();
                                    let src_lang_c = actual_src.clone();
                                    let dst_lang_c = actual_dst.clone();
                                    let glossary_c = glossary.clone();
                                    let recent_ctx_c = recent_ctx.clone();
                                    let orig_src_c = source_text.clone();
                                    let seg_uuid_c = seg_uuid.clone();
                                    tauri::async_runtime::spawn(async move {
                                        let a_opt = if asr_tok_c.trim().is_empty() {
                                            None
                                        } else {
                                            Some(asr_tok_c.as_str())
                                        };
                                        let m_opt = if mt_tok_c.trim().is_empty() {
                                            None
                                        } else {
                                            Some(mt_tok_c.as_str())
                                        };
                                        let Ok((refined, _, _)) = rt_corr
                                            .cloud
                                            .transcribe_wav_staged(
                                                &asr_url_c,
                                                wav,
                                                &langs_c,
                                                &src_lang_c,
                                                false,
                                                Some("correct"),
                                                a_opt,
                                            )
                                            .await
                                        else {
                                            return;
                                        };
                                        let clean_ref = refined.trim().to_string();
                                        if clean_ref.is_empty() || clean_ref == orig_src_c.trim() {
                                            return;
                                        }
                                        // 仅在用户尚未手动改过该句时应用 Whisper 后台精修
                                        let should_retranslate = {
                                            let mut snap = rt_corr.snapshot.lock().await;
                                            if let Some(s) =
                                                snap.segments.iter_mut().find(|s| s.id == seg_uuid_c)
                                            {
                                                if s.is_edited == Some(true) {
                                                    false
                                                } else {
                                                    s.baseline_translated =
                                                        Some(s.translated_text.clone());
                                                    s.source_text = clean_ref.clone();
                                                    s.is_edited = Some(true);
                                                    let _ = app_corr.emit("segment:upsert", &*s);
                                                    true
                                                }
                                            } else {
                                                false
                                            }
                                        };
                                        if !should_retranslate {
                                            return;
                                        }
                                        let (ref_src, ref_dst) = resolve_translation_direction(
                                            &clean_ref,
                                            &src_lang_c,
                                            &src_lang_c,
                                            &dst_lang_c,
                                            false,
                                        );
                                        let prompt_c = build_translation_prompt_with_context(
                                            &clean_ref,
                                            &ref_src,
                                            &ref_dst,
                                            &glossary_c,
                                            &recent_ctx_c,
                                        );
                                        if let Ok(raw_tr) = rt_corr
                                            .cloud
                                            .translate_stream(&mt_url_c, &prompt_c, false, m_opt, |_| {})
                                            .await
                                        {
                                            let tr_clean = clean_translation_output(&raw_tr);
                                            if !tr_clean.is_empty() {
                                                let mut updated_seg = None;
                                                {
                                                    let mut snap = rt_corr.snapshot.lock().await;
                                                    if let Some(s) = snap
                                                        .segments
                                                        .iter_mut()
                                                        .find(|s| s.id == seg_uuid_c)
                                                    {
                                                        s.translated_text = tr_clean;
                                                        s.status = "final".to_string();
                                                        updated_seg = Some(s.clone());
                                                    }
                                                }
                                                if let Some(u) = updated_seg {
                                                    let _ = app_corr.emit("segment:upsert", &u);
                                                    rt_corr.save_history(&app_corr).await;
                                                }
                                            }
                                        }
                                    });
                                }
                            }
                            Err(err) => {
                                logger::error(format!("[mt] seg={} failed: {}", segment_id, err));
                                seg.translated_text = format!("（翻译失败：{}）", err);
                                seg.status = "error".to_string();
                                {
                                    let mut snap = rt.snapshot.lock().await;
                                    if let Some(s) = snap.segments.iter_mut().find(|s| s.id == seg_uuid) {
                                        *s = seg.clone();
                                    }
                                    snap.live_partial_source.clear();
                                    snap.live_partial_translation.clear();
                                }
                                let _ = app.emit("segment:upsert", &seg);
                                let _ = app.emit("session:error", err);
                            }
                        }
                    }
                }
            }
        });

        Ok(Self {
            stop_flag,
            paused_flag,
            stop_tx: Some(stop_tx),
            capture_thread: Some(capture_thread),
            worker_task,
        })
    }

    pub fn set_paused(&self, paused: bool) {
        self.paused_flag.store(paused, Ordering::Relaxed);
    }

    pub fn is_paused(&self) -> bool {
        self.paused_flag.load(Ordering::Relaxed)
    }

    pub fn stop(mut self) {
        self.stop_flag.store(true, Ordering::Relaxed);
        if let Some(tx) = self.stop_tx.take() {
            let _ = tx.send(());
        }
        if let Some(handle) = self.capture_thread.take() {
            let _ = handle.join();
        }
        let _ = &self.worker_task;
    }
}

/// 离线批量切分 16 kHz 单声道音频为带精确起止时间戳的语音段落（用于本地音视频文件导入）
pub fn segment_offline_16k_mono(samples: &[f32]) -> Vec<(u64, u64, Vec<f32>)> {
    let mut lane = LaneProcessor::new(VAD_SAMPLE_RATE, 1);
    let mut out: Vec<(u64, u64, Vec<f32>)> = Vec::new();
    let min_samples = (VAD_SAMPLE_RATE as usize) / 4;

    lane.push_interleaved(samples, |_, _, _, ev| {
        if let Some(SegmentEvent::Final {
            start_ms,
            end_ms,
            samples: seg,
            ..
        }) = ev
        {
            if seg.len() >= min_samples {
                out.push((start_ms, end_ms, seg));
            }
        }
    });
    if let Some(SegmentEvent::Final {
        start_ms,
        end_ms,
        samples: seg,
        ..
    }) = lane.flush_final()
    {
        if seg.len() >= min_samples {
            out.push((start_ms, end_ms, seg));
        }
    }

    if out.is_empty() && samples.len() >= min_samples {
        let peak = samples.iter().fold(0.0f32, |a, &s| a.max(s.abs()));
        if peak > 0.003 {
            let chunk_len = (VAD_SAMPLE_RATE as usize) * 12;
            let mut offset = 0usize;
            while offset < samples.len() {
                let end = (offset + chunk_len).min(samples.len());
                if end - offset >= min_samples {
                    let start_ms = (offset as u64 * 1000) / VAD_SAMPLE_RATE as u64;
                    let end_ms = (end as u64 * 1000) / VAD_SAMPLE_RATE as u64;
                    out.push((start_ms, end_ms, samples[offset..end].to_vec()));
                }
                offset = end;
            }
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_hymt_prompt_with_glossary_and_cleans_think_tags() {
        let p = build_translation_prompt("Hello Hy-MT2 world", "en", "zh", "Hy-MT2=混元翻译\nFoo=Bar");
        assert!(p.contains("Hy-MT2 翻译成 混元翻译"));
        assert!(!p.contains("Foo"));
        assert!(p.contains("将以下文本翻译为中文"));

        assert_eq!(
            clean_translation_output("<think>reasoning</think>\n你好世界"),
            "你好世界"
        );
    }

    #[test]
    fn resamples_48k_stereo_to_16k_mono_and_triggers_vad() {
        let mut lane = LaneProcessor::new(48_000, 2);
        let mut stereo = Vec::with_capacity(19_200);
        for i in 0..9_600 {
            let v = ((i as f32) * 0.05).sin() * 0.25;
            stereo.push(v);
            stereo.push(v);
        }
        let mut frames_seen = 0;
        let mut speech_frames = 0;
        lane.push_interleaved(&stereo, |_, has_speech, _, _| {
            frames_seen += 1;
            if has_speech {
                speech_frames += 1;
            }
        });
        assert!(frames_seen >= 5 && frames_seen <= 7, "frames={}", frames_seen);
        // 连续 3 帧抗键盘敲击起振保护后，剩余帧均应触发人声
        assert!(speech_frames >= 3, "speech_frames={}", speech_frames);
    }

    #[test]
    fn resolves_translation_direction_without_same_language_loop() {
        // 即使 ASR 把中文误标为 en 或 zh-CN，且目标是 zh，也必须翻转成 zh -> en，绝不中译中
        assert_eq!(
            resolve_translation_direction("今天天气真不错", "en", "en", "zh", false),
            ("zh".to_string(), "en".to_string())
        );
        assert_eq!(
            resolve_translation_direction("今天天气真不错", "zh-CN", "en", "zh", true),
            ("zh".to_string(), "en".to_string())
        );
        assert_eq!(
            resolve_translation_direction("今天天气真不错", "zh", "auto", "zh", false),
            ("zh".to_string(), "en".to_string())
        );
        assert_eq!(
            resolve_translation_direction("Hello world today", "en-US", "en", "zh", false),
            ("en".to_string(), "zh".to_string())
        );
    }

    #[test]
    fn filters_punctuation_only_and_detects_tts_echo() {
        assert!(!has_real_speech_text("."));
        assert!(!has_real_speech_text("... 。?! "));
        assert!(has_real_speech_text("你好。"));
        assert!(is_likely_tts_echo(
            "Let me see how the results are now",
            "Let me see how the results are now."
        ));
        assert!(is_likely_tts_echo(
            "how the results are",
            "Let me see how the results are now."
        ));
        assert!(!is_likely_tts_echo(
            "我不知道你到底是怎么想的",
            "Let me see how the results are now."
        ));
    }

    #[test]
    fn antialias_downsample_48k_to_16k_attenuates_10khz_sine() {
        let mut proc = LaneProcessor::new(48_000, 1);
        let n = 48_000 / 2; // 0.5s of 10 kHz sine wave
        let sine: Vec<f32> = (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * 10_000.0 * i as f32 / 48_000.0).sin())
            .collect();
        let mut out_samples = Vec::new();
        proc.push_interleaved(&sine, |frame, _, _, _| {
            out_samples.extend_from_slice(frame);
        });
        // Skip first 64 samples of filter startup transient
        let steady = &out_samples[64..];
        let rms = (steady.iter().map(|s| (*s as f64) * (*s as f64)).sum::<f64>()
            / steady.len().max(1) as f64)
            .sqrt();
        assert!(
            rms < 0.08,
            "10 kHz sine should be heavily attenuated after 48k->16k anti-alias FIR, got rms={:.4}",
            rms
        );
    }
}
