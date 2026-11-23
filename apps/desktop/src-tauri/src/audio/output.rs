use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// 桌面端音频输出设备（支持识别 VB-Cable / VoiceMeeter 等虚拟声卡，用于会议同传）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputAudioDevice {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub is_virtual: bool,
}

fn is_virtual_device_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.contains("cable")
        || lower.contains("vb-audio")
        || lower.contains("voicemeeter")
        || lower.contains("virtual")
        || lower.contains("blackhole")
        || lower.contains("soundflower")
}

/// 枚举本机所有音频输出设备（包含物理耳机/扬声器与虚拟声卡）
pub fn list_output_devices() -> Vec<OutputAudioDevice> {
    let host = cpal::default_host();
    let default_name = host
        .default_output_device()
        .and_then(|d| d.name().ok())
        .unwrap_or_default();

    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();

    if let Ok(devices) = host.output_devices() {
        for dev in devices {
            if let Ok(name) = dev.name() {
                if !seen.insert(name.clone()) {
                    continue;
                }
                let is_default = !default_name.is_empty() && name == default_name;
                let is_virtual = is_virtual_device_name(&name);
                out.push(OutputAudioDevice {
                    id: name.clone(),
                    name,
                    is_default,
                    is_virtual,
                });
            }
        }
    }

    out.sort_by(|a, b| {
        b.is_default
            .cmp(&a.is_default)
            .then_with(|| b.is_virtual.cmp(&a.is_virtual))
            .then_with(|| a.name.cmp(&b.name))
    });
    out
}

/// 枚举本机所有麦克风/音频输入设备（支持蓝牙耳机麦、USB 耳机麦、笔记本阵列麦等）
pub fn list_input_devices() -> Vec<OutputAudioDevice> {
    let host = cpal::default_host();
    let default_name = host
        .default_input_device()
        .and_then(|d| d.name().ok())
        .unwrap_or_default();

    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();

    if let Ok(devices) = host.input_devices() {
        for dev in devices {
            if let Ok(name) = dev.name() {
                if !seen.insert(name.clone()) {
                    continue;
                }
                let is_default = !default_name.is_empty() && name == default_name;
                let is_virtual = is_virtual_device_name(&name);
                out.push(OutputAudioDevice {
                    id: name.clone(),
                    name,
                    is_default,
                    is_virtual,
                });
            }
        }
    }

    out.sort_by(|a, b| {
        b.is_default
            .cmp(&a.is_default)
            .then_with(|| a.is_virtual.cmp(&b.is_virtual))
            .then_with(|| a.name.cmp(&b.name))
    });
    out
}

/// 解析 16-bit PCM / 32-bit Float WAV 为单声道 f32 采样与采样率
fn decode_wav_mono_f32(wav: &[u8]) -> Result<(Vec<f32>, u32), String> {
    if wav.len() < 44 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return Err("无效的 WAV 音频头".to_string());
    }
    let mut pos = 12usize;
    let mut audio_format = 1u16;
    let mut channels = 1u16;
    let mut sample_rate = 24_000u32;
    let mut bits_per_sample = 16u16;
    let mut data_slice: Option<&[u8]> = None;

    while pos + 8 <= wav.len() {
        let id = &wav[pos..pos + 4];
        let size = u32::from_le_bytes([
            wav[pos + 4],
            wav[pos + 5],
            wav[pos + 6],
            wav[pos + 7],
        ]) as usize;
        let body = pos + 8;
        let end = body.saturating_add(size).min(wav.len());
        if id == b"fmt " && body + 16 <= wav.len() {
            audio_format = u16::from_le_bytes([wav[body], wav[body + 1]]);
            channels = u16::from_le_bytes([wav[body + 2], wav[body + 3]]).max(1);
            sample_rate = u32::from_le_bytes([
                wav[body + 4],
                wav[body + 5],
                wav[body + 6],
                wav[body + 7],
            ])
            .max(8_000);
            bits_per_sample = u16::from_le_bytes([wav[body + 14], wav[body + 15]]);
        } else if id == b"data" {
            data_slice = Some(&wav[body..end]);
            break;
        }
        pos = body.saturating_add(size).saturating_add(size % 2);
    }

    let raw = data_slice.ok_or_else(|| "WAV 文件缺少 data 块".to_string())?;
    let ch = channels as usize;
    let mut mono = Vec::new();

    if audio_format == 1 && bits_per_sample == 16 {
        let frame_bytes = 2 * ch;
        let frames = raw.len() / frame_bytes;
        mono.reserve(frames);
        for f in 0..frames {
            let mut acc = 0.0f32;
            for c in 0..ch {
                let o = f * frame_bytes + c * 2;
                let s = i16::from_le_bytes([raw[o], raw[o + 1]]) as f32 / 32768.0;
                acc += s;
            }
            mono.push((acc / ch as f32).clamp(-1.0, 1.0));
        }
    } else if audio_format == 3 && bits_per_sample == 32 {
        let frame_bytes = 4 * ch;
        let frames = raw.len() / frame_bytes;
        mono.reserve(frames);
        for f in 0..frames {
            let mut acc = 0.0f32;
            for c in 0..ch {
                let o = f * frame_bytes + c * 4;
                let s = f32::from_le_bytes([raw[o], raw[o + 1], raw[o + 2], raw[o + 3]]);
                acc += if s.is_finite() { s } else { 0.0 };
            }
            mono.push((acc / ch as f32).clamp(-1.0, 1.0));
        }
    } else {
        return Err(format!(
            "不支持的 WAV 编码格式：format={} bits={}",
            audio_format, bits_per_sample
        ));
    }

    Ok((mono, sample_rate))
}

fn resample_linear_to_interleaved(
    mono: &[f32],
    src_rate: u32,
    dst_rate: u32,
    dst_channels: usize,
) -> Vec<f32> {
    if mono.is_empty() {
        return Vec::new();
    }
    let ratio = dst_rate as f64 / src_rate as f64;
    let dst_frames = ((mono.len() as f64) * ratio).ceil() as usize;
    let mut out = Vec::with_capacity(dst_frames * dst_channels);
    for i in 0..dst_frames {
        let src_pos = (i as f64) / ratio;
        let idx = src_pos.floor() as usize;
        let frac = (src_pos - idx as f64) as f32;
        let s0 = mono.get(idx).copied().unwrap_or(0.0);
        let s1 = mono.get(idx + 1).copied().unwrap_or(s0);
        let sample = (s0 + (s1 - s0) * frac).clamp(-1.0, 1.0);
        for _ in 0..dst_channels {
            out.push(sample);
        }
    }
    out
}

/// 将 WAV 字节定向播放到指定的输出设备（支持物理耳机/扬声器或 VB-Cable 等虚拟麦克风）
/// 若传入 `far_end`，则在播放期间按真实播放进度同步推送 16kHz 远端参考样本供麦克风 AEC 实时消除回声。
pub fn play_wav_to_device(
    wav_bytes: &[u8],
    device_name: &str,
    cancel: Arc<AtomicBool>,
    far_end: Option<Arc<crate::audio::aec::FarEndReference>>,
) -> Result<(), String> {
    let (mono, src_rate) = decode_wav_mono_f32(wav_bytes)?;
    if mono.is_empty() {
        return Ok(());
    }
    let mono_16k = if far_end.is_some() {
        resample_linear_to_interleaved(&mono, src_rate, 16_000, 1)
    } else {
        Vec::new()
    };

    let host = cpal::default_host();
    let trimmed = device_name.trim();
    let device = if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("default") {
        host.default_output_device()
            .ok_or_else(|| "未找到默认音频输出设备".to_string())?
    } else {
        let mut found = None;
        if let Ok(devices) = host.output_devices() {
            for d in devices {
                if let Ok(name) = d.name() {
                    if name == trimmed {
                        found = Some(d);
                        break;
                    }
                }
            }
        }
        found
            .or_else(|| host.default_output_device())
            .ok_or_else(|| format!("未找到指定音频输出设备：{}", trimmed))?
    };

    let config = device
        .default_output_config()
        .map_err(|e| format!("获取输出设备配置失败：{}", e))?;
    let sample_format = config.sample_format();
    let stream_cfg: cpal::StreamConfig = config.into();
    let dst_rate = stream_cfg.sample_rate.0;
    let dst_channels = stream_cfg.channels as usize;

    let interleaved = Arc::new(resample_linear_to_interleaved(
        &mono,
        src_rate,
        dst_rate,
        dst_channels,
    ));
    let cursor = Arc::new(AtomicUsize::new(0));
    let finished = Arc::new(AtomicBool::new(false));

    let err_fn = |err| {
        crate::logger::warn(format!("[tts:output] cpal 输出流异常：{}", err));
    };

    let stream = match sample_format {
        SampleFormat::F32 => {
            let buf = interleaved.clone();
            let pos = cursor.clone();
            let done = finished.clone();
            let stop = cancel.clone();
            device.build_output_stream(
                &stream_cfg,
                move |data: &mut [f32], _| {
                    if stop.load(Ordering::Relaxed) {
                        data.fill(0.0);
                        done.store(true, Ordering::Relaxed);
                        return;
                    }
                    let start = pos.load(Ordering::Relaxed);
                    let avail = buf.len().saturating_sub(start);
                    let n = avail.min(data.len());
                    if n > 0 {
                        data[..n].copy_from_slice(&buf[start..start + n]);
                        pos.store(start + n, Ordering::Relaxed);
                    }
                    if n < data.len() {
                        data[n..].fill(0.0);
                        done.store(true, Ordering::Relaxed);
                    }
                },
                err_fn,
                None,
            )
        }
        SampleFormat::I16 => {
            let buf = interleaved.clone();
            let pos = cursor.clone();
            let done = finished.clone();
            let stop = cancel.clone();
            device.build_output_stream(
                &stream_cfg,
                move |data: &mut [i16], _| {
                    if stop.load(Ordering::Relaxed) {
                        data.fill(0);
                        done.store(true, Ordering::Relaxed);
                        return;
                    }
                    let start = pos.load(Ordering::Relaxed);
                    let avail = buf.len().saturating_sub(start);
                    let n = avail.min(data.len());
                    for i in 0..n {
                        data[i] = (buf[start + i].clamp(-1.0, 1.0) * 32767.0) as i16;
                    }
                    if n > 0 {
                        pos.store(start + n, Ordering::Relaxed);
                    }
                    if n < data.len() {
                        data[n..].fill(0);
                        done.store(true, Ordering::Relaxed);
                    }
                },
                err_fn,
                None,
            )
        }
        SampleFormat::U16 => {
            let buf = interleaved.clone();
            let pos = cursor.clone();
            let done = finished.clone();
            let stop = cancel.clone();
            device.build_output_stream(
                &stream_cfg,
                move |data: &mut [u16], _| {
                    if stop.load(Ordering::Relaxed) {
                        data.fill(32768);
                        done.store(true, Ordering::Relaxed);
                        return;
                    }
                    let start = pos.load(Ordering::Relaxed);
                    let avail = buf.len().saturating_sub(start);
                    let n = avail.min(data.len());
                    for i in 0..n {
                        let s = (buf[start + i].clamp(-1.0, 1.0) * 0.5 + 0.5) * 65535.0;
                        data[i] = s as u16;
                    }
                    if n > 0 {
                        pos.store(start + n, Ordering::Relaxed);
                    }
                    if n < data.len() {
                        data[n..].fill(32768);
                        done.store(true, Ordering::Relaxed);
                    }
                },
                err_fn,
                None,
            )
        }
        other => {
            return Err(format!("不支持的输出采样格式：{:?}", other));
        }
    }
    .map_err(|e| format!("创建音频输出流失败：{}", e))?;

    stream
        .play()
        .map_err(|e| format!("启动音频输出流失败：{}", e))?;

    // 等待播完或被取消，同时按 25ms 步长把对应的 16kHz 远端样本同步喂给麦克风 AEC
    let max_wait_ms = ((mono.len() as u64 * 1000) / src_rate as u64) + 2500;
    let mut elapsed = 0u64;
    let mut far_sent = 0usize;
    let total_dst = interleaved.len().max(1);
    while !finished.load(Ordering::Relaxed) && !cancel.load(Ordering::Relaxed) && elapsed < max_wait_ms
    {
        if let Some(ref fe) = far_end {
            let played_dst = cursor.load(Ordering::Relaxed).min(total_dst);
            let target_16k = ((played_dst as f64 / total_dst as f64) * mono_16k.len() as f64)
                .round() as usize;
            let clamped = target_16k.min(mono_16k.len());
            if clamped > far_sent {
                fe.push_16k(&mono_16k[far_sent..clamped]);
                far_sent = clamped;
            }
        }
        std::thread::sleep(Duration::from_millis(25));
        elapsed += 25;
    }
    if let Some(ref fe) = far_end {
        if !cancel.load(Ordering::Relaxed) && far_sent < mono_16k.len() {
            fe.push_16k(&mono_16k[far_sent..]);
        }
    }
    if !cancel.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(120));
    }
    drop(stream);
    Ok(())
}
