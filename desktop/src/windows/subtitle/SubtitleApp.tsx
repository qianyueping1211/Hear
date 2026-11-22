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
} from "lucide-react";
import { findActiveSegmentIndex } from "../../lib/export";
import { useHearStore } from "../../stores/useHearStore";
import type { SubtitleStyle } from "../../types/hear";

export function SubtitleApp() {
  const {
    mode,
    segments,
    livePartialSource,
    livePartialTranslation,
    subtitleStyle,
    playback,
    hydrate,
    toggleRecording,
    updateSubtitleStyle,
  } = useHearStore();

  const [hovered, setHovered] = useState(false);

  useEffect(() => {
    void hydrate();
  }, [hydrate]);

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

  const strokeClass = subtitleStyle.textStroke ? "subtitle-stroke" : "";

  return (
    <div
      data-tauri-drag-region={!subtitleStyle.clickThrough ? "" : undefined}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        backgroundColor: `rgba(11, 15, 23, ${subtitleStyle.backgroundOpacity})`,
      }}
      className="relative h-full w-full rounded-2xl border border-white/10 backdrop-blur-md px-5 py-3 flex flex-col justify-center transition-colors"
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
          className={`flex items-center justify-center gap-2 text-slate-300/75 text-sm ${strokeClass}`}
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
                  className={`text-slate-200/85 ${strokeClass}`}
                >
                  {line.speaker && (
                    <span className="mr-1.5 px-1.5 py-0.5 rounded bg-white/10 text-[11px] not-italic text-sky-300">
                      {line.speaker}
                    </span>
                  )}
                  {line.source}
                </div>
              )}
              <div
                style={{ fontSize: subtitleStyle.fontSize }}
                className={`font-semibold text-white ${strokeClass}`}
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
