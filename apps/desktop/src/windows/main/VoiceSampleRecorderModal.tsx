import React, { useEffect, useRef, useState } from "react";
import { CheckCircle2, Mic, Play, RotateCcw, Square, Volume2, X } from "lucide-react";

interface VoiceSampleRecorderModalProps {
  open: boolean;
  onClose: () => void;
  onSave: (wavBytes: Uint8Array, refText: string) => Promise<boolean>;
}

const PROMPTS = [
  {
    id: "zh",
    label: "中文朗读（推荐 · 约 5~7 秒）",
    text: "你好，欢迎使用听见实时翻译，今天天气很好，希望我们的交流顺畅愉快。",
  },
  {
    id: "en",
    label: "English（约 5~7 秒）",
    text: "Hello, welcome to Hear real-time translation. Today is a great day, and I hope our conversation goes smoothly.",
  },
];

const TARGET_SAMPLE_RATE = 16000;
const MIN_DURATION_SEC = 3.0;
const MAX_DURATION_SEC = 10.0;

function downsampleTo16k(samples: Float32Array, inputRate: number): Float32Array {
  if (inputRate === TARGET_SAMPLE_RATE) return samples;
  const ratio = inputRate / TARGET_SAMPLE_RATE;
  const outLen = Math.max(1, Math.floor(samples.length / ratio));
  const out = new Float32Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const pos = i * ratio;
    const idx = Math.floor(pos);
    const frac = pos - idx;
    const a = samples[idx] ?? 0;
    const b = samples[Math.min(idx + 1, samples.length - 1)] ?? a;
    out[i] = a + (b - a) * frac;
  }
  return out;
}

function encodeWav16kMono(samples: Float32Array): Uint8Array {
  const numSamples = samples.length;
  const dataBytes = numSamples * 2;
  const buf = new ArrayBuffer(44 + dataBytes);
  const view = new DataView(buf);
  const writeStr = (offset: number, s: string) => {
    for (let i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i));
  };
  writeStr(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  writeStr(8, "WAVE");
  writeStr(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, TARGET_SAMPLE_RATE, true);
  view.setUint32(28, TARGET_SAMPLE_RATE * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeStr(36, "data");
  view.setUint32(40, dataBytes, true);
  let offset = 44;
  for (let i = 0; i < numSamples; i++) {
    const clamped = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff, true);
    offset += 2;
  }
  return new Uint8Array(buf);
}

export const VoiceSampleRecorderModal: React.FC<VoiceSampleRecorderModalProps> = ({
  open,
  onClose,
  onSave,
}) => {
  const [promptIdx, setPromptIdx] = useState(0);
  const [recording, setRecording] = useState(false);
  const [elapsedSec, setElapsedSec] = useState(0);
  const [level, setLevel] = useState(0);
  const [recordedWav, setRecordedWav] = useState<Uint8Array | null>(null);
  const [recordedDurationSec, setRecordedDurationSec] = useState(0);
  const [previewPlaying, setPreviewPlaying] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const streamRef = useRef<MediaStream | null>(null);
  const ctxRef = useRef<AudioContext | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  const chunksRef = useRef<Float32Array[]>([]);
  const sampleRateRef = useRef<number>(48000);
  const timerRef = useRef<number | null>(null);
  const startedAtRef = useRef<number>(0);
  const audioElRef = useRef<HTMLAudioElement | null>(null);
  const audioUrlRef = useRef<string | null>(null);

  const stopPreview = () => {
    if (audioElRef.current) {
      try {
        audioElRef.current.pause();
        audioElRef.current.src = "";
      } catch {
        // ignore
      }
      audioElRef.current = null;
    }
    if (audioUrlRef.current) {
      URL.revokeObjectURL(audioUrlRef.current);
      audioUrlRef.current = null;
    }
    setPreviewPlaying(false);
  };

  const cleanupCapture = () => {
    if (timerRef.current !== null) {
      window.clearInterval(timerRef.current);
      timerRef.current = null;
    }
    if (processorRef.current) {
      try {
        processorRef.current.disconnect();
      } catch {
        // ignore
      }
      processorRef.current = null;
    }
    if (ctxRef.current) {
      void ctxRef.current.close().catch(() => {});
      ctxRef.current = null;
    }
    if (streamRef.current) {
      for (const t of streamRef.current.getTracks()) t.stop();
      streamRef.current = null;
    }
    setLevel(0);
  };

  useEffect(() => {
    if (!open) {
      cleanupCapture();
      stopPreview();
      setRecording(false);
      setElapsedSec(0);
      setRecordedWav(null);
      setRecordedDurationSec(0);
      setError(null);
    }
    return () => {
      cleanupCapture();
      stopPreview();
    };
  }, [open]);

  if (!open) return null;

  const currentPrompt = PROMPTS[promptIdx] ?? PROMPTS[0];

  const finishRecording = () => {
    const chunks = chunksRef.current;
    const inputRate = sampleRateRef.current;
    cleanupCapture();
    setRecording(false);

    const totalLen = chunks.reduce((acc, c) => acc + c.length, 0);
    if (totalLen === 0) {
      setError("未采集到麦克风音频，请检查系统麦克风权限与设备连接。");
      return;
    }
    const merged = new Float32Array(totalLen);
    let offset = 0;
    for (const c of chunks) {
      merged.set(c, offset);
      offset += c.length;
    }
    const resampled = downsampleTo16k(merged, inputRate);
    const maxSamples = Math.floor(MAX_DURATION_SEC * TARGET_SAMPLE_RATE);
    const trimmed = resampled.length > maxSamples ? resampled.subarray(0, maxSamples) : resampled;
    const dur = trimmed.length / TARGET_SAMPLE_RATE;
    const wav = encodeWav16kMono(trimmed);
    setRecordedWav(wav);
    setRecordedDurationSec(dur);
    setElapsedSec(dur);

    if (dur < MIN_DURATION_SEC) {
      setError(`当前仅录制了 ${dur.toFixed(1)} 秒，不足模型要求的 3 秒，请重新录制 3~10 秒。`);
    } else {
      setError(null);
    }
  };

  const startRecording = async () => {
    stopPreview();
    setError(null);
    setRecordedWav(null);
    setRecordedDurationSec(0);
    setElapsedSec(0);
    chunksRef.current = [];

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });
      streamRef.current = stream;
      const AudioCtx = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
      const ctx = new AudioCtx();
      ctxRef.current = ctx;
      sampleRateRef.current = ctx.sampleRate;

      const source = ctx.createMediaStreamSource(stream);
      const processor = ctx.createScriptProcessor(4096, 1, 1);
      processorRef.current = processor;

      processor.onaudioprocess = (ev) => {
        const input = ev.inputBuffer.getChannelData(0);
        const copy = new Float32Array(input.length);
        copy.set(input);
        chunksRef.current.push(copy);

        let sum = 0;
        for (let i = 0; i < input.length; i++) sum += input[i] * input[i];
        const rms = Math.sqrt(sum / Math.max(1, input.length));
        setLevel(Math.min(1, rms * 4.5));
      };

      source.connect(processor);
      processor.connect(ctx.destination);

      startedAtRef.current = performance.now();
      setRecording(true);
      timerRef.current = window.setInterval(() => {
        const sec = (performance.now() - startedAtRef.current) / 1000;
        setElapsedSec(Math.min(MAX_DURATION_SEC, sec));
        if (sec >= MAX_DURATION_SEC) {
          finishRecording();
        }
      }, 60);
    } catch (err) {
      cleanupCapture();
      setRecording(false);
      setError(
        err instanceof Error
          ? `无法打开麦克风：${err.message}`
          : "无法打开麦克风，请检查 Windows 麦克风隐私权限。"
      );
    }
  };

  const togglePreview = () => {
    if (!recordedWav) return;
    if (previewPlaying) {
      stopPreview();
      return;
    }
    const copy = new Uint8Array(recordedWav.byteLength);
    copy.set(recordedWav);
    const blob = new Blob([copy.buffer], { type: "audio/wav" });
    const url = URL.createObjectURL(blob);
    audioUrlRef.current = url;
    const audio = new Audio(url);
    audioElRef.current = audio;
    audio.onended = () => stopPreview();
    audio.onerror = () => stopPreview();
    setPreviewPlaying(true);
    void audio.play().catch(() => stopPreview());
  };

  const handleSave = async () => {
    if (!recordedWav || recordedDurationSec < MIN_DURATION_SEC) return;
    setSaving(true);
    setError(null);
    try {
      const ok = await onSave(recordedWav, currentPrompt.text);
      if (ok) {
        onClose();
      } else {
        setError("保存声纹样本失败，请重试。");
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  };

  const durationValid = recordedWav !== null && recordedDurationSec >= MIN_DURATION_SEC;
  const pct = Math.min(100, (elapsedSec / MAX_DURATION_SEC) * 100);

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/75 backdrop-blur-sm p-4">
      <div className="w-full max-w-lg rounded-2xl bg-surface-900 border border-white/15 shadow-2xl overflow-hidden">
        <div className="px-5 py-4 border-b border-white/10 flex items-center justify-between">
          <div className="flex items-center gap-2 font-semibold text-white text-sm">
            <Mic className="w-4 h-4 text-brand-400" />
            <span>录制我的固定声纹样本</span>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1.5 rounded-lg hover:bg-white/10 text-slate-400 hover:text-white"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        <div className="p-5 space-y-4">
          {/* 模型要求提示 */}
          <div className="rounded-xl bg-brand-500/10 border border-brand-400/30 p-3 text-xs text-slate-200 leading-relaxed space-y-1">
            <div className="font-medium text-brand-300">
              Qwen3-TTS 声纹克隆样本要求（本地 + 云端通用）
            </div>
            <div className="text-slate-300">
              · 时长严格控制在 <span className="font-semibold text-white">3 ~ 10 秒</span>（最佳{" "}
              <span className="font-semibold text-emerald-300">4 ~ 8 秒</span>），超 10 秒将自动停止。
            </div>
            <div className="text-slate-300">
              · 请在安静环境用自然语速<span className="font-semibold text-white">逐字朗读下方指定文本</span>，确保声音与参考文本完全一致。
            </div>
          </div>

          {/* 朗读语言切换 */}
          <div className="flex items-center gap-2">
            {PROMPTS.map((p, idx) => (
              <button
                key={p.id}
                type="button"
                disabled={recording}
                onClick={() => {
                  setPromptIdx(idx);
                  setRecordedWav(null);
                  setRecordedDurationSec(0);
                  setElapsedSec(0);
                  setError(null);
                }}
                className={`px-3 py-1.5 rounded-lg text-xs border transition disabled:opacity-40 ${
                  promptIdx === idx
                    ? "bg-brand-500/25 border-brand-400/50 text-white"
                    : "bg-surface-800 border-white/10 text-slate-400 hover:text-white"
                }`}
              >
                {p.label}
              </button>
            ))}
          </div>

          {/* 指定朗读文本 */}
          <div className="rounded-xl bg-surface-950 border border-white/10 p-4 space-y-1.5">
            <div className="text-[11px] text-slate-400">请朗读以下指定文本：</div>
            <div className="text-base font-medium text-white leading-relaxed select-text">
              「{currentPrompt.text}」
            </div>
          </div>

          {/* 计时进度条 + 实时音量 */}
          <div className="space-y-2">
            <div className="flex items-center justify-between text-xs font-mono">
              <span className={elapsedSec >= MIN_DURATION_SEC ? "text-emerald-300" : "text-slate-300"}>
                {elapsedSec.toFixed(1)}s / {MAX_DURATION_SEC.toFixed(0)}s
              </span>
              <span className="text-slate-400">
                {recording
                  ? elapsedSec < MIN_DURATION_SEC
                    ? `还需至少 ${(MIN_DURATION_SEC - elapsedSec).toFixed(1)}s`
                    : "已达标，读完即可点击停止"
                  : durationValid
                  ? "时长合格（16kHz 单声道 WAV）"
                  : "准备就绪"}
              </span>
            </div>
            <div className="relative h-2 rounded-full bg-surface-800 overflow-hidden">
              {/* 3s 达标刻度线 */}
              <div
                className="absolute top-0 bottom-0 w-0.5 bg-emerald-400/70 z-10"
                style={{ left: `${(MIN_DURATION_SEC / MAX_DURATION_SEC) * 100}%` }}
                title="3 秒最低达标线"
              />
              <div
                className={`h-full transition-all ${
                  elapsedSec >= MIN_DURATION_SEC ? "bg-emerald-500" : "bg-brand-500"
                }`}
                style={{ width: `${pct}%` }}
              />
            </div>

            {recording && (
              <div className="flex items-center gap-2 text-[11px] text-slate-400">
                <Volume2 className="w-3.5 h-3.5 text-emerald-400" />
                <div className="flex-1 h-1.5 rounded-full bg-surface-800 overflow-hidden">
                  <div
                    className="h-full bg-emerald-400 transition-all duration-75"
                    style={{ width: `${Math.round(level * 100)}%` }}
                  />
                </div>
              </div>
            )}
          </div>

          {error && (
            <div className="rounded-lg bg-rose-500/15 border border-rose-400/30 px-3 py-2 text-xs text-rose-200">
              {error}
            </div>
          )}

          {durationValid && !error && (
            <div className="rounded-lg bg-emerald-500/15 border border-emerald-400/30 px-3 py-2 text-xs text-emerald-200 flex items-center gap-2">
              <CheckCircle2 className="w-4 h-4 shrink-0" />
              <span>
                录音完成（{recordedDurationSec.toFixed(1)} 秒），建议先试听确认清晰无杂音后再保存。
              </span>
            </div>
          )}

          {/* 底部控制按钮 */}
          <div className="flex items-center justify-between gap-2 pt-1">
            <div className="flex items-center gap-2">
              {!recording ? (
                <button
                  type="button"
                  onClick={() => void startRecording()}
                  className="px-4 py-2 rounded-lg bg-rose-500 hover:bg-rose-600 text-white text-xs font-medium inline-flex items-center gap-1.5"
                >
                  {recordedWav ? (
                    <>
                      <RotateCcw className="w-3.5 h-3.5" />
                      <span>重新录制</span>
                    </>
                  ) : (
                    <>
                      <Mic className="w-3.5 h-3.5" />
                      <span>开始录制</span>
                    </>
                  )}
                </button>
              ) : (
                <button
                  type="button"
                  onClick={finishRecording}
                  className="px-4 py-2 rounded-lg bg-amber-500 hover:bg-amber-600 text-slate-950 text-xs font-semibold inline-flex items-center gap-1.5"
                >
                  <Square className="w-3.5 h-3.5 fill-current" />
                  <span>停止录制</span>
                </button>
              )}

              {recordedWav && !recording && (
                <button
                  type="button"
                  onClick={togglePreview}
                  className="px-3 py-2 rounded-lg bg-surface-800 border border-white/10 hover:bg-white/10 text-slate-200 text-xs inline-flex items-center gap-1.5"
                >
                  {previewPlaying ? (
                    <>
                      <Square className="w-3.5 h-3.5 fill-current text-emerald-400" />
                      <span>停止试听</span>
                    </>
                  ) : (
                    <>
                      <Play className="w-3.5 h-3.5 text-emerald-400" />
                      <span>试听</span>
                    </>
                  )}
                </button>
              )}
            </div>

            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={onClose}
                className="px-3 py-2 rounded-lg bg-surface-800 border border-white/10 hover:bg-white/10 text-slate-300 text-xs"
              >
                取消
              </button>
              <button
                type="button"
                disabled={!durationValid || recording || saving}
                onClick={() => void handleSave()}
                className="px-4 py-2 rounded-lg bg-brand-500 hover:bg-brand-600 disabled:opacity-40 text-white text-xs font-medium"
              >
                {saving ? "保存中…" : "保存为我的固定声纹"}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
