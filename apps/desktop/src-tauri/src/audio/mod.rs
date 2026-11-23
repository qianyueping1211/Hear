use crate::recorder::{encode_wav_16k_mono, StreamingWavRecorder};
use crate::state::{AudioCaptureMode, AudioChannel, EngineSource, SubtitleSegment};
use crate::vad::{SegmentEvent, Segmenter, VAD_SAMPLE_RATE, VAD_WINDOW_SAMPLES};
use crate::AppRuntime;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, Stream, StreamConfig};
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
    channel: AudioChannel,
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
    fn new(channel: AudioChannel, src_rate: u32, channels: usize) -> Self {
        Self {
            channel,
            src_rate: src_rate.max(8_000),
            channels: channels.max(1),
            pos: 0.0,
            prev_sample: None,
            frame_buf: Vec::with_capacity(VAD_WINDOW_SAMPLES * 2),
            segmenter: Segmenter::new(640, 15),
            noise_floor: 0.004,
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
        let mut mono = Vec::with_capacity(frames);
        for i in 0..frames {
            let mut sum = 0.0f32;
            let base = i * ch;
            for c in 0..ch {
                sum += interleaved[base + c];
            }
            mono.push(sum / ch as f32);
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

            let thresh = (self.noise_floor * 2.6).max(0.0085).min(0.06);
            let speech_now = rms > thresh;
            let has_speech = if speech_now {
                self.hangover = 6; // ~192ms 拖尾保护，防止吞尾音
                true
            } else if self.hangover > 0 {
                self.hangover -= 1;
                true
            } else {
                // 仅在静音时缓慢更新底噪估计
                self.noise_floor = (self.noise_floor * 0.96 + rms * 0.04).clamp(0.0015, 0.025);
                false
            };

            let ev = self.segmenter.push_frame(&frame, has_speech);
            let level = (rms * 8.0).clamp(0.0, 1.0);
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
        let _ = err_app.emit("session:error", format!("音频采集流异常：{}", err));
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
        SampleFormat::I32 => {
            let mut cb = on_samples;
            device
                .build_input_stream(
                    config,
                    move |data: &[i32], _| {
                        let f: Vec<f32> =
                            data.iter().map(|&s| (s as f64 / 2_147_483_648.0) as f32).collect();
                        cb(&f);
                    },
                    err_fn,
                    None,
                )
                .map_err(|e| format!("创建 I32 音频流失败：{}", e))
        }
        SampleFormat::U16 => {
            let mut cb = on_samples;
            device
                .build_input_stream(
                    config,
                    move |data: &[u16], _| {
                        let f: Vec<f32> =
                            data.iter().map(|&s| (s as f32 - 32768.0) / 32768.0).collect();
                        cb(&f);
                    },
                    err_fn,
                    None,
                )
                .map_err(|e| format!("创建 U16 音频流失败：{}", e))
        }
        other => Err(format!("不支持的音频采样格式：{:?}", other)),
    }
}

/// 正在运行的实时采集与翻译会话句柄（停止时优雅关闭音频流、落盘 WAV 并结束后台推理）
pub struct LiveCaptureHandle {
    stop_flag: Arc<AtomicBool>,
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
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::sync_channel::<Result<(), String>>(1);
        let (seg_tx, mut seg_rx) = tokio_mpsc::unbounded_channel::<CapturedSegment>();

        let app_capture = app.clone();
        let rt_capture = rt.clone();
        let stop_flag_capture = stop_flag.clone();

        let capture_thread = std::thread::Builder::new()
            .name("hear-audio-capture".to_string())
            .spawn(move || {
                let host = cpal::default_host();
                let mut streams: Vec<Stream> = Vec::new();
                let mut processors: Vec<Arc<std::sync::Mutex<LaneProcessor>>> = Vec::new();

                let rec_path = std::env::temp_dir()
                    .join("Hear-Recordings")
                    .join(format!("rec-{}.wav", uuid::Uuid::new_v4()));
                let recorder = StreamingWavRecorder::create(&rec_path, VAD_SAMPLE_RATE, 1)
                    .ok()
                    .map(|r| Arc::new(std::sync::Mutex::new(r)));

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

                let mut setup_err: Option<String> = None;

                if want_system {
                    match host.default_output_device() {
                        Some(dev) => match dev.default_output_config() {
                            Ok(supported) => {
                                let fmt = supported.sample_format();
                                let cfg: StreamConfig = supported.into();
                                let proc = Arc::new(std::sync::Mutex::new(LaneProcessor::new(
                                    AudioChannel::System,
                                    cfg.sample_rate.0,
                                    cfg.channels as usize,
                                )));
                                let proc_cb = proc.clone();
                                let tx_cb = seg_tx.clone();
                                let app_cb = app_capture.clone();
                                let rec_cb = recorder.clone();
                                let stop_cb = stop_flag_capture.clone();
                                let mut last_level_emit = Instant::now();
                                match build_cpal_stream(
                                    &dev,
                                    &cfg,
                                    fmt,
                                    move |samples| {
                                        if stop_cb.load(Ordering::Relaxed) {
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
                                                        channel: AudioChannel::System,
                                                        event,
                                                    });
                                                }
                                            });
                                        }
                                    },
                                    app_capture.clone(),
                                ) {
                                    Ok(stream) => {
                                        if let Err(e) = stream.play() {
                                            setup_err = Some(format!("启动系统内录失败：{}", e));
                                        } else {
                                            streams.push(stream);
                                            processors.push(proc);
                                        }
                                    }
                                    Err(e) => setup_err = Some(format!("系统声音内录初始化失败：{}", e)),
                                }
                            }
                            Err(e) => setup_err = Some(format!("获取系统播放设备参数失败：{}", e)),
                        },
                        None => setup_err = Some("未找到系统默认播放设备，无法捕获系统声音".to_string()),
                    }
                }

                if setup_err.is_none() && want_mic {
                    match host.default_input_device() {
                        Some(dev) => match dev.default_input_config() {
                            Ok(supported) => {
                                let fmt = supported.sample_format();
                                let cfg: StreamConfig = supported.into();
                                let proc = Arc::new(std::sync::Mutex::new(LaneProcessor::new(
                                    AudioChannel::Mic,
                                    cfg.sample_rate.0,
                                    cfg.channels as usize,
                                )));
                                let proc_cb = proc.clone();
                                let tx_cb = seg_tx.clone();
                                let app_cb = app_capture.clone();
                                let rec_cb = if !want_system { recorder.clone() } else { None };
                                let stop_cb = stop_flag_capture.clone();
                                let mut last_level_emit = Instant::now();
                                match build_cpal_stream(
                                    &dev,
                                    &cfg,
                                    fmt,
                                    move |samples| {
                                        if stop_cb.load(Ordering::Relaxed) {
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
                                    app_capture.clone(),
                                ) {
                                    Ok(stream) => {
                                        if let Err(e) = stream.play() {
                                            setup_err = Some(format!("启动麦克风采集失败：{}", e));
                                        } else {
                                            streams.push(stream);
                                            processors.push(proc);
                                        }
                                    }
                                    Err(e) => setup_err = Some(format!("麦克风初始化失败：{}", e)),
                                }
                            }
                            Err(e) => setup_err = Some(format!("获取麦克风参数失败：{}", e)),
                        },
                        None => setup_err = Some("未找到默认麦克风设备".to_string()),
                    }
                }

                if let Some(err) = setup_err {
                    drop(streams);
                    let _ = ready_tx.send(Err(err));
                    return;
                }

                let _ = ready_tx.send(Ok(()));

                // 阻塞等待停止信号，期间保持 WASAPI 音频流存活
                let _ = stop_rx.recv();
                stop_flag_capture.store(true, Ordering::Relaxed);
                drop(streams);

                // 停录时冲刷句尾未切完的话，避免丢最后半句
                for proc in &processors {
                    if let Ok(mut p) = proc.lock() {
                        let ch = p.channel;
                        if let Some(ev) = p.flush_final() {
                            let _ = seg_tx.send(CapturedSegment { channel: ch, event: ev });
                        }
                    }
                }
                drop(seg_tx);

                // 结束并回写录音文件头，将真实波形与时长同步回前端播放器
                if let Some(rec_arc) = recorder {
                    if let Ok(rec_mutex) = Arc::try_unwrap(rec_arc) {
                        if let Ok(rec) = rec_mutex.into_inner() {
                            if let Ok((path, duration_ms, peaks)) = rec.finalize() {
                                if duration_ms > 0 {
                                    let rt_done = rt_capture.clone();
                                    let app_done = app_capture.clone();
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
                let _ = app_capture.emit("audio:level", 0.0f32);
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

        // 启动异步推理消费协程：VAD 片段 -> /v1/asr -> 流式 /v1/translate -> 实时推送主窗与悬浮字幕
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
                        // 实时预览节流（至少间隔 900ms，避免压爆 CPU/网关）
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
                        // 忽略过短的噪声片段（< 250ms）
                        if samples.len() < (VAD_SAMPLE_RATE as usize / 4) {
                            continue;
                        }
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
                            Ok(pair) => pair,
                            Err(err) => {
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

                        // 双向自动判别方向（未锁定源语种且识别结果为目标语种时自动反向翻译）
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
            stop_tx: Some(stop_tx),
            capture_thread: Some(capture_thread),
            worker_task,
        })
    }

    pub fn stop(mut self) {
        self.stop_flag.store(true, Ordering::Relaxed);
        if let Some(tx) = self.stop_tx.take() {
            let _ = tx.send(());
        }
        if let Some(handle) = self.capture_thread.take() {
            let _ = handle.join();
        }
        // worker_task 会在 seg_rx 消费完冲刷出来的最后一句后自动退出
        let _ = &self.worker_task;
    }
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
        let mut lane = LaneProcessor::new(AudioChannel::System, 48_000, 2);
        // 0.2s of stereo 48kHz tone -> 9600 frames = 19200 interleaved samples -> ~3200 mono 16k samples (6 frames of 512)
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
