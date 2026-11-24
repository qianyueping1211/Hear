import { useEffect, useMemo, useState } from "react";
import {
  Copy,
  EyeOff,
  Languages,
  Lock,
  Mic,
  MicOff,
  PanelTop,
  ShieldCheck,
  Volume2,
  VolumeX,
} from "lucide-react";
import { findActiveSegmentIndex } from "../../lib/export";
import { useHearStore } from "../../stores/useHearStore";
import type { SubtitleStyle } from "../../types/hear";

/** 将 #RRGGBB 与透明度转为 rgba()，并计算是否属于浅色背景以自适应文字对比度 */
function parseHexBackground(hex: string, opacity: number): {
  rgba: string;
  isLight: boolean;
} {
  const clean = (hex || "#0b0f17").replace("#", "").trim();
  const valid = /^[0-9a-fA-F]{6}$/.test(clean) ? clean : "0b0f17";
  const r = parseInt(valid.slice(0, 2), 16);
  const g = parseInt(valid.slice(2, 4), 16);
  const b = parseInt(valid.slice(4, 6), 16);
  const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return {
    rgba: `rgba(${r}, ${g}, ${b}, ${opacity})`,
    isLight: luminance > 0.65 && opacity >= 0.45,
  };
}

export function SubtitleApp() {
  const {
    mode,
    segments,
    livePartialSource,
    livePartialTranslation,
    subtitleStyle,
    ttsSettings,
    playback,
    hydrate,
    toggleRecording,
    updateSubtitleStyle,
    updateTtsSettings,
  } = useHearStore();

  const [hovered, setHovered] = useState(false);
  const [fadedOut, setFadedOut] = useState(false);

  useEffect(() => {
    void hydrate();
  }, [hydrate]);

  // 静音自动淡出：当 subtitleStyle.autoFadeSeconds > 0 时，连续 N 秒无新字幕更新则平滑淡出，有新字幕或悬停时立刻恢复显示
  const latestActivityKey = useMemo(() => {
    const last = segments[segments.length - 1];
    return `${last?.id ?? ""}|${last?.translatedText ?? ""}|${livePartialSource}|${livePartialTranslation}|${playback.isPlaying ? Math.floor(playback.positionMs / 500) : 0}`;
  }, [segments, livePartialSource, livePartialTranslation, playback.isPlaying, playback.positionMs]);

  useEffect(() => {
    setFadedOut(false);
    const sec = subtitleStyle.autoFadeSeconds;
    if (!sec || sec <= 0 || hovered) return;
    const timer = window.setTimeout(() => {
      setFadedOut(true);
    }, sec * 1000);
    return () => window.clearTimeout(timer);
  }, [latestActivityKey, subtitleStyle.autoFadeSeconds, hovered]);

  const bg = useMemo(
    () =>
      parseHexBackground(
        subtitleStyle.backgroundColor,
        subtitleStyle.backgroundOpacity
      ),
    [subtitleStyle.backgroundColor, subtitleStyle.backgroundOpacity]
  );

  // 录音中展示最新 N 条 + 实时预览；回放录音时联动展示当前播放位置对应的句子
  const displayedLines = useMemo(() => {
    if (
      mode !== "recording" &&
      subtitleStyle.syncWithPlayback &&
      playback.hasAudio &&
      segments.length > 0
    ) {
      const activeIdx = findActiveSegmentIndex(segments, playback.positionMs);
      if (activeIdx >= 0) {
        const start = Math.max(0, activeIdx - subtitleStyle.maxLines + 1);
        return segments.slice(start, activeIdx + 1).map((s) => ({
          id: s.id,
          source: s.sourceText,
          translation: s.translatedText,
          speaker: s.speakerLabel,
          isPreview: false,
        }));
      }
    }

    const tail = segments.slice(-subtitleStyle.maxLines).map((s) => ({
      id: s.id,
      source: s.sourceText,
      translation: s.translatedText,
      speaker: s.speakerLabel,
      isPreview: false,
    }));

    if (livePartialSource || livePartialTranslation) {
      tail.push({
        id: "__live_partial__",
        source: livePartialSource,
        translation: livePartialTranslation || "…",
        speaker: undefined,
        isPreview: true,
      });
    }
    return tail.slice(-subtitleStyle.maxLines);
  }, [
    mode,
    segments,
    livePartialSource,
    livePartialTranslation,
    subtitleStyle.maxLines,
    subtitleStyle.syncWithPlayback,
    playback.hasAudio,
    playback.positionMs,
  ]);

  const cycleLayout = () => {
    const order: SubtitleStyle["layout"][] = [
      "bilingual",
      "translation_focus",
      "translation_only",
    ];
    const next = order[(order.indexOf(subtitleStyle.layout) + 1) % order.length];
    void updateSubtitleStyle({ layout: next });
  };

  const copyLatest = () => {
    const last = displayedLines[displayedLines.length - 1];
    if (!last) return;
    const text = last.translation || last.source;
    void navigator.clipboard?.writeText(text);
  };

  const strokeClass = subtitleStyle.textStroke && !bg.isLight ? "subtitle-stroke" : "";
  const primaryTextClass = bg.isLight ? "text-slate-900" : "text-white";
  const secondaryTextClass = bg.isLight ? "text-slate-700" : "text-slate-200/85";
  const borderClass = bg.isLight ? "border-slate-900/15" : "border-white/10";

  return (
    <div
      data-tauri-drag-region={!subtitleStyle.clickThrough ? "" : undefined}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{ backgroundColor: bg.rgba, opacity: fadedOut && !hovered ? 0 : 1 }}
      className={`relative h-full w-full rounded-2xl border ${borderClass} backdrop-blur-md px-5 py-3 flex flex-col justify-center transition-all duration-500`}
    >
      {/* 悬停迷你工具栏（穿透锁定时不拦截鼠标） */}
      {!subtitleStyle.clickThrough && (
        <div
          className={`absolute top-2 right-3 flex items-center gap-1.5 rounded-lg bg-slate-900/90 border border-white/10 px-2 py-1 text-xs text-slate-200 transition-opacity duration-150 ${
            hovered ? "opacity-100" : "opacity-0 pointer-events-none"
          }`}
        >
          {subtitleStyle.excludeFromCapture && (
            <span
              title="防录屏/防共享已开启（会议共享画面中对方不可见）"
              className="flex items-center gap-1 text-emerald-400 pr-1 border-r border-white/10"
            >
              <ShieldCheck className="w-3.5 h-3.5" />
            </span>
          )}
          <button
            onClick={() => void toggleRecording()}
            title="开始/暂停录音 (Ctrl+Shift+H)"
            className="p-1 rounded hover:bg-white/10"
          >
            {mode === "recording" ? (
              <Mic className="w-3.5 h-3.5 text-rose-400" />
            ) : (
              <MicOff className="w-3.5 h-3.5 text-slate-400" />
            )}
          </button>
          <button
            onClick={() => {
              const nextEnabled = !ttsSettings.enabled;
              if (nextEnabled && !ttsSettings.autoSpeakMyMic && !ttsSettings.autoSpeakOther) {
                void updateTtsSettings({
                  enabled: true,
                  autoSpeakMyMic: true,
                  autoSpeakOther: true,
                });
              } else {
                void updateTtsSettings({ enabled: nextEnabled });
              }
            }}
            title={ttsSettings.enabled ? "关闭自动朗读译文" : "开启自动朗读译文"}
            className="p-1 rounded hover:bg-white/10"
          >
            {ttsSettings.enabled ? (
              <Volume2 className="w-3.5 h-3.5 text-emerald-400" />
            ) : (
              <VolumeX className="w-3.5 h-3.5 text-slate-400" />
            )}
          </button>
          <button
            onClick={cycleLayout}
            title="切换双语 / 译文优先 / 仅译文 (Ctrl+Shift+B)"
            className="p-1 rounded hover:bg-white/10"
          >
            <Languages className="w-3.5 h-3.5" />
          </button>
          <button
            onClick={() => void updateSubtitleStyle({ clickThrough: true })}
            title="锁定鼠标穿透 (Ctrl+Shift+L 解锁)"
            className="p-1 rounded hover:bg-white/10"
          >
            <Lock className="w-3.5 h-3.5" />
          </button>
          <button
            onClick={copyLatest}
            title="复制最新一句 (Ctrl+Shift+C)"
            className="p-1 rounded hover:bg-white/10"
          >
            <Copy className="w-3.5 h-3.5" />
          </button>
          <button
            onClick={() => void updateSubtitleStyle({ visible: false })}
            title="隐藏悬浮字幕 (Ctrl+Shift+S)"
            className="p-1 rounded hover:bg-white/10"
          >
            <EyeOff className="w-3.5 h-3.5" />
          </button>
        </div>
      )}

      {/* 字幕内容 */}
      {displayedLines.length === 0 ? (
        <div
          data-tauri-drag-region
          className={`flex items-center justify-center gap-2 text-sm ${secondaryTextClass} ${strokeClass}`}
        >
          <PanelTop className="w-4 h-4" />
          <span>
            {mode === "recording"
              ? "正在聆听语音，等待断句出字幕…"
              : "听见悬浮字幕就绪 — 按 Ctrl+Shift+H 开始实时翻译"}
          </span>
        </div>
      ) : (
        <div className="space-y-2 overflow-hidden">
          {displayedLines.map((line) => (
            <div
              key={line.id}
              className={`leading-snug ${line.isPreview ? "opacity-75 italic" : ""}`}
            >
              {subtitleStyle.layout !== "translation_only" && line.source && (
                <div
                  style={{
                    fontSize:
                      subtitleStyle.layout === "translation_focus"
                        ? Math.max(12, Math.round(subtitleStyle.fontSize * 0.72))
                        : Math.max(13, Math.round(subtitleStyle.fontSize * 0.82)),
                  }}
                  className={`${secondaryTextClass} ${strokeClass}`}
                >
                  {line.speaker && (
                    <span className="mr-1.5 px-1.5 py-0.5 rounded bg-black/20 text-[11px] not-italic text-sky-400">
                      {line.speaker}
                    </span>
                  )}
                  {line.source}
                </div>
              )}
              <div
                style={{ fontSize: subtitleStyle.fontSize }}
                className={`font-semibold ${primaryTextClass} ${strokeClass}`}
              >
                {line.translation}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
