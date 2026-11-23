import { useEffect, useRef, useState } from "react";
import {
  Headphones,
  Mic,
  Pause,
  Play,
  RotateCcw,
  RotateCw,
  Square,
  Volume2,
} from "lucide-react";
import { formatTimestamp } from "../../lib/export";
import { useHearStore } from "../../stores/useHearStore";
import type { AudioCaptureMode } from "../../types/hear";

const SPEEDS = [0.75, 1.0, 1.25, 1.5, 2.0];

export function WaveformPlayer() {
  const {
    mode,
    audioLevel,
    captureMode,
    audioSources,
    segments,
    playback,
    seekNonce,
    seekTargetMs,
    setCaptureMode,
    startRecording,
    pauseRecording,
    resumeRecording,
    stopRecording,
    togglePlayback,
    setPlaybackPlaying,
    syncPlaybackPosition,
    readRecordingAudio,
    seekPlayback,
    setPlaybackSpeed,
    setTrackVolumes,
  } = useHearStore();

  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const sysGainRef = useRef<GainNode | null>(null);
  const micGainRef = useRef<GainNode | null>(null);
  const [audioUrl, setAudioUrl] = useState<string | null>(null);

  // 录音结束后（idle 且有音频文件）才从 Rust 后端加载 WAV 字节供回放；新录音录制中或暂停中不提供播放
  useEffect(() => {
    let revoked = false;
    let objectUrl: string | null = null;
    if (
      !playback.hasAudio ||
      !playback.audioPath ||
      mode === "recording" ||
      mode === "paused"
    ) {
      setAudioUrl(null);
      return;
    }
    void readRecordingAudio().then((bytes) => {
      if (revoked || !bytes || bytes.byteLength === 0) return;
      const copy = new Uint8Array(bytes.byteLength);
      copy.set(bytes);
      const blob = new Blob([copy.buffer], { type: "audio/wav" });
      objectUrl = URL.createObjectURL(blob);
      setAudioUrl(objectUrl);
    });
    return () => {
      revoked = true;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [
    playback.hasAudio,
    playback.audioPath,
    playback.durationMs,
    mode,
    readRecordingAudio,
  ]);

  // 响应显式跳转请求（点波形、点字幕句子、快退/快进）
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio || !audioUrl || seekNonce === 0) return;
    audio.currentTime = Math.max(0, seekTargetMs / 1000);
    if (playback.isPlaying) {
      void audio.play().catch(() => {});
    }
  }, [seekNonce, seekTargetMs, audioUrl, playback.isPlaying]);

  // 同步播放/暂停、倍速与分轨独立音量（左声道=系统内录/对方，右声道=麦克风/我）
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;
    audio.playbackRate = playback.speed;
    if (sysGainRef.current && micGainRef.current) {
      audio.volume = 1.0;
      sysGainRef.current.gain.value = Math.max(0, Math.min(1.5, playback.systemVolume));
      micGainRef.current.gain.value =
        captureMode === "dual_mix"
          ? Math.max(0, Math.min(1.5, playback.micVolume))
          : 0.0;
    } else {
      audio.volume = Math.max(0, Math.min(1, playback.systemVolume));
    }
  }, [playback.speed, playback.systemVolume, playback.micVolume, captureMode, audioUrl]);

  const ensureWebAudioGraph = () => {
    const audio = audioRef.current;
    if (!audio || audioCtxRef.current) {
      if (audioCtxRef.current?.state === "suspended") {
        void audioCtxRef.current.resume();
      }
      return;
    }
    try {
      const Ctx =
        window.AudioContext ||
        (window as unknown as { webkitAudioContext: typeof AudioContext })
          .webkitAudioContext;
      if (!Ctx) return;
      const ctx = new Ctx();
      const source = ctx.createMediaElementSource(audio);
      const splitter = ctx.createChannelSplitter(2);
      const sysGain = ctx.createGain();
      const micGain = ctx.createGain();
      sysGain.gain.value = Math.max(0, Math.min(1.5, playback.systemVolume));
      micGain.gain.value =
        captureMode === "dual_mix"
          ? Math.max(0, Math.min(1.5, playback.micVolume))
          : 0.0;
      source.connect(splitter);
      splitter.connect(sysGain, 0);
      splitter.connect(micGain, 1);
      sysGain.connect(ctx.destination);
      micGain.connect(ctx.destination);
      audioCtxRef.current = ctx;
      sysGainRef.current = sysGain;
      micGainRef.current = micGain;
    } catch {
      // Web Audio 不支持或已绑定时退回原生 audio.volume
    }
  };

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio || !audioUrl) return;
    if (playback.isPlaying) {
      ensureWebAudioGraph();
      void audio.play().catch(() => {
        void setPlaybackPlaying(false);
      });
    } else {
      audio.pause();
    }
  }, [playback.isPlaying, audioUrl, setPlaybackPlaying]);

  // 播放期间高频平滑刷新波形指针与字幕高亮位置
  useEffect(() => {
    if (!playback.isPlaying || !audioUrl) return;
    const timer = window.setInterval(() => {
      const audio = audioRef.current;
      if (audio && !audio.paused) {
        syncPlaybackPosition(audio.currentTime * 1000);
      }
    }, 60);
    return () => window.clearInterval(timer);
  }, [playback.isPlaying, audioUrl, syncPlaybackPosition]);

  // 根据状态绘制不同主题的波形与进度条（录音中实时生长、暂停/回放态可点击定位）
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    const width = canvas.clientWidth || 400;
    const height = canvas.clientHeight || 36;
    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, width, height);

    const isRecording = mode === "recording";
    const isPaused = mode === "paused";
    const rawPeaks = playback.peaks;
    let maxRawPeak = 0;
    for (let k = 0; k < rawPeaks.length; k++) {
      if (rawPeaks[k] > maxRawPeak) maxRawPeak = rawPeaks[k];
    }

    let peaks: number[];
    if (rawPeaks.length > 0 && maxRawPeak >= 0.0015) {
      const normBase = Math.max(maxRawPeak, 0.015);
      peaks = rawPeaks.map((p) => {
        if (p < 0.001) return 0.08;
        const ratio = Math.min(1, p / normBase);
        return Math.max(0.1, Math.min(0.96, Math.pow(ratio, 0.62)));
      });
    } else if (segments.length > 0) {
      // 若历史记录或刚结束的会话缺少原始峰值采样，根据对话句子时间轴自动生成高对比度声纹图
      const totalMs = Math.max(
        playback.durationMs,
        segments[segments.length - 1]?.endMs ?? 0,
        1000
      );
      const count = 120;
      peaks = new Array(count).fill(0.08);
      for (let idx = 0; idx < count; idx++) {
        const tMs = (idx * totalMs) / count;
        const seg = segments.find(
          (s) => tMs >= s.startMs && tMs <= Math.max(s.endMs, s.startMs + 350)
        );
        if (seg) {
          const span = Math.max(350, seg.endMs - seg.startMs);
          const rel = Math.max(0, Math.min(1, (tMs - seg.startMs) / span));
          const env = Math.max(0.25, Math.sin(rel * Math.PI));
          const jitter = ((idx * 37 + seg.seq * 13) % 19) / 19;
          peaks[idx] = Math.max(
            0.18,
            Math.min(0.95, 0.28 + env * 0.45 + jitter * 0.22)
          );
        }
      }
    } else {
      peaks = new Array(80).fill(0.08);
    }

    const barCount = Math.min(
      Math.max(peaks.length, 64),
      Math.max(64, Math.floor(width / 4))
    );
    const barW = width / barCount;
    const totalDurMs =
      playback.durationMs || (segments[segments.length - 1]?.endMs ?? 0);
    const progress =
      isRecording || isPaused
        ? 1.0
        : totalDurMs > 0
        ? Math.max(0, Math.min(1, playback.positionMs / totalDurMs))
        : 0;

    for (let i = 0; i < barCount; i++) {
      const srcIdx = Math.floor((i / barCount) * peaks.length);
      let amp = Math.max(0.08, Math.min(1, peaks[srcIdx] ?? 0.08));
      // 录音中让最右侧几个柱子叠加当前实时电平跳动感
      if (isRecording && i >= barCount - 3) {
        amp = Math.max(amp, Math.min(1, audioLevel * 1.15 + 0.1));
      }
      const barH = amp * (height - 6);
      const x = i * barW;
      const y = (height - barH) / 2;
      const ratio = i / barCount;

      if (isRecording) {
        ctx.fillStyle =
          i >= barCount - 4 ? "#fb7185" : "rgba(244, 63, 94, 0.72)";
      } else if (isPaused) {
        ctx.fillStyle =
          ratio <= progress ? "#fbbf24" : "rgba(251, 191, 36, 0.30)";
      } else if (playback.hasAudio || segments.length > 0) {
        ctx.fillStyle =
          ratio <= progress ? "#60a5fa" : "rgba(96, 165, 250, 0.42)";
      } else {
        ctx.fillStyle =
          ratio <= progress ? "#60a5fa" : "rgba(148, 163, 184, 0.28)";
      }
      ctx.fillRect(x + 0.5, y, Math.max(1.5, barW - 1.5), barH);
    }

    // 指针（录音中在最右端脉冲，回放/暂停态在当前播放位置）
    if (isRecording || playback.hasAudio || segments.length > 0) {
      const px = Math.min(width - 2, Math.max(1, progress * width));
      ctx.fillStyle = isRecording ? "#fda4af" : "#f8fafc";
      ctx.fillRect(px - 1, 0, 2, height);
    }
  }, [
    mode,
    audioLevel,
    segments,
    playback.peaks,
    playback.positionMs,
    playback.durationMs,
    playback.hasAudio,
  ]);

  const canSeek =
    mode === "idle" && playback.hasAudio && playback.durationMs > 0;

  const handleCanvasClick = (e: React.MouseEvent<HTMLCanvasElement>) => {
    if (!canSeek) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const ratio = Math.max(
      0,
      Math.min(1, (e.clientX - rect.left) / rect.width)
    );
    void seekPlayback(ratio * playback.durationMs, true);
  };

  const nextSpeed = () => {
    const idx = SPEEDS.indexOf(playback.speed);
    setPlaybackSpeed(SPEEDS[(idx + 1) % SPEEDS.length]);
  };

  return (
    <div className="h-20 border-t border-white/10 bg-surface-900/95 px-5 flex items-center gap-4">
      <audio
        ref={audioRef}
        src={audioUrl ?? undefined}
        preload="auto"
        onEnded={() => {
          syncPlaybackPosition(playback.durationMs);
          void setPlaybackPlaying(false);
        }}
        className="hidden"
      />

      {/* 左侧主控区：录制中（暂停+结束）、已暂停（继续+结束，无播放按钮）、已结束回放（快退+播放+快进+新录音） */}
      <div className="flex items-center gap-2 shrink-0">
        {mode === "recording" ? (
          <>
            <button
              type="button"
              onClick={() => void pauseRecording()}
              title="暂停当前录音"
              className="px-3.5 py-2 rounded-full bg-amber-500 hover:bg-amber-600 text-slate-950 text-xs font-semibold flex items-center gap-1.5 shadow transition"
            >
              <Pause className="w-3.5 h-3.5 fill-current" />
              暂停
            </button>
            <button
              type="button"
              onClick={() => void stopRecording()}
              title="结束本轮录音并进入回放与总结"
              className="px-3.5 py-2 rounded-full bg-rose-500 hover:bg-rose-600 text-white text-xs font-semibold flex items-center gap-1.5 shadow transition"
            >
              <Square className="w-3.5 h-3.5 fill-current" />
              结束
            </button>
          </>
        ) : mode === "paused" ? (
          <>
            <button
              type="button"
              onClick={() => void resumeRecording()}
              title="从暂停处无缝继续"
              className="px-4 py-2 rounded-full bg-emerald-500 hover:bg-emerald-600 text-white text-xs font-semibold flex items-center gap-1.5 shadow transition"
            >
              <Mic className="w-3.5 h-3.5" />
              继续
            </button>
            <button
              type="button"
              onClick={() => void stopRecording()}
              title="结束本轮录音并生成完整回放音频"
              className="px-3.5 py-2 rounded-full bg-rose-500/90 hover:bg-rose-600 text-white text-xs font-semibold flex items-center gap-1.5 transition"
            >
              <Square className="w-3.5 h-3.5 fill-current" />
              结束
            </button>
          </>
        ) : playback.hasAudio ? (
          <>
            <button
              type="button"
              onClick={() =>
                void seekPlayback(
                  Math.max(0, playback.positionMs - 5000),
                  playback.isPlaying
                )
              }
              title="快退 5 秒"
              className="p-2 rounded-lg text-slate-300 hover:bg-white/10"
            >
              <RotateCcw className="w-4 h-4" />
            </button>
            <button
              type="button"
              onClick={() => void togglePlayback()}
              title="播放 / 暂停完整录音"
              className="w-10 h-10 rounded-full bg-brand-500 hover:bg-brand-600 text-white flex items-center justify-center shadow"
            >
              {playback.isPlaying ? (
                <Pause className="w-4 h-4" />
              ) : (
                <Play className="w-4 h-4 ml-0.5" />
              )}
            </button>
            <button
              type="button"
              onClick={() =>
                void seekPlayback(
                  Math.min(playback.durationMs, playback.positionMs + 5000),
                  playback.isPlaying
                )
              }
              title="快进 5 秒"
              className="p-2 rounded-lg text-slate-300 hover:bg-white/10"
            >
              <RotateCw className="w-4 h-4" />
            </button>
            <button
              type="button"
              onClick={() => void startRecording(true)}
              title="开启新一轮实时录音"
              className="ml-1 px-3 py-1.5 rounded-full bg-surface-800 border border-white/15 hover:bg-brand-500 hover:border-brand-400 text-xs text-slate-200 hover:text-white flex items-center gap-1.5 transition"
            >
              <Mic className="w-3.5 h-3.5 text-rose-400" />
              新录音
            </button>
          </>
        ) : (
          <button
            type="button"
            disabled={mode === "batch_processing"}
            onClick={() => void startRecording(false)}
            className="px-4 py-2 rounded-full bg-brand-500 hover:bg-brand-600 disabled:opacity-50 text-white text-xs font-semibold flex items-center gap-2 shadow transition"
          >
            <Mic className="w-4 h-4" />
            开始录音
          </button>
        )}
      </div>

      {/* 中央：状态时间 + 波形进度条 */}
      <div className="flex-1 flex flex-col gap-1 min-w-0">
        <div className="flex items-center justify-between text-xs text-slate-400 font-mono">
          {mode === "recording" ? (
            <span className="flex items-center gap-1.5 text-rose-400 font-semibold">
              <span
                className="w-2 h-2 rounded-full bg-rose-500 animate-ping"
                style={{ opacity: 0.5 + Math.min(0.5, audioLevel) }}
              />
              正在录音 {formatTimestamp(playback.durationMs)}
            </span>
          ) : mode === "paused" ? (
            <span className="text-amber-300 font-semibold">
              已暂停 · {formatTimestamp(playback.durationMs)}
            </span>
          ) : (
            <span>{formatTimestamp(playback.positionMs)}</span>
          )}

          <span className="text-[11px] font-sans text-slate-500 truncate px-2">
            {mode === "recording"
              ? "正在实时采集并识别翻译… 可随时点击左侧「暂停」或「结束」"
              : mode === "paused"
              ? "录音已暂停：点击左侧「继续」无缝接着录制，或点击「结束」进入回放与总结"
              : playback.hasAudio
              ? "点击波形或任意字幕卡片即可精准跳转录音位置"
              : "点击左侧「开始录音」启动实时翻译"}
          </span>

          <span>{formatTimestamp(playback.durationMs)}</span>
        </div>
        <canvas
          ref={canvasRef}
          onClick={handleCanvasClick}
          className={`w-full h-9 rounded-md bg-surface-950/70 ${
            canSeek
              ? "cursor-pointer"
              : mode === "recording"
              ? "ring-1 ring-rose-500/30"
              : mode === "paused"
              ? "ring-1 ring-amber-500/30"
              : segments.length > 0 || playback.peaks.length > 0
              ? ""
              : "opacity-50"
          }`}
        />
      </div>

      {/* 右侧：回放界面显示倍速与音量；录制界面右下角显示收音音源选择（带耳机/音源图标，非设置图标） */}
      {canSeek ? (
        <div className="flex items-center gap-3 shrink-0">
          <button
            onClick={nextSpeed}
            title="回放倍速"
            className="px-2.5 py-1 rounded-md bg-surface-800 border border-white/10 text-xs font-mono text-slate-200 hover:bg-surface-700"
          >
            {playback.speed.toFixed(2).replace(/\.00$/, ".0")}x
          </button>

          {captureMode === "dual_mix" ? (
            <div className="flex items-center gap-2 text-xs text-slate-400">
              <label className="flex items-center gap-1" title="回放音量">
                <span>对方</span>
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.05}
                  value={playback.systemVolume}
                  onChange={(e) =>
                    setTrackVolumes(Number(e.target.value), playback.micVolume)
                  }
                  className="w-16 accent-brand-500"
                />
              </label>
              <label className="flex items-center gap-1" title="麦克风音轨音量">
                <span>我</span>
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.05}
                  value={playback.micVolume}
                  onChange={(e) =>
                    setTrackVolumes(
                      playback.systemVolume,
                      Number(e.target.value)
                    )
                  }
                  className="w-16 accent-emerald-400"
                />
              </label>
            </div>
          ) : (
            <div className="flex items-center gap-1.5 text-slate-400">
              <Volume2 className="w-4 h-4" />
              <input
                type="range"
                min={0}
                max={1}
                step={0.05}
                value={playback.systemVolume}
                onChange={(e) =>
                  setTrackVolumes(Number(e.target.value), playback.micVolume)
                }
                className="w-20 accent-brand-500"
              />
            </div>
          )}
        </div>
      ) : (
        <div
          className="flex items-center gap-1.5 rounded-lg bg-surface-800 border border-white/10 px-2.5 py-1.5 shrink-0"
          title="选择实时录音的收音来源（双路混合 / 仅麦克风 / 仅系统内录）"
        >
          <Headphones className="w-3.5 h-3.5 text-brand-400 shrink-0" />
          <select
            value={captureMode}
            onChange={(e) =>
              void setCaptureMode(e.target.value as AudioCaptureMode)
            }
            className="bg-transparent text-xs text-slate-200 focus:outline-none max-w-[180px] cursor-pointer"
          >
            {audioSources.map((src) => (
              <option key={src.id} value={src.kind} className="bg-surface-900">
                {src.label}
              </option>
            ))}
          </select>
        </div>
      )}
    </div>
  );
}
