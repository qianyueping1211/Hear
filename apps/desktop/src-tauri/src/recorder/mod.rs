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
}
