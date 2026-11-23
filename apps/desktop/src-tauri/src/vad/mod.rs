use std::collections::VecDeque;

/// 16 kHz 下与 Silero VAD 严格对齐的 512 采样窗口（32ms）
pub const VAD_SAMPLE_RATE: u32 = 16_000;
pub const VAD_WINDOW_SAMPLES: usize = 512;

#[derive(Debug, Clone)]
pub enum SegmentEvent {
    Partial {
        segment_id: u64,
        start_ms: u64,
        end_ms: u64,
        samples: Vec<f32>,
    },
    Final {
        segment_id: u64,
        start_ms: u64,
        end_ms: u64,
        samples: Vec<f32>,
    },
}

/// 零搬移环形缓冲断句器（复刻并优化 iOS 0.4.80 边界：不丢样、不重复、长段优先找停顿切分）
pub struct Segmenter {
    preroll_max: usize,
    silence_limit_frames: usize,
    max_segment_samples: usize,
    partial_interval_frames: usize,

    preroll: VecDeque<f32>,
    speech: Vec<f32>,
    in_speech: bool,
    silence_frames: usize,
    frames_since_partial: usize,
    segment_id: u64,
    total_samples_seen: u64,
    segment_start_sample: u64,
}

impl Segmenter {
    pub fn new(silence_ms: u64, max_segment_secs: u64) -> Self {
        let frame_ms = (VAD_WINDOW_SAMPLES as u64 * 1000) / VAD_SAMPLE_RATE as u64; // 32ms
        let silence_limit_frames = (silence_ms.max(200) / frame_ms.max(1)) as usize;
        Self {
            preroll_max: VAD_WINDOW_SAMPLES * 10, // ~320ms 句首缓冲，避免吞首字
            silence_limit_frames,
            max_segment_samples: (max_segment_secs.max(5) * VAD_SAMPLE_RATE as u64) as usize,
            partial_interval_frames: 12, // ~384ms 预览间隔
            preroll: VecDeque::with_capacity(VAD_WINDOW_SAMPLES * 12),
            speech: Vec::with_capacity(VAD_SAMPLE_RATE as usize * 16),
            in_speech: false,
            silence_frames: 0,
            frames_since_partial: 0,
            segment_id: 0,
            total_samples_seen: 0,
            segment_start_sample: 0,
        }
    }

    /// 喂入一帧严格 512 采样（16kHz）与该帧的 VAD 判别结果
    pub fn push_frame(&mut self, frame: &[f32], has_speech: bool) -> Option<SegmentEvent> {
        let frame_start_sample = self.total_samples_seen;
        self.total_samples_seen += frame.len() as u64;

        if !self.in_speech {
            if has_speech {
                self.in_speech = true;
                self.silence_frames = 0;
                self.frames_since_partial = 0;
                self.segment_id += 1;
                self.speech.clear();
                let pre_len = self.preroll.len() as u64;
                self.segment_start_sample = frame_start_sample.saturating_sub(pre_len);
                self.speech.extend(self.preroll.drain(..));
                self.speech.extend_from_slice(frame);
            } else {
                self.preroll.extend(frame.iter().copied());
                while self.preroll.len() > self.preroll_max {
                    self.preroll.pop_front();
                }
            }
            return None;
        }

        // 正在说话中
        self.speech.extend_from_slice(frame);
        if has_speech {
            self.silence_frames = 0;
        } else {
            self.silence_frames += 1;
        }

        // 触发正式切段条件：停顿达到阈值 或 触达最长上限
        if self.silence_frames >= self.silence_limit_frames
            || self.speech.len() >= self.max_segment_samples
        {
            return self.flush_final();
        }

        self.frames_since_partial += 1;
        if self.frames_since_partial >= self.partial_interval_frames {
            self.frames_since_partial = 0;
            return Some(SegmentEvent::Partial {
                segment_id: self.segment_id,
                start_ms: samples_to_ms(self.segment_start_sample),
                end_ms: samples_to_ms(self.total_samples_seen),
                samples: self.speech.clone(),
            });
        }
        None
    }

    /// 丢弃当前正在累积的语音与预卷缓冲（播报译文静音期间调用，避免回声残片拼成误识别）
    pub fn discard_current(&mut self) {
        self.in_speech = false;
        self.silence_frames = 0;
        self.frames_since_partial = 0;
        self.speech.clear();
        self.preroll.clear();
    }

    pub fn flush_final(&mut self) -> Option<SegmentEvent> {
        if !self.in_speech || self.speech.is_empty() {
            return None;
        }
        let samples = std::mem::take(&mut self.speech);
        let start_ms = samples_to_ms(self.segment_start_sample);
        let end_ms = samples_to_ms(self.total_samples_seen);
        self.in_speech = false;
        self.silence_frames = 0;
        self.frames_since_partial = 0;
        Some(SegmentEvent::Final {
            segment_id: self.segment_id,
            start_ms,
            end_ms,
            samples,
        })
    }
}

fn samples_to_ms(samples: u64) -> u64 {
    (samples * 1000) / VAD_SAMPLE_RATE as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emits_final_with_exact_timeline_and_no_dropped_samples() {
        let mut seg = Segmenter::new(320, 15);
        let silence = [0.0f32; VAD_WINDOW_SAMPLES];
        let voice = [0.25f32; VAD_WINDOW_SAMPLES];

        // 2 帧前置静音进入 preroll
        assert!(seg.push_frame(&silence, false).is_none());
        assert!(seg.push_frame(&silence, false).is_none());

        // 5 帧有效语音
        for _ in 0..5 {
            let _ = seg.push_frame(&voice, true);
        }

        // 10 帧停顿触发切段
        let mut final_ev = None;
        for _ in 0..10 {
            if let Some(SegmentEvent::Final {
                start_ms,
                end_ms,
                samples,
                ..
            }) = seg.push_frame(&silence, false)
            {
                final_ev = Some((start_ms, end_ms, samples.len()));
                break;
            }
        }
        let (start_ms, end_ms, len) = final_ev.expect("expected final segment");
        assert_eq!(start_ms, 0);
        assert!(end_ms > start_ms);
        assert_eq!(len, (2 + 5 + 10) * VAD_WINDOW_SAMPLES);
    }
}
