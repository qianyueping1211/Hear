use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// 扬声器远端参考信号缓冲（16 kHz 单声道），由本地 TTS 播放线程实时写入，
/// 麦克风采集线程同步读取并送入 NLMS 自适应回声消除器。
pub struct FarEndReference {
    inner: Mutex<FarEndInner>,
}

struct FarEndInner {
    queue: VecDeque<f32>,
    active_until: Option<Instant>,
}

impl FarEndReference {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(FarEndInner {
                queue: VecDeque::with_capacity(16_000 * 2),
                active_until: None,
            }),
        }
    }

    /// 推送一段 16 kHz 单声道远端播放样本，并延长活跃窗口（含 350ms 房间残响尾音）
    pub fn push_16k(&self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        if let Ok(mut guard) = self.inner.lock() {
            // 最多保留 1.5 秒远端缓冲，防止异常堆积导致延迟漂移
            let max_len = 24_000usize;
            if guard.queue.len() + samples.len() > max_len {
                let drop_n = (guard.queue.len() + samples.len()).saturating_sub(max_len);
                for _ in 0..drop_n.min(guard.queue.len()) {
                    guard.queue.pop_front();
                }
            }
            guard.queue.extend(samples.iter().copied());
            guard.active_until = Some(Instant::now() + Duration::from_millis(400));
        }
    }

    pub fn is_active(&self) -> bool {
        if let Ok(guard) = self.inner.lock() {
            if !guard.queue.is_empty() {
                return true;
            }
            if let Some(until) = guard.active_until {
                return Instant::now() < until;
            }
        }
        false
    }

    /// 取出与当前麦克风帧等长的 16 kHz 远端参考样本（不足补零）
    pub fn pop_frame(&self, len: usize) -> Vec<f32> {
        let mut out = vec![0.0f32; len];
        if let Ok(mut guard) = self.inner.lock() {
            let n = len.min(guard.queue.len());
            for i in 0..n {
                if let Some(v) = guard.queue.pop_front() {
                    out[i] = v;
                }
            }
        }
        out
    }

    pub fn clear(&self) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.queue.clear();
            guard.active_until = None;
        }
    }
}

/// 实时声学回声消除器（2048-tap 归一化 LMS 自适应滤波 + 双讲检测 + 残余回声抑制）
///
/// 覆盖 128ms 声学与缓冲路径（16 kHz），在电脑外放播报译文期间实时抵消扬声器回声，
/// 当用户同时开口说话（双讲 Double-Talk）时冻结权值更新并保留人声，实现真正全双工。
pub struct AcousticEchoCanceller {
    taps: usize,
    weights: Vec<f32>,
    ref_history: Vec<f32>,
    head: usize,
    mu: f32,
}

impl AcousticEchoCanceller {
    pub fn new() -> Self {
        let taps = 2048; // 128ms @ 16kHz
        Self {
            taps,
            weights: vec![0.0f32; taps],
            ref_history: vec![0.0f32; taps],
            head: 0,
            mu: 0.35,
        }
    }

    pub fn reset(&mut self) {
        self.weights.fill(0.0);
        self.ref_history.fill(0.0);
        self.head = 0;
    }

    /// 对一帧 16 kHz 麦克风样本执行回声消除（原地修改 `mic_frame`）
    pub fn process_frame(&mut self, mic_frame: &mut [f32], far_frame: &[f32]) {
        let n = mic_frame.len().min(far_frame.len());
        if n == 0 {
            return;
        }

        // 计算本帧远端参考能量与近端麦克风能量，用于双讲检测（Double-Talk Detection）
        let far_energy: f32 = far_frame[..n].iter().map(|x| x * x).sum::<f32>() / n as f32;
        let far_rms = far_energy.sqrt();
        let mic_energy: f32 = mic_frame[..n].iter().map(|x| x * x).sum::<f32>() / n as f32;
        let mic_rms = mic_energy.sqrt();

        // 远端几乎静音且历史能量可忽略时直接放行，避免损伤人声
        let hist_energy: f32 = self.ref_history.iter().map(|x| x * x).sum::<f32>();
        if far_rms < 1e-4 && hist_energy < 1e-4 {
            return;
        }

        // 双讲判断：笔记本扬声器紧邻麦克风时纯回声幅值可接近 far_rms，阈值设在 1.15x 且 >= 0.06，
        // 避免纯回声误触发双讲冻结 NLMS 权值；用户近距离开口说话时仍会触发双讲保护人声。
        let double_talk = mic_rms > (far_rms * 1.15).max(0.06);
        let step = if double_talk { 0.0 } else { self.mu };

        let taps = self.taps;
        let mut residual_energy = 0.0f32;

        for i in 0..n {
            let x = far_frame[i];
            self.ref_history[self.head] = x;

            // 线性预测扬声器回声 y_hat = w · ref_history
            let mut y_hat = 0.0f32;
            let mut norm = 1e-4f32;
            // 分两段连续切片点积，便于编译器自动 SIMD 向量化
            let first_len = self.head + 1;
            let h_rev_base = self.head;
            for k in 0..first_len {
                let r = self.ref_history[h_rev_base - k];
                y_hat += self.weights[k] * r;
                norm += r * r;
            }
            let rem = taps - first_len;
            for j in 0..rem {
                let r = self.ref_history[taps - 1 - j];
                y_hat += self.weights[first_len + j] * r;
                norm += r * r;
            }

            let err = (mic_frame[i] - y_hat).clamp(-1.0, 1.0);
            mic_frame[i] = err;
            residual_energy += err * err;

            // 非双讲状态下更新 NLMS 权值
            if step > 0.0 && norm > 1e-3 {
                let gain = (step * err) / norm;
                for k in 0..first_len {
                    self.weights[k] += gain * self.ref_history[h_rev_base - k];
                }
                for j in 0..rem {
                    self.weights[first_len + j] += gain * self.ref_history[taps - 1 - j];
                }
            }

            self.head = (self.head + 1) % taps;
        }

        // 残余回声温和抑制（仅在非双讲且远端明显发声时压低残余线性/非线性回声，双讲时全额保留人声）
        let res_rms = (residual_energy / n as f32).sqrt();
        if !double_talk && far_rms > 0.003 && res_rms < far_rms * 0.65 {
            for s in &mut mic_frame[..n] {
                *s *= 0.08;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nlms_aec_suppresses_delayed_echo_and_preserves_double_talk() {
        let mut aec = AcousticEchoCanceller::new();
        let delay = 320; // 20ms @ 16kHz
        let total = 16_000; // 1 秒收敛测试
        let mut far = vec![0.0f32; total];
        for i in 0..total {
            far[i] = ((i as f32) * 0.07).sin() * 0.25 + ((i as f32) * 0.19).cos() * 0.12;
        }

        // 模拟纯回声（远端延迟 20ms 衰减 0.4 倍）
        let mut mic_echo = vec![0.0f32; total];
        for i in delay..total {
            mic_echo[i] = far[i - delay] * 0.4;
        }

        let mut last_rms = 0.0f32;
        for chunk_start in (0..total).step_by(512) {
            let end = (chunk_start + 512).min(total);
            let mut frame = mic_echo[chunk_start..end].to_vec();
            aec.process_frame(&mut frame, &far[chunk_start..end]);
            let e: f32 = frame.iter().map(|x| x * x).sum::<f32>() / frame.len() as f32;
            last_rms = e.sqrt();
        }
        // 收敛后纯回声残余应被大幅压低
        assert!(last_rms < 0.02, "expected echo suppressed, got rms={}", last_rms);

        // 模拟双讲：用户大声说话叠加在回声上，人声应被保留
        let mut dt_frame = vec![0.0f32; 512];
        for i in 0..512 {
            let near_voice = ((i as f32) * 0.13).sin() * 0.35;
            dt_frame[i] = near_voice + far[total - 512 + i - delay] * 0.4;
        }
        aec.process_frame(&mut dt_frame, &far[total - 512..total]);
        let dt_rms = (dt_frame.iter().map(|x| x * x).sum::<f32>() / 512.0).sqrt();
        assert!(dt_rms > 0.15, "expected double-talk speech preserved, got rms={}", dt_rms);
    }
}
