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

/// 构造与 Hy-MT2 官方推荐一致的翻译提示词（附带匹配的自定义术语表）
pub fn build_translation_prompt(text: &str, src: &str, dst: &str, glossary_raw: &str) -> String {
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
        let hints = if matched_terms.is_empty() {
            String::new()
        } else {
            let rows: Vec<String> = matched_terms
                .iter()
                .map(|(a, b)| format!("{} 翻译成 {}", a, b))
                .collect();
            format!("参考下面的翻译：\n{}\n\n", rows.join("\n"))
        };
        format!(
            "{}将以下文本翻译为{}，注意只需要输出翻译后的结果，不要额外解释：\n\n{}",
            hints,
            lang_zh_name(dst),
            text
        )
    } else {
        let hints = if matched_terms.is_empty() {
            String::new()
        } else {
            let rows: Vec<String> = matched_terms
                .iter()
                .map(|(a, b)| format!("{} translates to {}", a, b))
                .collect();
            format!("Refer to the following translations:\n{}\n\n", rows.join("\n"))
        };
        format!(
            "{}Translate the following segment into {}, without additional explanation.\n\n{}",
            hints,
            lang_en_name(dst),
            text
        )
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

/// 将任意采样率/声道数的实时输入下混为单声道并线性重采样到 16 kHz，再按 512 采样帧喂入 VAD 与断句器
struct LaneProcessor {
    src_rate: u32,
    channels: usize,
    pos: f64,
    prev_sample: Option<f32>,
    frame_buf: Vec<f32>,
    segmenter: Segmenter,
    noise_floor: f32,
    hangover: usize,
}

impl LaneProcessor {
    fn new(src_rate: u32, channels: usize) -> Self {
        Self {
            src_rate: src_rate.max(8_000),
            channels: channels.max(1),
            pos: 0.0,
            prev_sample: None,
            frame_buf: Vec::with_capacity(VAD_WINDOW_SAMPLES * 2),
            segmenter: Segmenter::new(640, 15),
            noise_floor: 0.0012,
            hangover: 0,
        }
    }

    fn push_interleaved<F>(&mut self, interleaved: &[f32], mut on_frame: F)
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

        // 多声道下混：对 4 通道及以上笔记本阵列麦防反相抵消（若均值能量明显低于首通道，则回退首通道）
        let mut mono = Vec::with_capacity(frames);
        let mut avg_energy = 0.0f32;
        let mut ch0_energy = 0.0f32;
        for i in 0..frames {
            let base = i * ch;
            let mut sum = 0.0f32;
            for c in 0..ch {
                sum += interleaved[base + c];
            }
            let avg = sum / ch as f32;
            let c0 = interleaved[base];
            avg_energy += avg * avg;
            ch0_energy += c0 * c0;
            mono.push(avg);
        }
        if ch > 2 && ch0_energy > 1e-7 && avg_energy < ch0_energy * 0.25 {
            mono.clear();
            for i in 0..frames {
                mono.push(interleaved[i * ch]);
            }
        }

        // 线性重采样到 16 kHz
        if self.src_rate == VAD_SAMPLE_RATE {
            self.frame_buf.extend_from_slice(&mono);
        } else {
            let step = self.src_rate as f64 / VAD_SAMPLE_RATE as f64;
            let mut input = Vec::with_capacity(mono.len() + 1);
            if let Some(prev) = self.prev_sample {
                input.push(prev);
            } else {
                input.push(mono[0]);
            }
            input.extend_from_slice(&mono);
            let max_idx = (input.len() - 1) as f64;
            while self.pos < max_idx {
                let idx = self.pos.floor() as usize;
                let frac = (self.pos - idx as f64) as f32;
                let a = input[idx];
                let b = input[(idx + 1).min(input.len() - 1)];
                self.frame_buf.push(a + (b - a) * frac);
                self.pos += step;
            }
            self.pos -= mono.len() as f64;
            if self.pos < 0.0 {
                self.pos = 0.0;
            }
            self.prev_sample = mono.last().copied();
        }

        // 按严格 512 采样帧做自适应能量 VAD + 断句
        while self.frame_buf.len() >= VAD_WINDOW_SAMPLES {
            let frame: Vec<f32> = self.frame_buf.drain(..VAD_WINDOW_SAMPLES).collect();
            let energy: f32 = frame.iter().map(|s| s * s).sum::<f32>() / frame.len() as f32;
            let rms = energy.sqrt();

            let thresh = (self.noise_floor * 2.4).max(0.0028).min(0.045);
            let speech_now = rms > thresh;
            let has_speech = if speech_now {
                self.hangover = 7; // ~224ms 拖尾保护，防止吞尾音
                true
            } else if self.hangover > 0 {
                self.hangover -= 1;
                true
            } else {
                // 仅在静音时缓慢更新底噪估计
                self.noise_floor = (self.noise_floor * 0.96 + rms * 0.04).clamp(0.0005, 0.018);
                false
            };

            let ev = self.segmenter.push_frame(&frame, has_speech);
            let level = (rms * 12.0).clamp(0.0, 1.0);
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
        eCapture, eConsole, eRender, IAudioCaptureClient, IAudioClient, IMMDeviceEnumerator,
        MMDeviceEnumerator, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, WAVEFORMATEX,
        WAVEFORMATEXTENSIBLE,
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
        audio_client: IAudioClient,
        capture_client: IAudioCaptureClient,
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
        unsafe fn open(
            enumerator: &IMMDeviceEnumerator,
            channel: AudioChannel,
            is_loopback: bool,
        ) -> Result<Self, String> {
            let flow = if is_loopback { eRender } else { eCapture };
            let device = enumerator
                .GetDefaultAudioEndpoint(flow, eConsole)
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
                audio_client,
                capture_client,
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

        unsafe fn drain_packets(
            &mut self,
            seg_tx: &tokio_mpsc::UnboundedSender<CapturedSegment>,
        ) -> f32 {
            let mut max_level = 0.0f32;
            let mut scratch: Vec<f32> = Vec::new();

            loop {
                let pkt = match self.capture_client.GetNextPacketSize() {
                    Ok(n) if n > 0 => n,
                    _ => break,
                };
                let _ = pkt;

                let mut data_ptr: *mut u8 = std::ptr::null_mut();
                let mut num_frames: u32 = 0;
                let mut buf_flags: u32 = 0;
                if self
                    .capture_client
                    .GetBuffer(&mut data_ptr, &mut num_frames, &mut buf_flags, None, None)
                    .is_err()
                {
                    break;
                }

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

                let _ = self.capture_client.ReleaseBuffer(num_frames);

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
                self.processor.push_interleaved(&scratch, |frame, has_speech, level, ev| {
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
            max_level
        }

        unsafe fn discard_packets(&mut self) {
            loop {
                let pkt = match self.capture_client.GetNextPacketSize() {
                    Ok(n) if n > 0 => n,
                    _ => break,
                };
                let _ = pkt;
                let mut data_ptr: *mut u8 = std::ptr::null_mut();
                let mut num_frames: u32 = 0;
                let mut buf_flags: u32 = 0;
                if self
                    .capture_client
                    .GetBuffer(&mut data_ptr, &mut num_frames, &mut buf_flags, None, None)
                    .is_err()
                {
                    break;
                }
                let _ = self.capture_client.ReleaseBuffer(num_frames);
            }
        }

        unsafe fn stop_and_flush(
            &mut self,
            seg_tx: &tokio_mpsc::UnboundedSender<CapturedSegment>,
        ) {
            let _ = self.audio_client.Stop();
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
                let mut mixed = Vec::with_capacity(rem);
                for _ in 0..rem {
                    let a = q0.pop_front().unwrap_or(0.0);
                    let b = q1.pop_front().unwrap_or(0.0);
                    mixed.push((a + b).clamp(-1.0, 1.0));
                }
                let _ = rec.write_f32(&mixed);
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
                match WasapiLane::open(&enumerator, AudioChannel::System, true) {
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
                match WasapiLane::open(&enumerator, AudioChannel::Mic, false) {
                    Ok(lane) => lanes.push(lane),
                    Err(e) => {
                        for l in &mut lanes {
                            let _ = l.audio_client.Stop();
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
            let mut recorder = StreamingWavRecorder::create(&rec_path, VAD_SAMPLE_RATE, 1).ok();

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
                }

                let mut level = 0.0f32;
                for lane in &mut lanes {
                    let l = lane.drain_packets(&seg_tx);
                    if l > level {
                        level = l;
                    }
                }

                // 将单路或双路（系统声 + 麦克风）真实混合写入 WAV 录音文件，确保回放与波形永远有声
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
                            let mut mixed = Vec::with_capacity(common);
                            for _ in 0..common {
                                let a = q0.pop_front().unwrap_or(0.0);
                                let b = q1.pop_front().unwrap_or(0.0);
                                mixed.push((a + b).clamp(-1.0, 1.0));
                            }
                            let _ = rec.write_f32(&mixed);
                        }
                        // 若其中一路暂停吐包（例如系统扬声器未播放任何声音），防止另一路积压超过 250ms
                        let max_lead = (VAD_SAMPLE_RATE as usize) / 4;
                        if q0.len() > max_lead {
                            let extra = q0.len() - max_lead;
                            let buf: Vec<f32> = q0.drain(..extra).collect();
                            let _ = rec.write_f32(&buf);
                        } else if q1.len() > max_lead {
                            let extra = q1.len() - max_lead;
                            let buf: Vec<f32> = q1.drain(..extra).collect();
                            let _ = rec.write_f32(&buf);
                        }
                    }

                    if last_live_tick.elapsed().as_millis() >= 300 {
                        last_live_tick = Instant::now();
                        let dur = rec.duration_ms();
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

            while let Some(item) = seg_rx.recv().await {
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
                            .map(|t| t.elapsed().as_millis() < 900)
                            .unwrap_or(false);
                        if throttled || samples.len() < (VAD_SAMPLE_RATE as usize / 2) {
                            continue;
                        }
                        last_preview_at = Some(Instant::now());
                        let wav = encode_wav_16k_mono(&samples);
                        if let Ok((text, _)) = rt
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
                            if !text.is_empty() {
                                {
                                    let mut snap = rt.snapshot.lock().await;
                                    snap.live_partial_source = text.clone();
                                }
                                let _ = app.emit(
                                    "subtitle:partial",
                                    serde_json::json!({
                                        "source": text,
                                        "translation": "正在识别…"
                                    }),
                                );
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
                        let (source_text, detected_lang) = match rt
                            .cloud
                            .transcribe_wav(
                                &asr_url,
                                wav,
                                &languages_hdr,
                                &src_lang,
                                false,
                                asr_token_opt,
                            )
                            .await
                        {
                            Ok(pair) => {
                                logger::info(format!(
                                    "[asr] seg={} ms={} lang={} chars={}",
                                    segment_id,
                                    t0.elapsed().as_millis(),
                                    pair.1,
                                    pair.0.chars().count()
                                ));
                                pair
                            }
                            Err(err) => {
                                logger::error(format!("[asr] seg={} failed: {}", segment_id, err));
                                let _ = app.emit("session:error", err);
                                continue;
                            }
                        };

                        if source_text.trim().is_empty() {
                            let mut snap = rt.snapshot.lock().await;
                            snap.live_partial_source.clear();
                            snap.live_partial_translation.clear();
                            let _ = app.emit(
                                "subtitle:partial",
                                serde_json::json!({ "source": "", "translation": "" }),
                            );
                            continue;
                        }

                        let (actual_src, actual_dst) =
                            if !lock_src && detected_lang == dst_lang && dst_lang != src_lang {
                                (dst_lang.clone(), src_lang.clone())
                            } else {
                                (
                                    if detected_lang.is_empty() {
                                        src_lang.clone()
                                    } else {
                                        detected_lang
                                    },
                                    dst_lang.clone(),
                                )
                            };

                        let seg_uuid = format!("seg-{}-{}", segment_id, uuid::Uuid::new_v4());
                        let mut seg = SubtitleSegment {
                            id: seg_uuid.clone(),
                            seq: segment_id,
                            start_ms,
                            end_ms,
                            channel: item.channel,
                            speaker_label: Some(
                                if item.channel == AudioChannel::Mic {
                                    "我".to_string()
                                } else {
                                    "对方".to_string()
                                },
                            ),
                            source_lang: actual_src.clone(),
                            target_lang: actual_dst.clone(),
                            source_text: source_text.clone(),
                            translated_text: "翻译中…".to_string(),
                            baseline_translated: None,
                            status: "preview".to_string(),
                            is_edited: None,
                        };

                        {
                            let mut snap = rt.snapshot.lock().await;
                            snap.segments.push(seg.clone());
                            snap.live_partial_source = source_text.clone();
                            snap.live_partial_translation = "翻译中…".to_string();
                        }
                        let _ = app.emit("segment:upsert", &seg);
                        let _ = app.emit(
                            "subtitle:partial",
                            serde_json::json!({
                                "source": source_text,
                                "translation": "翻译中…"
                            }),
                        );

                        let t_mt = Instant::now();
                        let prompt =
                            build_translation_prompt(&source_text, &actual_src, &actual_dst, &glossary);
                        let app_stream = app.clone();
                        let src_for_cb = source_text.clone();
                        let mut seg_cb = seg.clone();

                        match rt
                            .cloud
                            .translate_stream(&mt_url, &prompt, false, mt_token_opt, |partial_raw| {
                                let cleaned = clean_translation_output(partial_raw);
                                if !cleaned.is_empty() {
                                    seg_cb.translated_text = cleaned.clone();
                                    let _ = app_stream.emit("segment:upsert", &seg_cb);
                                    let _ = app_stream.emit(
                                        "subtitle:partial",
                                        serde_json::json!({
                                            "source": src_for_cb,
                                            "translation": cleaned
                                        }),
                                    );
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
        assert!(speech_frames >= 5);
    }
}
