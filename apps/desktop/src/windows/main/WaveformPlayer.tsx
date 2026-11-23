import { useEffect, useRef, useState } from "react";
import { Pause, Play, RotateCcw, RotateCw, Volume2 } from "lucide-react";
import { formatTimestamp } from "../../lib/export";
import { useHearStore } from "../../stores/useHearStore";

const SPEEDS = [0.75, 1.0, 1.25, 1.5, 2.0];

export function WaveformPlayer() {
  const {
    captureMode,
    playback,
    seekNonce,
    seekTargetMs,
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
  const [audioUrl, setAudioUrl] = useState<string | null>(null);

  // 录音文件就绪或切换时从 Rust 后端加载真实 WAV 字节并绑定到 HTMLAudioElement
  useEffect(() => {
    let revoked = false;
    let objectUrl: string | null = null;
    if (!playback.hasAudio || !playback.audioPath) {
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
  }, [playback.hasAudio, playback.audioPath, readRecordingAudio]);

  // 响应显式跳转请求（点波形、点字幕句子、快退/快进）
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio || !audioUrl || seekNonce === 0) return;
    audio.currentTime = Math.max(0, seekTargetMs / 1000);
    if (playback.isPlaying) {
      void audio.play().catch(() => {});
    }
  }, [seekNonce, seekTargetMs, audioUrl, playback.isPlaying]);

  // 同步播放/暂停、倍速与音量
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;
    audio.playbackRate = playback.speed;
    audio.volume = Math.max(0, Math.min(1, playback.systemVolume));
  }, [playback.speed, playback.systemVolume, audioUrl]);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio || !audioUrl) return;
    if (playback.isPlaying) {
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

    const peaks = playback.peaks.length > 0 ? playback.peaks : new Array(80).fill(0.08);
    const barCount = Math.min(peaks.length, Math.max(40, Math.floor(width / 4)));
    const barW = width / barCount;
    const progress =
      playback.durationMs > 0
        ? Math.max(0, Math.min(1, playback.positionMs / playback.durationMs))
        : 0;

    for (let i = 0; i < barCount; i++) {
      const srcIdx = Math.floor((i / barCount) * peaks.length);
      const amp = Math.max(0.08, Math.min(1, peaks[srcIdx] ?? 0.08));
      const barH = amp * (height - 6);
      const x = i * barW;
      const y = (height - barH) / 2;
      const ratio = i / barCount;
      ctx.fillStyle =
        ratio <= progress
          ? "#60a5fa"
          : "rgba(148, 163, 184, 0.28)";
      ctx.fillRect(x + 0.5, y, Math.max(1.5, barW - 1.5), barH);
    }

    // 播放指针
    const px = progress * width;
    ctx.fillStyle = "#f8fafc";
    ctx.fillRect(px - 1, 0, 2, height);
  }, [playback.peaks, playback.positionMs, playback.durationMs]);

  const handleCanvasClick = (e: React.MouseEvent<HTMLCanvasElement>) => {
    if (!playback.hasAudio || playback.durationMs <= 0) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
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
      {/* 播放控制 */}
      <div className="flex items-center gap-2 shrink-0">
        <button
          disabled={!playback.hasAudio}
          onClick={() => void seekPlayback(Math.max(0, playback.positionMs - 5000), playback.isPlaying)}
          title="快退 5 秒"
          className="p-2 rounded-lg text-slate-300 hover:bg-white/10 disabled:opacity-35"
        >
          <RotateCcw className="w-4 h-4" />
        </button>
        <button
          disabled={!playback.hasAudio}
          onClick={() => void togglePlayback()}
          title="播放 / 暂停完整录音"
          className="w-10 h-10 rounded-full bg-brand-500 hover:bg-brand-600 text-white flex items-center justify-center disabled:opacity-35 shadow"
        >
          {playback.isPlaying ? (
            <Pause className="w-4 h-4" />
          ) : (
            <Play className="w-4 h-4 ml-0.5" />
          )}
        </button>
        <button
          disabled={!playback.hasAudio}
          onClick={() =>
            void seekPlayback(
              Math.min(playback.durationMs, playback.positionMs + 5000),
              playback.isPlaying
            )
          }
          title="快进 5 秒"
          className="p-2 rounded-lg text-slate-300 hover:bg-white/10 disabled:opacity-35"
        >
          <RotateCw className="w-4 h-4" />
        </button>
      </div>

      {/* 时间 + 波形进度条 */}
      <div className="flex-1 flex flex-col gap-1 min-w-0">
        <div className="flex items-center justify-between text-xs text-slate-400 font-mono">
          <span>{formatTimestamp(playback.positionMs)}</span>
          <span className="text-[11px] font-sans text-slate-500">
            {playback.hasAudio
              ? "点击波形或任意字幕段落即可精准跳转录音位置"
              : "开始录音或拖入本地音视频后，可在此完整回听并双向联动"}
          </span>
          <span>{formatTimestamp(playback.durationMs)}</span>
        </div>
        <canvas
          ref={canvasRef}
          onClick={handleCanvasClick}
          className={`w-full h-9 rounded-md bg-surface-950/70 ${
            playback.hasAudio ? "cursor-pointer" : "opacity-50"
          }`}
        />
      </div>

      {/* 倍速 & 双轨音量 */}
      <div className="flex items-center gap-3 shrink-0">
        <button
          disabled={!playback.hasAudio}
          onClick={nextSpeed}
          className="px-2.5 py-1 rounded-md bg-surface-800 border border-white/10 text-xs font-mono text-slate-200 hover:bg-surface-700 disabled:opacity-35"
        >
          {playback.speed.toFixed(2).replace(/\.00$/, ".0")}x
        </button>

        {captureMode === "dual_mix" ? (
          <div className="flex items-center gap-2 text-xs text-slate-400">
            <label className="flex items-center gap-1" title="远端/系统声音轨音量">
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
            <label className="flex items-center gap-1" title="本机麦克风音轨音量">
              <span>我</span>
              <input
                type="range"
                min={0}
                max={1}
                step={0.05}
                value={playback.micVolume}
                onChange={(e) =>
                  setTrackVolumes(playback.systemVolume, Number(e.target.value))
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
    </div>
  );
}
