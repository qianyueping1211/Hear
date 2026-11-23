use std::fs::File;
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// 流式完整录音写入器（PCM 16-bit WAV + 50ms 归一化波形峰值）
/// 录音期间定期回写 WAV 头长度，即使异常崩溃也不会损坏已录音频。
pub struct StreamingWavRecorder {
    path: PathBuf,
    file: File,
    sample_rate: u32,
    channels: u16,
    data_bytes: u32,
    samples_per_peak: usize,
    peak_acc: f32,
    peak_count: usize,
    pub peaks: Vec<f32>,
}

impl StreamingWavRecorder {
    pub fn create(path: impl AsRef<Path>, sample_rate: u32, channels: u16) -> std::io::Result<Self> {
        let path_buf = path.as_ref().to_path_buf();
        if let Some(parent) = path_buf.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = File::create(&path_buf)?;
        write_wav_header(&mut file, sample_rate, channels, 0)?;
        let samples_per_peak = ((sample_rate as usize) / 20).max(1) * (channels as usize);
        Ok(Self {
            path: path_buf,
            file,
            sample_rate,
            channels,
            data_bytes: 0,
            samples_per_peak,
            peak_acc: 0.0,
            peak_count: 0,
            peaks: Vec::new(),
        })
    }

    pub fn write_f32(&mut self, samples: &[f32]) -> std::io::Result<()> {
        let mut pcm = Vec::with_capacity(samples.len() * 2);
        for &s in samples {
            let clamped = s.clamp(-1.0, 1.0);
            let abs = clamped.abs();
            if abs > self.peak_acc {
                self.peak_acc = abs;
            }
            self.peak_count += 1;
            if self.peak_count >= self.samples_per_peak {
                self.peaks.push(self.peak_acc);
                self.peak_acc = 0.0;
                self.peak_count = 0;
            }
            let v = (clamped * 32767.0) as i16;
            pcm.extend_from_slice(&v.to_le_bytes());
        }
        self.file.write_all(&pcm)?;
        self.data_bytes = self.data_bytes.saturating_add(pcm.len() as u32);
        Ok(())
    }

    pub fn flush_header(&mut self) -> std::io::Result<()> {
        let pos = self.file.stream_position()?;
        self.file.seek(SeekFrom::Start(0))?;
        write_wav_header(&mut self.file, self.sample_rate, self.channels, self.data_bytes)?;
        self.file.seek(SeekFrom::Start(pos))?;
        self.file.flush()
    }

    pub fn snapshot(&mut self) -> (PathBuf, u64, Vec<f32>) {
        let _ = self.flush_header();
        let bytes_per_frame = (self.channels as u64) * 2;
        let frames = (self.data_bytes as u64) / bytes_per_frame.max(1);
        let duration_ms = (frames * 1000) / (self.sample_rate as u64).max(1);
        let mut peaks = self.peaks.clone();
        if self.peak_count > 0 {
            peaks.push(self.peak_acc);
        }
        (self.path.clone(), duration_ms, peaks)
    }

    pub fn duration_ms(&self) -> u64 {
        let bytes_per_frame = (self.channels as u64) * 2;
        let frames = (self.data_bytes as u64) / bytes_per_frame.max(1);
        (frames * 1000) / (self.sample_rate as u64).max(1)
    }

    pub fn finalize(mut self) -> std::io::Result<(PathBuf, u64, Vec<f32>)> {
        if self.peak_count > 0 {
            self.peaks.push(self.peak_acc);
        }
        self.flush_header()?;
        let bytes_per_frame = (self.channels as u64) * 2;
        let frames = (self.data_bytes as u64) / bytes_per_frame.max(1);
        let duration_ms = (frames * 1000) / (self.sample_rate as u64).max(1);
        Ok((self.path, duration_ms, self.peaks))
    }
}

/// 从已录制的 16 kHz 单/双声道 16-bit PCM WAV 文件中截取 [start_ms, end_ms] 音频片段并封装为单声道 WAV（供 Qwen3-TTS 声音克隆作参考音频）
/// 若为双路混合立体声（左=系统声 channel 0，右=麦克风 channel 1），优先提取 preferred_channel 对应轨的纯净人声。
pub fn slice_wav_range_16k_mono(
    path: &Path,
    start_ms: u64,
    end_ms: u64,
    preferred_channel: Option<usize>,
) -> Option<Vec<u8>> {
    if end_ms <= start_ms {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    let (samples, _, _) =
        decode_wav_to_16k_mono_with_channel(&bytes, preferred_channel).ok()?;
    let start_idx = ((start_ms * 16_000) / 1000) as usize;
    let mut end_idx = ((end_ms * 16_000) / 1000) as usize;
    if start_idx >= samples.len() {
        return None;
    }
    end_idx = end_idx.min(samples.len());
    if end_idx <= start_idx {
        return None;
    }
    // 钳制在 0.2s ~ 10.0s 之间，确保短句原音播放与参考音频切片均能正常截取
    let min_samples = 3_200; // 0.2s
    let max_samples = 16_000 * 10; // 10.0s
    let slice = &samples[start_idx..end_idx];
    if slice.len() < min_samples {
        return None;
    }
    let capped = &slice[..slice.len().min(max_samples)];
    Some(encode_wav_16k_mono(capped))
}

/// 将 16 kHz 单声道 f32 采样编码为标准 16-bit PCM WAV 字节数组（供 /v1/asr 上传）
pub fn encode_wav_16k_mono(samples: &[f32]) -> Vec<u8> {
    let data_bytes = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + samples.len() * 2);
    let _ = write_wav_header(&mut out, 16_000, 1, data_bytes);
    for &s in samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

/// 解析标准 PCM/Float WAV 字节并重采样为 16 kHz 单声道 f32，同时生成 50ms 波形峰值与总时长
pub fn decode_wav_to_16k_mono(bytes: &[u8]) -> Result<(Vec<f32>, u64, Vec<f32>), String> {
    decode_wav_to_16k_mono_with_channel(bytes, None)
}

pub fn decode_wav_to_16k_mono_with_channel(
    bytes: &[u8],
    preferred_channel: Option<usize>,
) -> Result<(Vec<f32>, u64, Vec<f32>), String> {
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("文件不是有效的 WAV 音频格式".to_string());
    }

    let mut pos = 12usize;
    let mut audio_format: u16 = 0;
    let mut channels: u16 = 0;
    let mut sample_rate: u32 = 0;
    let mut bits_per_sample: u16 = 0;
    let mut data_slice: Option<&[u8]> = None;

    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes([
            bytes[pos + 4],
            bytes[pos + 5],
            bytes[pos + 6],
            bytes[pos + 7],
        ]) as usize;
        pos += 8;
        let end = pos.saturating_add(size).min(bytes.len());
        if id == b"fmt " && end - pos >= 16 {
            audio_format = u16::from_le_bytes([bytes[pos], bytes[pos + 1]]);
            channels = u16::from_le_bytes([bytes[pos + 2], bytes[pos + 3]]);
            sample_rate = u32::from_le_bytes([
                bytes[pos + 4],
                bytes[pos + 5],
                bytes[pos + 6],
                bytes[pos + 7],
            ]);
            bits_per_sample = u16::from_le_bytes([bytes[pos + 14], bytes[pos + 15]]);
        } else if id == b"data" {
            data_slice = Some(&bytes[pos..end]);
            break;
        }
        // WAV 块按 2 字节对齐
        pos = end + (size % 2);
    }

    let raw = data_slice.ok_or_else(|| "WAV 文件缺少 data 音频数据块".to_string())?;
    if channels == 0 || sample_rate == 0 {
        return Err("WAV 音频参数无效（声道数或采样率为 0）".to_string());
    }

    let bytes_per_sample = (bits_per_sample / 8) as usize;
    if bytes_per_sample == 0 {
        return Err("WAV 位深参数无效".to_string());
    }
    let ch = channels as usize;
    let frame_stride = bytes_per_sample * ch;
    let frame_count = raw.len() / frame_stride.max(1);
    if frame_count == 0 {
        return Err("WAV 文件不包含有效音频采样".to_string());
    }

    let mut mono = Vec::with_capacity(frame_count);
    let pick_ch = preferred_channel.filter(|&c| c < ch);
    for f in 0..frame_count {
        if let Some(c) = pick_ch {
            let off = f * frame_stride + c * bytes_per_sample;
            let sample = match (audio_format, bits_per_sample) {
                (1, 8) => (raw[off] as f32 - 128.0) / 128.0,
                (1, 16) => i16::from_le_bytes([raw[off], raw[off + 1]]) as f32 / 32768.0,
                (1, 24) => {
                    let b0 = raw[off] as i32;
                    let b1 = (raw[off + 1] as i32) << 8;
                    let b2 = ((raw[off + 2] as i8) as i32) << 16;
                    (b0 | b1 | b2) as f32 / 8_388_608.0
                }
                (1, 32) => {
                    let v =
                        i32::from_le_bytes([raw[off], raw[off + 1], raw[off + 2], raw[off + 3]]);
                    (v as f64 / 2_147_483_648.0) as f32
                }
                (3, 32) => {
                    f32::from_le_bytes([raw[off], raw[off + 1], raw[off + 2], raw[off + 3]])
                }
                _ => {
                    return Err(format!(
                        "不支持的 WAV 编码（format={}，{} bit）",
                        audio_format, bits_per_sample
                    ));
                }
            };
            mono.push(sample.clamp(-1.0, 1.0));
            continue;
        }

        let mut sum = 0.0f32;
        for c in 0..ch {
            let off = f * frame_stride + c * bytes_per_sample;
            let sample = match (audio_format, bits_per_sample) {
                (1, 8) => (raw[off] as f32 - 128.0) / 128.0,
                (1, 16) => i16::from_le_bytes([raw[off], raw[off + 1]]) as f32 / 32768.0,
                (1, 24) => {
                    let b0 = raw[off] as i32;
                    let b1 = (raw[off + 1] as i32) << 8;
                    let b2 = ((raw[off + 2] as i8) as i32) << 16;
                    (b0 | b1 | b2) as f32 / 8_388_608.0
                }
                (1, 32) => {
                    let v = i32::from_le_bytes([raw[off], raw[off + 1], raw[off + 2], raw[off + 3]]);
                    (v as f64 / 2_147_483_648.0) as f32
                }
                (3, 32) => f32::from_le_bytes([raw[off], raw[off + 1], raw[off + 2], raw[off + 3]]),
                _ => {
                    return Err(format!(
                        "不支持的 WAV 编码（format={}，{} bit）",
                        audio_format, bits_per_sample
                    ));
                }
            };
            sum += sample.clamp(-1.0, 1.0);
        }
        mono.push(sum / ch as f32);
    }

    // 线性重采样到 16 kHz
    let samples_16k = if sample_rate == 16_000 {
        mono
    } else {
        let out_len = ((mono.len() as u64 * 16_000) / sample_rate as u64).max(1) as usize;
        let step = sample_rate as f64 / 16_000.0;
        let mut out = Vec::with_capacity(out_len);
        let max_idx = mono.len() - 1;
        for i in 0..out_len {
            let p = i as f64 * step;
            let idx = (p.floor() as usize).min(max_idx);
            let next = (idx + 1).min(max_idx);
            let frac = (p - idx as f64) as f32;
            out.push(mono[idx] + (mono[next] - mono[idx]) * frac);
        }
        out
    };

    let duration_ms = (samples_16k.len() as u64 * 1000) / 16_000;
    let peaks: Vec<f32> = samples_16k
        .chunks(800) // 50ms @ 16kHz
        .map(|chunk| chunk.iter().fold(0.0f32, |acc, &s| acc.max(s.abs())))
        .collect();

    Ok((samples_16k, duration_ms, peaks))
}

fn write_wav_header<W: Write>(
    w: &mut W,
    sample_rate: u32,
    channels: u16,
    data_bytes: u32,
) -> std::io::Result<()> {
    let byte_rate = sample_rate * (channels as u32) * 2;
    let block_align = channels * 2;
    let riff_size = 36u32.saturating_add(data_bytes);

    w.write_all(b"RIFF")?;
    w.write_all(&riff_size.to_le_bytes())?;
    w.write_all(b"WAVE")?;
    w.write_all(b"fmt ")?;
    w.write_all(&16u32.to_le_bytes())?; // PCM fmt chunk size
    w.write_all(&1u16.to_le_bytes())?; // PCM format
    w.write_all(&channels.to_le_bytes())?;
    w.write_all(&sample_rate.to_le_bytes())?;
    w.write_all(&byte_rate.to_le_bytes())?;
    w.write_all(&block_align.to_le_bytes())?;
    w.write_all(&16u16.to_le_bytes())?; // bits per sample
    w.write_all(b"data")?;
    w.write_all(&data_bytes.to_le_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_valid_wav_and_peaks() {
        let tmp = std::env::temp_dir().join(format!("hear-rec-{}.wav", uuid::Uuid::new_v4()));
        let mut rec = StreamingWavRecorder::create(&tmp, 16_000, 1).unwrap();
        let half_sec = vec![0.5f32; 8_000];
        rec.write_f32(&half_sec).unwrap();
        let (path, duration_ms, peaks) = rec.finalize().unwrap();
        assert_eq!(duration_ms, 500);
        assert_eq!(peaks.len(), 10);
        let meta = std::fs::metadata(&path).unwrap();
        assert_eq!(meta.len(), 44 + 8_000 * 2);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn decodes_wav_roundtrip_and_computes_peaks() {
        let orig: Vec<f32> = (0..16_000).map(|i| ((i as f32) * 0.02).sin() * 0.4).collect();
        let wav = encode_wav_16k_mono(&orig);
        let (decoded, duration_ms, peaks) = decode_wav_to_16k_mono(&wav).unwrap();
        assert_eq!(decoded.len(), 16_000);
        assert_eq!(duration_ms, 1000);
        assert_eq!(peaks.len(), 20);
        assert!(peaks.iter().all(|&p| p > 0.3 && p <= 0.45));
    }
}
