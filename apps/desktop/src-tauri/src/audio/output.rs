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

    let is_pcm16 = (audio_format == 1 || audio_format == 0xFFFE) && bits_per_sample == 16;
    let is_f32 = (audio_format == 3 || audio_format == 0xFFFE) && bits_per_sample == 32;

    if is_pcm16 {
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
    } else if is_f32 {
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

/// 裁掉克隆音频开头与结尾的空白/轻气口并做人声响度归一化（对标 iOS CloneAudio.trimmingEdgeSilence + playbackGain）
/// 若整段音频近似静音，返回 None 以便上层立即降级系统语音，避免显示「播放中」却无声。
fn trim_edge_silence_and_normalize(samples: &[f32], sample_rate: u32) -> Option<Vec<f32>> {
    if samples.is_empty() || sample_rate < 8_000 {
        return None;
    }
    let window = (sample_rate as usize / 100).max(1); // 10ms 窗口
    let mut levels = Vec::with_capacity((samples.len() + window - 1) / window);
    let mut max_level = 0.0f32;
    let mut peak = 0.0f32;
    for chunk in samples.chunks(window) {
        let n = chunk.len() as f64;
        let mut sum = 0.0f64;
        let mut power = 0.0f64;
        for &s in chunk {
            let v = if s.is_finite() { s.clamp(-1.0, 1.0) } else { 0.0 };
            peak = peak.max(v.abs());
            let d = v as f64;
            sum += d;
            power += d * d;
        }
        let mean = sum / n;
        let rms = (power / n - mean * mean).max(0.0).sqrt() as f32;
        max_level = max_level.max(rms);
        levels.push(rms);
    }
    if max_level < 0.001 || peak < 0.002 {
        return None;
    }
    let threshold = (max_level * 0.05).max(0.001);
    let mut previous: Option<usize> = None;
    let mut first: Option<usize> = None;
    let mut last = 0usize;
    for (idx, &lv) in levels.iter().enumerate() {
        if lv >= threshold {
            if let Some(prev) = previous {
                if idx.saturating_sub(prev) <= 2 {
                    if first.is_none() {
                        first = Some(prev);
                    }
                    last = idx;
                }
            }
            previous = Some(idx);
        }
    }
    let first_idx = first?;
    let start = first_idx.saturating_sub(5) * window;
    let end = ((last + 9) * window).min(samples.len());
    if end <= start {
        return None;
    }
    let mut clipped: Vec<f32> = samples[start..end].to_vec();
    // 响度归一化：把偏小的克隆声音温和抬升至 ~0.10 RMS（峰值不超过 0.88）
    let active_energy: f64 = clipped.iter().map(|&s| (s as f64) * (s as f64)).sum();
    let rms = (active_energy / clipped.len().max(1) as f64).sqrt() as f32;
    let gain = if rms > 1e-4 {
        (0.10 / rms).clamp(1.0, 6.0).min(0.88 / peak.max(1e-4))
    } else {
        1.0
    };
    if (gain - 1.0).abs() > 0.02 {
        for s in &mut clipped {
            *s = (*s * gain).clamp(-1.0, 1.0);
        }
    }
    // 首尾 5ms 淡入淡出防爆音
    let fade = (window / 2).min(clipped.len() / 2);
    for i in 0..fade {
        let g = i as f32 / fade.max(1) as f32;
        if start > 0 {
            clipped[i] *= g;
        }
        if end < samples.len() {
            let tail_i = clipped.len() - 1 - i;
            clipped[tail_i] *= g;
        }
    }
    Some(clipped)
}

/// 裁切 16kHz 单声道参考声纹 WAV 的前后空白音并温和归一化（对标 iOS FixedVoiceSampleStore.saveRecordedWav），
/// 防止按下录音到开口前/结束后的静音混入 Qwen3-TTS 参考声纹导致克隆开头无声。
pub fn trim_wav_edge_silence_16k_mono(wav_bytes: &[u8]) -> Result<Vec<u8>, String> {
    let (raw_mono, src_rate) = decode_wav_mono_f32(wav_bytes)?;
    let trimmed = trim_edge_silence_and_normalize(&raw_mono, src_rate)
        .ok_or_else(|| "未检测到有效人声，请在安静环境下重新清晰朗读 3~10 秒".to_string())?;
    let mono_16k = if src_rate == 16_000 {
        trimmed
    } else {
        resample_linear_to_interleaved(&trimmed, src_rate, 16_000, 1)
    };
    let secs = mono_16k.len() as f32 / 16_000.0;
    if secs < 2.2 {
        return Err("有效人声时长不足，请在安静环境下清晰朗读 3~10 秒".to_string());
    }
    let clipped = if mono_16k.len() > 160_000 {
        &mono_16k[..160_000]
    } else {
        &mono_16k[..]
    };
    let data_bytes = (clipped.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data_bytes as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36u32 + data_bytes).to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&16_000u32.to_le_bytes());
    out.extend_from_slice(&32_000u32.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for &s in clipped {
        let clamped = s.clamp(-1.0, 1.0);
        let i16_val = if clamped < 0.0 {
            (clamped * 32768.0) as i16
        } else {
            (clamped * 32767.0) as i16
        };
        out.extend_from_slice(&i16_val.to_le_bytes());
    }
    Ok(out)
}

/// 将 WAV 字节定向播放到指定的输出设备（支持物理耳机/扬声器或 VB-Cable 等虚拟麦克风）
/// 若传入 `far_end`，则在播放期间按真实播放进度同步推送 16kHz 远端参考样本供麦克风 AEC 实时消除回声。
pub fn play_wav_to_device(
    wav_bytes: &[u8],
    device_name: &str,
    cancel: Arc<AtomicBool>,
    far_end: Option<Arc<crate::audio::aec::FarEndReference>>,
) -> Result<(), String> {
    let (raw_mono, src_rate) = decode_wav_mono_f32(wav_bytes)?;
    let mono = trim_edge_silence_and_normalize(&raw_mono, src_rate)
        .ok_or_else(|| "克隆音频为空或近似静音，将自动降级系统朗读".to_string())?;
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
        let def = host.default_output_device();
        // 若系统默认播放设备被误设为虚拟声卡（如 VB-Cable），播放给本地听的译文时自动优先切回物理耳机/扬声器，避免无声
        let def_is_virtual = def
            .as_ref()
            .and_then(|d| d.name().ok())
            .map(|n| is_virtual_device_name(&n))
            .unwrap_or(false);
        if def_is_virtual {
            host.output_devices()
                .ok()
                .and_then(|mut devs| {
                    devs.find(|d| {
                        d.name()
                            .map(|n| !is_virtual_device_name(&n))
                            .unwrap_or(false)
                    })
                })
                .or(def)
                .ok_or_else(|| "未找到默认音频输出设备".to_string())?
        } else {
            def.ok_or_else(|| "未找到默认音频输出设备".to_string())?
        }
    } else {
        let needle = trimmed.to_ascii_lowercase();
        let want_vb = needle.contains("vb-audio virtual cable")
            || (needle.contains("cable input") && !needle.contains("hi-fi"));
        let want_hifi = needle.contains("hi-fi");
        let mut found = None;
        let mut family_match = None;
        if let Ok(devices) = host.output_devices() {
            for d in devices {
                if let Ok(name) = d.name() {
                    if name == trimmed {
                        found = Some(d);
                        break;
                    }
                    if family_match.is_none() {
                        let lower = name.to_ascii_lowercase();
                        if !lower.contains("16ch") {
                            if want_vb && lower.contains("vb-audio virtual cable") {
                                family_match = Some(d);
                            } else if want_hifi
                                && (lower.contains("vb-audio hi-fi cable")
                                    || lower.contains("hi-fi cable"))
                            {
                                family_match = Some(d);
                            }
                        }
                    }
                }
            }
        }
        found
            .or(family_match)
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

/// Windows 会议原声自动压低守卫（Audio Ducking）：
/// 朗读译文期间，通过 Windows CoreAudio (IAudioSessionManager2 + ISimpleAudioVolume)
/// 将本进程与指定排除进程之外的其他应用（如腾讯会议 / Teams / 浏览器）音量按比例临时压低，
/// 离开作用域（Drop）时自动恢复原音量。非 Windows 平台为空实现。
#[cfg(target_os = "windows")]
pub struct AudioDuckGuard {
    saved: Vec<(windows::Win32::Media::Audio::ISimpleAudioVolume, f32)>,
    com_inited: bool,
}

#[cfg(target_os = "windows")]
impl AudioDuckGuard {
    pub fn enter(ratio: f32, exclude_pids: &[u32]) -> Self {
        use windows::core::Interface;
        use windows::Win32::Media::Audio::{
            eCommunications, eConsole, eRender, IAudioSessionControl2, IAudioSessionManager2,
            IMMDeviceEnumerator, ISimpleAudioVolume, MMDeviceEnumerator,
        };
        use windows::Win32::System::Com::{
            CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED,
        };

        let clamped = ratio.clamp(0.0, 1.0);
        if clamped >= 0.98 {
            return Self {
                saved: Vec::new(),
                com_inited: false,
            };
        }
        unsafe {
            let hr = CoInitializeEx(None, COINIT_MULTITHREADED);
            let com_inited = hr.is_ok();
            let mut saved = Vec::new();
            let mut seen_device_ids: Vec<String> = Vec::new();
            if let Ok(enumerator) =
                CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL)
            {
                // 同时覆盖默认多媒体设备 (eConsole) 与默认通信设备 (eCommunications，蓝牙/USB 会议耳机常走此路)
                for role in [eConsole, eCommunications] {
                    let Ok(device) = enumerator.GetDefaultAudioEndpoint(eRender, role) else {
                        continue;
                    };
                    if let Ok(id_pwstr) = device.GetId() {
                        let id_str = id_pwstr.to_string().unwrap_or_default();
                        CoTaskMemFree(Some(id_pwstr.0 as *const std::ffi::c_void));
                        if !id_str.is_empty() {
                            if seen_device_ids.contains(&id_str) {
                                continue;
                            }
                            seen_device_ids.push(id_str);
                        }
                    }
                    if let Ok(mgr) = device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None) {
                        if let Ok(session_enum) = mgr.GetSessionEnumerator() {
                            if let Ok(count) = session_enum.GetCount() {
                                for i in 0..count {
                                    let Ok(ctrl) = session_enum.GetSession(i) else {
                                        continue;
                                    };
                                    let Ok(ctrl2) = ctrl.cast::<IAudioSessionControl2>() else {
                                        continue;
                                    };
                                    let Ok(pid) = ctrl2.GetProcessId() else {
                                        continue;
                                    };
                                    if pid == 0 || exclude_pids.contains(&pid) {
                                        continue;
                                    }
                                    let Ok(vol) = ctrl.cast::<ISimpleAudioVolume>() else {
                                        continue;
                                    };
                                    let Ok(orig) = vol.GetMasterVolume() else {
                                        continue;
                                    };
                                    let target = (orig * clamped).clamp(0.0, 1.0);
                                    if (orig - target).abs() > 0.01
                                        && vol.SetMasterVolume(target, std::ptr::null()).is_ok()
                                    {
                                        saved.push((vol, orig));
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Self { saved, com_inited }
        }
    }
}

#[cfg(target_os = "windows")]
impl Drop for AudioDuckGuard {
    fn drop(&mut self) {
        unsafe {
            for (vol, orig) in self.saved.drain(..) {
                let _ = vol.SetMasterVolume(orig, std::ptr::null());
            }
            if self.com_inited {
                windows::Win32::System::Com::CoUninitialize();
            }
        }
    }
}

#[cfg(not(target_os = "windows"))]
pub struct AudioDuckGuard;

#[cfg(not(target_os = "windows"))]
impl AudioDuckGuard {
    pub fn enter(_ratio: f32, _exclude_pids: &[u32]) -> Self {
        Self
    }
}

/// 通过 Windows 10/11 原生 WinRT OneCore 语音库合成 PCM WAV（支持中文男声 Microsoft Kangkang、女声 Huihui/Yaoyao 及更多系统男女声）
/// 若系统 OneCore 语音库未安装目标语种，返回 None 以便上层回退经典 SAPI。
#[cfg(target_os = "windows")]
pub fn synthesize_winrt_onecore_wav(text: &str, lang: &str, gender: &str) -> Option<Vec<u8>> {
    use windows::core::HSTRING;
    use windows::Media::SpeechSynthesis::{SpeechSynthesizer, VoiceGender, VoiceInformation};
    use windows::Storage::Streams::DataReader;

    let synth = SpeechSynthesizer::new().ok()?;
    let all = SpeechSynthesizer::AllVoices().ok()?;
    let count = all.Size().ok()?;
    let lang_lower = lang.trim().to_ascii_lowercase();
    let lang_base = lang_lower.split('-').next().unwrap_or("").to_string();

    let mut exact_pool: Vec<VoiceInformation> = Vec::new();
    let mut base_pool: Vec<VoiceInformation> = Vec::new();
    for i in 0..count {
        let Ok(v) = all.GetAt(i) else {
            continue;
        };
        let Ok(vlang) = v.Language() else {
            continue;
        };
        let vl = vlang.to_string_lossy().to_ascii_lowercase();
        if !lang_lower.is_empty() && vl.starts_with(&lang_lower) {
            exact_pool.push(v);
        } else if !lang_base.is_empty() && vl.starts_with(&lang_base) {
            base_pool.push(v);
        }
    }
    let pool = if !exact_pool.is_empty() {
        exact_pool
    } else if !base_pool.is_empty() {
        base_pool
    } else {
        // 目标语种在 OneCore 语音库中未安装，返回 None 回退到经典 SAPI（避免用中文声音硬读英文）
        return None;
    };

    let want_gender = match gender.to_ascii_lowercase().as_str() {
        "male" => Some(VoiceGender::Male),
        "female" => Some(VoiceGender::Female),
        _ => None,
    };
    let chosen = if let Some(wg) = want_gender {
        pool.iter()
            .find(|v| v.Gender().ok() == Some(wg))
            .or_else(|| pool.first())
    } else {
        pool.first()
    }?;
    synth.SetVoice(chosen).ok()?;

    let htext = HSTRING::from(text);
    let stream = synth.SynthesizeTextToStreamAsync(&htext).ok()?.get().ok()?;
    let size = stream.Size().ok()? as u32;
    if size <= 44 {
        return None;
    }
    let input = stream.GetInputStreamAt(0).ok()?;
    let reader = DataReader::CreateDataReader(&input).ok()?;
    let _ = reader.LoadAsync(size).ok()?.get().ok()?;
    let mut buf = vec![0u8; size as usize];
    reader.ReadBytes(&mut buf).ok()?;
    if buf.len() > 44 && &buf[0..4] == b"RIFF" {
        Some(buf)
    } else {
        None
    }
}

#[cfg(not(target_os = "windows"))]
pub fn synthesize_winrt_onecore_wav(_text: &str, _lang: &str, _gender: &str) -> Option<Vec<u8>> {
    None
}
