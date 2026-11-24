import { useEffect, useMemo, useRef, useState } from "react";
import {
  AlertCircle,
  ArrowDownCircle,
  ArrowLeft,
  ArrowUpCircle,
  Calendar,
  Check,
  Clock,
  Copy,
  Download,
  FileAudio,
  History,
  Info,
  Loader2,
  Lock,
  Mic,
  Minus,
  PanelRight,
  PanelTop,
  Pencil,
  Play,
  RefreshCw,
  Search,
  Settings,
  Sparkles,
  Square,
  Trash2,
  Unlock,
  UserCheck,
  Volume2,
  Wand2,
  X,
} from "lucide-react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  buildMarkdown,
  buildSrt,
  findActiveSegmentIndex,
  formatTimestamp,
  parseSummaryTimestampMs,
} from "../../lib/export";
import { SUMMARY_TEMPLATES, useHearStore } from "../../stores/useHearStore";
import { SettingsModal } from "./SettingsModal";
import { WaveformPlayer } from "./WaveformPlayer";

const LANGUAGES = [
  { id: "zh", label: "中文" },
  { id: "en", label: "English" },
  { id: "ja", label: "日本語" },
  { id: "ko", label: "한국어" },
  { id: "fr", label: "Français" },
  { id: "de", label: "Deutsch" },
  { id: "es", label: "Español" },
];

/**
 * 与 iOS TranslationRevision.changes 保持完全一致的分词与 LCS 差异对比算法：
 * 英文按单词切分，中日韩按单字切分，找出终稿译文中相比初版译文新增/修正的片段并以高亮色标注。
 */
function tokenizeForDiff(text: string): string[] {
  const result: string[] = [];
  let word = "";
  for (const ch of text) {
    const code = ch.codePointAt(0) ?? 0;
    const isCjk =
      (code >= 0x3000 && code <= 0x9fff) || (code >= 0x20000 && code <= 0x323af);
    const isAlphaNum = /[\p{L}\p{N}]/u.test(ch);
    if (isAlphaNum && !isCjk) {
      word += ch;
    } else {
      if (word) {
        result.push(word);
        word = "";
      }
      result.push(ch);
    }
  }
  if (word) result.push(word);
  return result;
}

function computeTranslationDiff(
  previous: string,
  current: string
): { text: string; changed: boolean }[] {
  const prevTokens = tokenizeForDiff(previous);
  const currTokens = tokenizeForDiff(current);
  const m = prevTokens.length;
  const n = currTokens.length;
  if (m === 0 || n === 0 || m * n > 40_000) {
    return [{ text: current, changed: false }];
  }
  const dp: Uint16Array[] = Array.from(
    { length: m + 1 },
    () => new Uint16Array(n + 1)
  );
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      if (prevTokens[i] === currTokens[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = Math.max(dp[i + 1][j], dp[i][j + 1]);
      }
    }
  }
  const unchangedIdx = new Set<number>();
  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (prevTokens[i] === currTokens[j]) {
      unchangedIdx.add(j);
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  const out: { text: string; changed: boolean }[] = [];
  for (let k = 0; k < n; k++) {
    const tok = currTokens[k];
    const isWhitespace = /^\s+$/.test(tok);
    const changed = !unchangedIdx.has(k) && !isWhitespace;
    const last = out[out.length - 1];
    if (last && last.changed === changed) {
      last.text += tok;
    } else {
      out.push({ text: tok, changed });
    }
  }
  return out;
}

export function MainApp() {
  const {
    mode,
    sourceLang,
    targetLang,
    lockSourceLang,
    captureMode,
    sessionError,
    sessionNotice,
    speakingSegmentId,
    preparingCloneSegmentId,
    cloneStates,
    segments,
    livePartialSource,
    livePartialTranslation,
    subtitleStyle,
    serviceConfig,
    localStatus,
    cloudStatus,
    testingLocal,
    testingCloud,
    updateInfo,
    playback,
    ttsSettings,
    activeConversationId,
    conversations,
    viewMode,
    searchQuery,
    summaryOpen,
    summaryTemplateId,
    summaryMarkdown,
    summaryGenerating,
    importProgress,
    hydrate,
    clearSessionError,
    clearSessionNotice,
    setSearchQuery,
    setSummaryOpen,
    setSummaryTemplateId,
    backToHome,
    setSettingsOpen,
    loadConversation,
    renameConversation,
    deleteConversation,
    setLanguagePair,
    setCaptureMode,
    startRecording,
    clearRecording,
    seekPlayback,
    toggleSubtitleVisible,
    testServiceConnection,
    editSegmentSource,
    editSegmentSpeaker,
    playSegmentOriginal,
    speakSegment,
    updateTtsSettings,
    generateSummary,
    saveSummaryMarkdown,
    exportTextFile,
    importMediaFile,
    cancelImportMedia,
    exportRecordingWav,
  } = useHearStore();

  const [autoFollow, setAutoFollow] = useState(true);
  const [editingSummary, setEditingSummary] = useState(false);
  const [summaryDraft, setSummaryDraft] = useState("");
  const [summaryCopied, setSummaryCopied] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editSourceDraft, setEditSourceDraft] = useState("");
  const [editingSpeakerId, setEditingSpeakerId] = useState<string | null>(null);
  const [speakerDraft, setSpeakerDraft] = useState("");
  const [speakerApplyAll, setSpeakerApplyAll] = useState(true);
  const [historySearch, setHistorySearch] = useState("");
  const [renamingConvId, setRenamingConvId] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState("");
  const [isMaximized, setIsMaximized] = useState(false);
  const listRef = useRef<HTMLDivElement | null>(null);
  const itemRefs = useRef<Record<string, HTMLDivElement | null>>({});
  const clickTimerRef = useRef<number | null>(null);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    try {
      const win = getCurrentWindow();
      void win.isMaximized().then(setIsMaximized).catch(() => {});
      void win
        .onResized(() => {
          void win.isMaximized().then(setIsMaximized).catch(() => {});
        })
        .then((fn) => {
          unlisten = fn;
        })
        .catch(() => {});
    } catch {
      // non-Tauri preview
    }
    return () => {
      unlisten?.();
    };
  }, []);

  const handleWinMinimize = () => {
    try {
      void getCurrentWindow().minimize();
    } catch {}
  };
  const handleWinToggleMaximize = () => {
    try {
      const win = getCurrentWindow();
      void win.toggleMaximize().then(() => win.isMaximized().then(setIsMaximized));
    } catch {}
  };
  const handleWinClose = () => {
    try {
      void getCurrentWindow().close();
    } catch {}
  };

  const knownSpeakers = useMemo(() => {
    const set = new Set<string>(["我", "对方"]);
    for (const s of segments) {
      if (s.speakerLabel?.trim()) set.add(s.speakerLabel.trim());
    }
    return Array.from(set);
  }, [segments]);

  useEffect(() => {
    void hydrate();
  }, [hydrate]);

  // 汇总当前路由所用服务的连接与模型状态，显示在顶栏胶囊中
  const serviceBadge = useMemo(() => {
    const usesLocal =
      serviceConfig.asrSource === "local" || serviceConfig.mtSource === "local";
    const usesCloud =
      serviceConfig.asrSource === "cloud" || serviceConfig.mtSource === "cloud";
    const checking = (usesLocal && testingLocal) || (usesCloud && testingCloud);

    const routeLabel =
      usesLocal && usesCloud ? "混合服务" : usesCloud ? "云端服务" : "本机服务";

    const activeStatuses = [
      ...(usesLocal ? [localStatus] : []),
      ...(usesCloud ? [cloudStatus] : []),
    ];
    const anyTested = activeStatuses.some(
      (s) => Boolean(s.address || s.error || s.latencyMs > 0)
    );
    const allOk = anyTested && activeStatuses.every((s) => s.ok);
    const asrStatus =
      serviceConfig.asrSource === "local" ? localStatus : cloudStatus;
    const mtStatus =
      serviceConfig.mtSource === "local" ? localStatus : cloudStatus;

    let dotClass = "bg-slate-400";
    let statusText = `${routeLabel} · 未检测`;
    if (checking) {
      dotClass = "bg-amber-400 animate-pulse";
      statusText = `${routeLabel} · 检测中…`;
    } else if (allOk) {
      const modelsReady = asrStatus.asrReady && mtStatus.mtReady;
      dotClass = modelsReady ? "bg-emerald-400" : "bg-amber-400";
      statusText = modelsReady
        ? `${routeLabel} · 就绪`
        : `${routeLabel} · 已连(加载中)`;
    } else if (anyTested) {
      dotClass = "bg-rose-400";
      statusText = `${routeLabel} · 异常`;
    }

    const tooltip = [
      `识别(${serviceConfig.asrSource === "local" ? "本机" : "云端"})：${asrStatus.asrDetail}`,
      `翻译(${serviceConfig.mtSource === "local" ? "本机" : "云端"})：${mtStatus.mtDetail}`,
    ].join(" | ");

    return { dotClass, statusText, tooltip, usesLocal, usesCloud, checking };
  }, [serviceConfig, localStatus, cloudStatus, testingLocal, testingCloud]);

  const handleQuickRefresh = async (e: React.MouseEvent) => {
    e.stopPropagation();
    const tasks: Promise<unknown>[] = [];
    if (serviceBadge.usesLocal && serviceConfig.localServiceAddress.trim()) {
      tasks.push(testServiceConnection("local"));
    }
    if (serviceBadge.usesCloud && serviceConfig.cloudServiceAddress.trim()) {
      tasks.push(testServiceConnection("cloud"));
    }
    if (tasks.length === 0) {
      setSettingsOpen(true, "server");
      return;
    }
    await Promise.all(tasks);
  };

  const filteredSegments = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    if (!q) return segments;
    return segments.filter(
      (s) =>
        s.sourceText.toLowerCase().includes(q) ||
        s.translatedText.toLowerCase().includes(q) ||
        (s.speakerLabel ?? "").toLowerCase().includes(q)
    );
  }, [segments, searchQuery]);

  const activeIdx = useMemo(() => {
    if (!playback.hasAudio) return -1;
    return findActiveSegmentIndex(segments, playback.positionMs);
  }, [segments, playback.hasAudio, playback.positionMs]);

  const activeSegmentId = activeIdx >= 0 ? segments[activeIdx]?.id : null;

  useEffect(() => {
    if (!autoFollow) return;
    if (activeSegmentId && playback.isPlaying) {
      itemRefs.current[activeSegmentId]?.scrollIntoView({
        behavior: "smooth",
        block: "center",
      });
    } else if (mode === "recording" && listRef.current) {
      listRef.current.scrollTop = listRef.current.scrollHeight;
    }
  }, [
    activeSegmentId,
    playback.isPlaying,
    mode,
    segments.length,
    livePartialTranslation,
    autoFollow,
  ]);

  const exportBaseFilename = () => {
    const meta = conversations.find((c) => c.id === activeConversationId);
    const raw = (meta?.title || "听见会议记录")
      .replace(/[\\/:*?"<>|]/g, "_")
      .trim()
      .slice(0, 48);
    return raw || "听见会议记录";
  };

  const renderSummaryWithAnchors = (text: string) => {
    const lines = text.split("\n");
    return lines.map((line, lineIdx) => {
      const parts = line.split(/(\[\d{1,2}:\d{2}(?::\d{2})?\])/g);
      return (
        <p key={lineIdx} className="leading-relaxed mb-1.5 text-xs text-slate-200">
          {parts.map((part, idx) => {
            const match = part.match(/^\[(\d{1,2}:\d{2}(?::\d{2})?)\]$/);
            if (!match) return <span key={idx}>{part}</span>;
            const ms = parseSummaryTimestampMs(match[1]);
            if (ms === null) return <span key={idx}>{part}</span>;
            return (
              <button
                key={idx}
                onClick={() => void seekPlayback(ms, true)}
                className="mx-0.5 px-1.5 py-0.5 rounded bg-brand-500/20 text-brand-400 hover:bg-brand-500/35 font-mono text-[11px]"
                title={`跳转到录音 ${match[1]}`}
              >
                {part}
              </button>
            );
          })}
        </p>
      );
    });
  };

  const currentConvTitle = useMemo(() => {
    const found = (conversations ?? []).find((c) => c.id === activeConversationId);
    if (found?.title) return found.title;
    if (mode === "recording") return "正在实时录音…";
    if (mode === "paused") return "录音已暂停";
    return "当前录音对话";
  }, [conversations, activeConversationId, mode]);

  const toolbarButtons = (
    <div className="flex items-center gap-2 shrink-0">
      {updateInfo?.hasUpdate && (
        <button
          onClick={() => setSettingsOpen(true, "system")}
          title={`发现新版本 v${updateInfo.latestVersion}，点击查看更新说明并一键更新`}
          className="h-9 px-3 rounded-lg bg-emerald-500/20 border border-emerald-400/40 text-emerald-300 hover:bg-emerald-500/30 text-xs inline-flex items-center gap-1.5"
        >
          <ArrowUpCircle className="w-3.5 h-3.5" />
          <span>新版本 v{updateInfo.latestVersion}</span>
        </button>
      )}

      {/* 声音克隆前面的「自动朗读译文」快捷开关 */}
      <button
        type="button"
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
        title={
          ttsSettings.enabled
            ? "自动朗读译文已开启（点击关闭）"
            : "自动朗读译文已关闭（点击开启）"
        }
        className={`h-9 px-2.5 rounded-lg border text-xs inline-flex items-center gap-1.5 transition ${
          ttsSettings.enabled
            ? "bg-emerald-500/20 border-emerald-400/40 text-emerald-300 hover:bg-emerald-500/30"
            : "bg-surface-800 border-white/10 text-slate-400 hover:text-white hover:bg-white/5"
        }`}
      >
        <Volume2 className="w-3.5 h-3.5" />
        <span>自动朗读译文</span>
      </button>

      {/* 语言转换前面的「声音克隆」快捷开关（开/关 + 面对面/会议同传模式切换） */}
      <div className="h-9 inline-flex items-center rounded-lg border border-white/10 bg-surface-800 overflow-hidden text-xs">
        <button
          type="button"
          onClick={() =>
            void updateTtsSettings({
              useVoiceClone: !ttsSettings.useVoiceClone,
            })
          }
          title={
            ttsSettings.useVoiceClone
              ? "声音克隆已开启（点击关闭）"
              : "声音克隆已关闭（点击开启）"
          }
          className={`h-full px-2.5 inline-flex items-center gap-1.5 transition ${
            ttsSettings.useVoiceClone
              ? "bg-brand-500/25 text-brand-300 hover:bg-brand-500/35"
              : "text-slate-400 hover:text-white hover:bg-white/5"
          }`}
        >
          <Volume2 className="w-3.5 h-3.5" />
          <span>声音克隆</span>
        </button>
        {ttsSettings.useVoiceClone && (
          <button
            type="button"
            onClick={() => {
              const nextMode =
                ttsSettings.routingMode === "meeting" ? "face_to_face" : "meeting";
              if (
                nextMode === "meeting" &&
                !ttsSettings.meetingMicOutputDeviceId
              ) {
                void updateTtsSettings({ routingMode: nextMode });
                setSettingsOpen(true, "audio");
              } else {
                void updateTtsSettings({ routingMode: nextMode });
              }
            }}
            title={
              ttsSettings.routingMode === "meeting"
                ? "当前：会议同传模式（我的克隆译文送到虚拟麦克风，对方译文送到耳机；点击切回面对面）"
                : "当前：面对面模式（播报克隆译文给身边人听并自动静音麦防回声；点击切换到会议同传）"
            }
            className={`h-full px-2 border-l border-white/10 text-[11px] font-medium transition ${
              ttsSettings.routingMode === "meeting"
                ? "bg-emerald-500/20 text-emerald-300 hover:bg-emerald-500/30"
                : "text-slate-300 hover:text-white hover:bg-white/5"
            }`}
          >
            {ttsSettings.routingMode === "meeting" ? "会议同传" : "面对面"}
          </button>
        )}
      </div>

      <div className="h-9 flex items-center gap-1 rounded-lg bg-surface-800 border border-white/10 px-2.5 text-xs">
        <select
          value={sourceLang}
          onChange={(e) => void setLanguagePair(e.target.value, targetLang, lockSourceLang)}
          className="bg-transparent text-slate-100 focus:outline-none cursor-pointer"
        >
          {LANGUAGES.map((l) => (
            <option key={l.id} value={l.id} className="bg-surface-900">
              {l.label}
            </option>
          ))}
        </select>
        <span className="text-slate-500 px-0.5">{lockSourceLang ? "→" : "⇄"}</span>
        <select
          value={targetLang}
          onChange={(e) => void setLanguagePair(sourceLang, e.target.value, lockSourceLang)}
          className="bg-transparent text-slate-100 focus:outline-none cursor-pointer"
        >
          {LANGUAGES.map((l) => (
            <option key={l.id} value={l.id} className="bg-surface-900">
              {l.label}
            </option>
          ))}
        </select>
        <button
          onClick={() => void setLanguagePair(sourceLang, targetLang, !lockSourceLang)}
          title={lockSourceLang ? "已锁定源语种（单向翻译，纯外语视频更稳更快）" : "自动双向判别语种"}
          className={`ml-1 p-1 rounded ${
            lockSourceLang ? "text-amber-300 bg-amber-500/15" : "text-slate-400 hover:text-white"
          }`}
        >
          {lockSourceLang ? <Lock className="w-3 h-3" /> : <Unlock className="w-3 h-3" />}
        </button>
      </div>

      <div
        onClick={() => setSettingsOpen(true, "server")}
        title={serviceBadge.tooltip}
        className="h-9 px-3 rounded-lg bg-surface-800 border border-white/10 hover:bg-surface-700 text-xs inline-flex items-center gap-1.5 cursor-pointer"
      >
        <span className={`w-2 h-2 rounded-full ${serviceBadge.dotClass}`} />
        <span>{serviceBadge.statusText}</span>
        <button
          type="button"
          onClick={(e) => void handleQuickRefresh(e)}
          title="刷新服务状态"
          className="ml-0.5 p-0.5 rounded hover:bg-white/10 text-slate-400 hover:text-white"
        >
          <RefreshCw
            className={`w-3 h-3 ${serviceBadge.checking ? "animate-spin" : ""}`}
          />
        </button>
      </div>

      <button
        onClick={() => void toggleSubtitleVisible()}
        title="显示 / 隐藏悬浮字幕窗 (Ctrl+Shift+S)"
        className={`h-9 w-9 rounded-lg border inline-flex items-center justify-center ${
          subtitleStyle.visible
            ? "bg-brand-500/20 border-brand-500/40 text-brand-400"
            : "bg-surface-800 border-white/10 text-slate-400 hover:text-white"
        }`}
      >
        <PanelTop className="w-4 h-4" />
      </button>

      {viewMode === "workspace" && (
        <button
          onClick={() => setSummaryOpen(!summaryOpen)}
          title="展开 / 收起一键总结面板"
          className={`h-9 w-9 rounded-lg border inline-flex items-center justify-center ${
            summaryOpen
              ? "bg-purple-500/20 border-purple-500/40 text-purple-300"
              : "bg-surface-800 border-white/10 text-slate-400 hover:text-white"
          }`}
        >
          <PanelRight className="w-4 h-4" />
        </button>
      )}

      <button
        onClick={() => setSettingsOpen(true)}
        title="模型服务、悬浮字幕样式与音频设置"
        className="h-9 w-9 rounded-lg bg-surface-800 border border-white/10 text-slate-300 hover:text-white inline-flex items-center justify-center"
      >
        <Settings className="w-4 h-4" />
      </button>
    </div>
  );

  return (
    <div className="h-screen w-screen flex flex-col bg-surface-950 text-slate-100">
      {/* 最顶部窗口标题栏（48px 舒展高度）：仅放应用标识与最小化/最大化/关闭按钮 */}
      <header
        data-tauri-drag-region
        onDoubleClick={(e) => {
          if ((e.target as HTMLElement).closest("button, select, input")) return;
          handleWinToggleMaximize();
        }}
        className="h-12 border-b border-white/5 bg-surface-900/95 pl-5 pr-2 flex items-center justify-between gap-4 shrink-0 select-none"
      >
        <div
          data-tauri-drag-region
          className="flex items-center gap-2.5 min-w-0 flex-1 h-full"
        >
          <div
            data-tauri-drag-region
            className="w-6 h-6 rounded-md bg-gradient-to-br from-emerald-400 to-brand-500 flex items-center justify-center text-[12px] font-bold text-white shadow-sm"
          >
            听
          </div>
          <span
            data-tauri-drag-region
            className="text-sm font-semibold text-slate-100 tracking-wide"
          >
            听见 Hear
          </span>
        </div>

        {/* 右上角窗口控制按钮（高 40px、宽 44px） */}
        <div className="flex items-center gap-0.5 shrink-0">
          <button
            type="button"
            onClick={handleWinMinimize}
            title="最小化"
            className="h-10 w-11 rounded-lg text-slate-300 hover:text-white hover:bg-white/10 inline-flex items-center justify-center transition"
          >
            <Minus className="w-4 h-4" />
          </button>
          <button
            type="button"
            onClick={handleWinToggleMaximize}
            title={isMaximized ? "还原窗口" : "最大化"}
            className="h-10 w-11 rounded-lg text-slate-300 hover:text-white hover:bg-white/10 inline-flex items-center justify-center transition"
          >
            {isMaximized ? (
              <Copy className="w-3.5 h-3.5" />
            ) : (
              <Square className="w-3.5 h-3.5" />
            )}
          </button>
          <button
            type="button"
            onClick={handleWinClose}
            title="关闭"
            className="h-10 w-11 rounded-lg text-slate-300 hover:text-white hover:bg-rose-500/85 inline-flex items-center justify-center transition"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      </header>

      {viewMode === "home" ? (
        /* 默认主页：右上角 4 个功能按钮与下方 3 张快捷卡片、最近文件共用同一内容区域 */
        <div className="flex-1 overflow-y-auto px-8 pt-4 pb-7">
          <div className="max-w-5xl mx-auto space-y-6">
            <div className="flex items-center justify-end">
              {toolbarButtons}
            </div>
            {sessionError && (
              <div className="rounded-xl bg-rose-500/15 border border-rose-400/40 px-4 py-2.5 flex items-center justify-between gap-3 text-xs text-rose-200">
                <div className="flex items-center gap-2 min-w-0">
                  <AlertCircle className="w-4 h-4 text-rose-400 shrink-0" />
                  <span className="break-all leading-relaxed">{sessionError}</span>
                </div>
                <button
                  type="button"
                  onClick={clearSessionError}
                  className="p-1 rounded hover:bg-white/10 text-rose-300"
                >
                  <X className="w-3.5 h-3.5" />
                </button>
              </div>
            )}

            {/* 顶部 3 大快捷入口卡片 */}
            <div className="grid grid-cols-3 gap-5">
              {/* 1. 开始录音 */}
              <button
                type="button"
                onClick={() => void startRecording(true)}
                className="group relative h-28 rounded-2xl bg-gradient-to-br from-slate-800 via-slate-900 to-slate-950 border border-brand-500/35 hover:border-brand-400 shadow-lg hover:shadow-brand-500/15 px-6 flex items-center justify-between overflow-hidden text-left transition"
              >
                <div className="z-10 space-y-1">
                  <div className="text-base font-semibold text-white group-hover:text-brand-200 transition">
                    开始录音
                  </div>
                  <div className="text-[11px] text-slate-400">
                    实时识别与双语翻译
                  </div>
                </div>
                <div className="relative w-28 h-20 rounded-xl bg-white/5 border border-white/10 -mr-2 translate-y-2 rotate-[-4deg] group-hover:rotate-0 transition flex items-center px-3">
                  <div className="w-9 h-9 rounded-full bg-brand-500 shadow-md shadow-brand-500/40 flex items-center justify-center text-white">
                    <Mic className="w-4 h-4" />
                  </div>
                  <div className="ml-2.5 flex-1 space-y-1.5">
                    <div className="h-1.5 w-10 rounded-full bg-white/30" />
                    <div className="h-1.5 w-7 rounded-full bg-white/15" />
                  </div>
                </div>
              </button>

              {/* 2. 导入文件 */}
              <button
                type="button"
                disabled={mode === "batch_processing"}
                onClick={() => void importMediaFile()}
                className="group relative h-28 rounded-2xl bg-surface-900/90 hover:bg-surface-800/90 border border-white/10 hover:border-sky-400/40 shadow px-6 flex items-center justify-between overflow-hidden text-left transition disabled:opacity-50"
              >
                <div className="z-10 space-y-1">
                  <div className="text-base font-semibold text-slate-100 group-hover:text-white transition">
                    导入文件
                  </div>
                  <div className="text-[11px] text-slate-400">
                    音视频转写与会议纪要
                  </div>
                </div>
                <div className="relative w-28 h-20 rounded-xl bg-surface-800/90 border border-white/10 -mr-2 translate-y-2 rotate-[-3deg] group-hover:rotate-0 transition flex items-center px-3">
                  <div className="w-8 h-8 rounded-lg bg-sky-500/20 border border-sky-400/30 flex items-center justify-center text-sky-400">
                    <FileAudio className="w-4 h-4" />
                  </div>
                  <div className="ml-2.5 flex-1 space-y-1.5">
                    <div className="h-1.5 w-11 rounded-full bg-slate-600" />
                    <div className="h-1.5 w-8 rounded-full bg-slate-700" />
                  </div>
                </div>
              </button>

              {/* 3. 悬浮字幕 */}
              <button
                type="button"
                onClick={() => void toggleSubtitleVisible()}
                className={`group relative h-28 rounded-2xl border shadow px-6 flex items-center justify-between overflow-hidden text-left transition ${
                  subtitleStyle.visible
                    ? "bg-brand-500/15 border-brand-400/50"
                    : "bg-surface-900/90 hover:bg-surface-800/90 border-white/10 hover:border-brand-400/40"
                }`}
              >
                <div className="z-10 space-y-1">
                  <div className="flex items-center gap-2">
                    <span className="text-base font-semibold text-slate-100 group-hover:text-white transition">
                      悬浮字幕
                    </span>
                    {subtitleStyle.visible && (
                      <span className="px-1.5 py-0.5 rounded-full bg-brand-500/30 text-brand-200 text-[10px]">
                        已开启
                      </span>
                    )}
                  </div>
                  <div className="text-[11px] text-slate-400">
                    {subtitleStyle.visible ? "点击隐藏桌面同传字幕" : "桌面置顶双语同传字幕"}
                  </div>
                </div>
                <div className="relative w-28 h-20 rounded-xl bg-surface-800/90 border border-white/10 -mr-2 translate-y-2 rotate-[-3deg] group-hover:rotate-0 transition flex flex-col justify-center px-3 space-y-1.5">
                  <div className="flex items-center gap-1.5">
                    <span className="w-2 h-1.5 rounded-full bg-brand-400" />
                    <span className="h-1.5 w-14 rounded-full bg-slate-500" />
                  </div>
                  <div className="flex items-center gap-1.5">
                    <span className="w-2 h-1.5 rounded-full bg-emerald-400" />
                    <span className="h-1.5 w-10 rounded-full bg-slate-600" />
                  </div>
                </div>
              </button>
            </div>

            {/* 下方：最近文件列表 */}
            <div className="space-y-4">
              <div className="flex items-center justify-between gap-4">
                <div className="flex items-center gap-2">
                  <h2 className="text-sm font-semibold text-slate-300">最近文件</h2>
                  {(conversations?.length ?? 0) > 0 && (
                    <span className="px-2 py-0.5 rounded-full bg-surface-800 border border-white/10 text-[11px] text-slate-400">
                      {conversations?.length}
                    </span>
                  )}
                </div>
                <div className="relative w-72">
                  <Search className="w-3.5 h-3.5 text-slate-500 absolute left-3 top-1/2 -translate-y-1/2" />
                  <input
                    type="text"
                    value={historySearch}
                    onChange={(e) => setHistorySearch(e.target.value)}
                    placeholder="搜索会议标题或内容摘要…"
                    className="w-full pl-8 pr-3 py-1.5 rounded-lg bg-surface-900 border border-white/10 text-xs text-slate-100 placeholder:text-slate-500 focus:outline-none focus:border-brand-500"
                  />
                </div>
              </div>

              <div className="space-y-3.5">
                {(conversations ?? [])
                  .filter((c) => {
                    const q = historySearch.trim().toLowerCase();
                    if (!q) return true;
                    return (
                      c.title.toLowerCase().includes(q) ||
                      c.preview.toLowerCase().includes(q)
                    );
                  })
                  .map((c) => {
                    const isRenaming = renamingConvId === c.id;
                    const dt = new Date(c.updatedAtMs);
                    const dateStr = `${String(dt.getMonth() + 1).padStart(2, "0")}-${String(
                      dt.getDate()
                    ).padStart(2, "0")} ${String(dt.getHours()).padStart(2, "0")}:${String(
                      dt.getMinutes()
                    ).padStart(2, "0")}`;
                    const durMs = c.durationMs ?? 0;
                    const durStr = formatTimestamp(durMs);

                    return (
                      <div
                        key={c.id}
                        onClick={() => {
                          if (!isRenaming) {
                            void loadConversation(c.id);
                          }
                        }}
                        className="group rounded-2xl bg-surface-900/85 hover:bg-surface-800/85 border border-white/10 hover:border-brand-400/40 p-5 flex items-center justify-between gap-6 cursor-pointer shadow-sm transition"
                      >
                        <div className="flex-1 min-w-0 space-y-2.5">
                          {isRenaming ? (
                            <div
                              className="flex items-center gap-2 max-w-lg"
                              onClick={(e) => e.stopPropagation()}
                            >
                              <input
                                value={renameDraft}
                                onChange={(e) => setRenameDraft(e.target.value)}
                                className="flex-1 rounded-lg bg-surface-950 border border-brand-500 px-3 py-1.5 text-sm text-white focus:outline-none"
                              />
                              <button
                                type="button"
                                onClick={() => {
                                  if (renameDraft.trim()) {
                                    void renameConversation(c.id, renameDraft.trim());
                                  }
                                  setRenamingConvId(null);
                                }}
                                className="px-3 py-1.5 rounded-lg bg-brand-500 text-white text-xs font-medium"
                              >
                                保存
                              </button>
                              <button
                                type="button"
                                onClick={() => setRenamingConvId(null)}
                                className="px-2.5 py-1.5 rounded-lg bg-surface-800 text-slate-300 text-xs"
                              >
                                取消
                              </button>
                            </div>
                          ) : (
                            <div className="flex items-center gap-2.5">
                              <h3 className="text-base font-bold text-white group-hover:text-brand-200 truncate transition">
                                {c.title}
                              </h3>
                              {c.hasSummary && (
                                <span className="px-2 py-0.5 rounded-md bg-purple-500/15 border border-purple-400/30 text-purple-300 text-[11px] shrink-0">
                                  已生成总结
                                </span>
                              )}
                            </div>
                          )}

                          <p className="text-xs text-slate-400 leading-relaxed line-clamp-2">
                            <span className="text-slate-600 font-serif mr-1">“</span>
                            {c.preview || "点击进入查看完整录音回放、双语转写字幕与会议总结纪要。"}
                          </p>

                          <div className="flex items-center justify-between gap-4 pt-0.5 text-xs text-slate-500">
                            <div className="flex items-center gap-4">
                              <span className="flex items-center gap-1 font-mono">
                                <Clock className="w-3.5 h-3.5 text-slate-500" />
                                {durStr}
                              </span>
                              <span className="flex items-center gap-1">
                                <Calendar className="w-3.5 h-3.5 text-slate-500" />
                                {dateStr} · 客户端
                              </span>
                              <span className="px-2 py-0.5 rounded bg-surface-800 text-slate-400 text-[11px]">
                                {c.langPair} · {c.segmentCount} 句
                              </span>
                            </div>

                            <div
                              className="flex items-center gap-1 opacity-0 group-hover:opacity-100 transition"
                              onClick={(e) => e.stopPropagation()}
                            >
                              <button
                                type="button"
                                onClick={() => {
                                  setRenamingConvId(c.id);
                                  setRenameDraft(c.title);
                                }}
                                title="重命名"
                                className="px-2 py-1 rounded hover:bg-white/10 text-slate-400 hover:text-white flex items-center gap-1"
                              >
                                <Pencil className="w-3.5 h-3.5" />
                                <span>重命名</span>
                              </button>
                              <button
                                type="button"
                                onClick={() => void deleteConversation(c.id)}
                                title="删除"
                                className="px-2 py-1 rounded hover:bg-rose-500/20 text-slate-400 hover:text-rose-300 flex items-center gap-1"
                              >
                                <Trash2 className="w-3.5 h-3.5" />
                                <span>删除</span>
                              </button>
                            </div>
                          </div>
                        </div>

                        {/* 右侧：缩略纪要卡片图示（对标参考图右侧叠层文档视觉） */}
                        <div className="relative w-24 h-20 shrink-0 hidden sm:flex items-center justify-center">
                          <div className="absolute w-16 h-20 rounded-xl bg-surface-800/70 border border-white/10 rotate-6 translate-x-1.5" />
                          <div className="relative w-16 h-20 rounded-xl bg-surface-800 border border-white/15 -rotate-3 p-2.5 flex flex-col justify-between shadow">
                            <div className="space-y-1">
                              <div className="h-1.5 w-8 rounded-full bg-brand-400/70" />
                              <div className="h-1 w-11 rounded-full bg-slate-500/60" />
                              <div className="h-1 w-9 rounded-full bg-slate-600/60" />
                              <div className="h-1 w-10 rounded-full bg-slate-600/50" />
                            </div>
                            <div className="flex items-center justify-between">
                              <span className="w-2 h-2 rounded-full bg-emerald-400/70" />
                              <span className="text-[9px] font-mono text-slate-400">
                                {c.hasSummary ? "AI 纪要" : "双语"}
                              </span>
                            </div>
                          </div>
                        </div>
                      </div>
                    );
                  })}

                {(conversations?.length ?? 0) === 0 && (
                  <div className="rounded-2xl border border-dashed border-white/10 bg-surface-900/40 py-16 px-6 text-center space-y-3">
                    <History className="w-9 h-9 text-slate-600 mx-auto" />
                    <div className="text-sm font-medium text-slate-300">
                      暂无最近录音或导入文件
                    </div>
                    <p className="text-xs text-slate-500 max-w-md mx-auto leading-relaxed">
                      点击上方「开始录音」启动实时语音识别与双语翻译，或点击「导入文件」转写本地音视频。每次录音与总结都会自动保存在此，点击即可进入左侧播放、右侧总结详情页。
                    </p>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      ) : (
        <>
          {/* 工作台顶部操作行（与下方内容共用同一区域）：左侧返回列表与标题，右侧 4+1 个功能按钮 */}
          <div className="px-5 pt-3 pb-2.5 border-b border-white/5 flex items-center justify-between gap-4 shrink-0">
            <div className="flex items-center gap-3 min-w-0">
              <button
                type="button"
                onClick={() => void backToHome()}
                title="返回历史记录主页"
                className="h-9 px-3 rounded-lg bg-surface-800 border border-white/10 hover:bg-surface-700 text-xs text-slate-200 inline-flex items-center gap-1.5 shrink-0"
              >
                <ArrowLeft className="w-3.5 h-3.5 text-brand-400" />
                <span>返回列表</span>
              </button>
              <span className="text-sm font-medium text-slate-200 truncate">
                {currentConvTitle}
              </span>
            </div>
            {toolbarButtons}
          </div>

          {/* 详情与录制工作台：左侧是播放与字幕，右侧是总结 */}
          <div className="flex-1 flex min-h-0 overflow-hidden">
        <main className="flex-1 flex flex-col min-w-0 relative">
          <div className="h-11 border-b border-white/5 px-4 flex items-center justify-between gap-3 bg-surface-950/60">
            <div className="relative flex-1 max-w-sm">
              <Search className="w-3.5 h-3.5 text-slate-500 absolute left-2.5 top-1/2 -translate-y-1/2" />
              <input
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="搜索原文、译文或说话人…"
                className="w-full pl-8 pr-3 py-1 rounded-md bg-surface-900 border border-white/10 text-xs text-slate-100 placeholder:text-slate-500 focus:outline-none focus:border-brand-500"
              />
            </div>

            <div className="flex items-center gap-1.5 text-xs">
              <button
                disabled={!playback.hasAudio}
                onClick={() => void exportRecordingWav()}
                title="导出当前会话的原始 WAV 录音文件"
                className="px-2.5 py-1 rounded-md bg-surface-900 border border-white/10 text-slate-300 hover:text-white disabled:opacity-35 flex items-center gap-1"
              >
                <FileAudio className="w-3.5 h-3.5 text-emerald-400" /> 导出 WAV
              </button>
              <button
                disabled={segments.length === 0}
                onClick={() =>
                  void exportTextFile(
                    `${exportBaseFilename()}.srt`,
                    "srt",
                    "SRT 双语字幕",
                    buildSrt(segments, true)
                  )
                }
                className="px-2.5 py-1 rounded-md bg-surface-900 border border-white/10 text-slate-300 hover:text-white disabled:opacity-35 flex items-center gap-1"
              >
                <Download className="w-3.5 h-3.5" /> 导出 SRT
              </button>
              <button
                disabled={segments.length === 0}
                onClick={() =>
                  void exportTextFile(
                    `${exportBaseFilename()}.md`,
                    "md",
                    "Markdown 会议纪要",
                    buildMarkdown(segments, summaryMarkdown)
                  )
                }
                className="px-2.5 py-1 rounded-md bg-surface-900 border border-white/10 text-slate-300 hover:text-white disabled:opacity-35 flex items-center gap-1"
              >
                <Download className="w-3.5 h-3.5" /> 导出 MD
              </button>
              <button
                disabled={segments.length === 0 && !playback.hasAudio}
                onClick={() => void clearRecording()}
                title="清空当前录音与字幕"
                className="p-1.5 rounded-md bg-surface-900 border border-white/10 text-slate-400 hover:text-rose-400 disabled:opacity-35"
              >
                <Trash2 className="w-3.5 h-3.5" />
              </button>
            </div>
          </div>

          {importProgress && importProgress.active && (
            <div className="mx-5 mt-3 rounded-xl bg-sky-500/15 border border-sky-400/40 px-4 py-2.5 flex items-center justify-between gap-4 text-xs text-sky-100">
              <div className="flex-1 min-w-0 space-y-1.5">
                <div className="flex items-center justify-between">
                  <span>
                    正在批量识别与翻译导入文件（{importProgress.current} /{" "}
                    {importProgress.total} 句）…
                  </span>
                  <span className="font-mono text-sky-300">
                    {Math.round(
                      (importProgress.current / Math.max(1, importProgress.total)) * 100
                    )}
                    %
                  </span>
                </div>
                <div className="h-1.5 w-full rounded-full bg-surface-950 overflow-hidden">
                  <div
                    className="h-full bg-sky-400 transition-all duration-200"
                    style={{
                      width: `${Math.min(
                        100,
                        Math.round(
                          (importProgress.current / Math.max(1, importProgress.total)) *
                            100
                        )
                      )}%`,
                    }}
                  />
                </div>
              </div>
              <button
                type="button"
                onClick={() => void cancelImportMedia()}
                className="px-2.5 py-1 rounded-md bg-rose-500/25 hover:bg-rose-500/40 border border-rose-400/30 text-rose-200 shrink-0"
              >
                中途取消
              </button>
            </div>
          )}

          {sessionNotice && (
            <div className="mx-5 mt-3 rounded-xl bg-amber-500/15 border border-amber-400/40 px-3.5 py-2.5 flex items-center justify-between gap-3 text-xs text-amber-100">
              <div className="flex items-center gap-2 min-w-0">
                <Info className="w-4 h-4 text-amber-300 shrink-0" />
                <span className="leading-relaxed">{sessionNotice}</span>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                {captureMode !== "dual_mix" && (
                  <button
                    type="button"
                    onClick={() => void setCaptureMode("dual_mix")}
                    className="px-2.5 py-1 rounded-md bg-amber-500/25 hover:bg-amber-500/40 text-amber-50"
                  >
                    切换为双路混合
                  </button>
                )}
                {captureMode !== "microphone" && (
                  <button
                    type="button"
                    onClick={() => void setCaptureMode("microphone")}
                    className="px-2.5 py-1 rounded-md bg-amber-500/25 hover:bg-amber-500/40 text-amber-50"
                  >
                    切换为默认麦克风
                  </button>
                )}
                <button
                  type="button"
                  onClick={clearSessionNotice}
                  title="关闭提示"
                  className="p-1 rounded hover:bg-white/10 text-amber-200"
                >
                  <X className="w-3.5 h-3.5" />
                </button>
              </div>
            </div>
          )}

          {sessionError && (
            <div className="mx-5 mt-3 rounded-xl bg-rose-500/15 border border-rose-400/40 px-3.5 py-2.5 flex items-center justify-between gap-3 text-xs text-rose-200">
              <div className="flex items-center gap-2 min-w-0">
                <AlertCircle className="w-4 h-4 text-rose-400 shrink-0" />
                <span className="break-all leading-relaxed">{sessionError}</span>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                {(sessionError.includes("服务") ||
                  sessionError.includes("HTTP") ||
                  sessionError.includes("连接") ||
                  sessionError.includes("口令")) && (
                  <button
                    type="button"
                    onClick={() => setSettingsOpen(true, "server")}
                    className="px-2.5 py-1 rounded-md bg-rose-500/25 hover:bg-rose-500/40 text-rose-100"
                  >
                    检查模型服务
                  </button>
                )}
                <button
                  type="button"
                  onClick={clearSessionError}
                  title="关闭提示"
                  className="p-1 rounded hover:bg-white/10 text-rose-300"
                >
                  <X className="w-3.5 h-3.5" />
                </button>
              </div>
            </div>
          )}

          <div
            ref={listRef}
            onWheel={() => {
              if (autoFollow) setAutoFollow(false);
            }}
            className="flex-1 overflow-y-auto px-5 py-4 space-y-2.5 select-text"
          >
            {filteredSegments.length === 0 && !livePartialSource ? (
              <div className="h-full flex flex-col items-center justify-center text-center text-slate-500 space-y-2">
                <Mic className="w-10 h-10 text-slate-700" />
                <div className="text-sm text-slate-300">实时录音与翻译工作台就绪</div>
                <p className="text-xs max-w-md leading-relaxed">
                  点击左下方「开始录音」支持随时暂停、继续、结束与回听，也可从顶部直接导入本地音视频文件。
                  每句原文、译文、说话人均支持点击修改与译文语音朗读，点击任意卡片即可跳转到对应录音位置。
                </p>
              </div>
            ) : (
              <>
                {filteredSegments.map((seg) => {
                  const isActive = seg.id === activeSegmentId;
                  const isEditing = editingId === seg.id;
                  const isEditingSpeaker = editingSpeakerId === seg.id;
                  const isSpeaking = speakingSegmentId === seg.id;
                  const cloneState = cloneStates[seg.id];
                  const isPreparingClone =
                    !isSpeaking &&
                    (preparingCloneSegmentId === seg.id || cloneState === "cloning");
                  const isRecordingMode = mode === "recording" || mode === "paused";
                  const canSpeakTranslation =
                    Boolean(seg.translatedText?.trim()) &&
                    seg.translatedText !== "翻译中…";
                  const speakerText =
                    seg.speakerLabel ?? (seg.channel === "mic" ? "我" : "对方");
                  const diffParts =
                    seg.baselineTranslated &&
                    seg.baselineTranslated !== seg.translatedText &&
                    seg.translatedText !== "翻译中…"
                      ? computeTranslationDiff(seg.baselineTranslated, seg.translatedText)
                      : null;

                  const commitSourceEdit = () => {
                    const trimmed = editSourceDraft.trim();
                    if (trimmed && trimmed !== seg.sourceText) {
                      void editSegmentSource(seg.id, trimmed);
                    }
                    setEditingId(null);
                  };

                  return (
                    <div
                      key={seg.id}
                      ref={(el) => {
                        itemRefs.current[seg.id] = el;
                      }}
                      onClick={() => {
                        // 实时翻译/录音期间禁止单击气泡播放原文（防误触及原音回环录入）；仅在结束录音后或历史记录中允许单击播放原文
                        if (isRecordingMode || isEditing || isEditingSpeaker) return;
                        if (clickTimerRef.current !== null) {
                          window.clearTimeout(clickTimerRef.current);
                        }
                        // 稍微延迟区分单击（播放原文）与双击（修改原文）
                        clickTimerRef.current = window.setTimeout(() => {
                          clickTimerRef.current = null;
                          void playSegmentOriginal(seg.id);
                        }, 210);
                      }}
                      onDoubleClick={(e) => {
                        e.stopPropagation();
                        if (clickTimerRef.current !== null) {
                          window.clearTimeout(clickTimerRef.current);
                          clickTimerRef.current = null;
                        }
                        setEditingSpeakerId(null);
                        setEditingId(seg.id);
                        setEditSourceDraft(seg.sourceText);
                      }}
                      className={`group rounded-xl border p-3.5 transition cursor-pointer ${
                        isActive
                          ? "bg-brand-500/15 border-brand-400/50 shadow-sm"
                          : "bg-surface-900/75 border-white/5 hover:border-white/15 hover:bg-surface-800/70"
                      }`}
                    >
                      <div className="flex items-center justify-between gap-2 mb-1.5 text-[11px]">
                        <div className="flex items-center gap-2 flex-wrap">
                          <span
                            className={`font-mono px-1.5 py-0.5 rounded ${
                              isActive
                                ? "bg-brand-500 text-white"
                                : "bg-surface-800 text-slate-400"
                            }`}
                          >
                            {formatTimestamp(seg.startMs)} – {formatTimestamp(seg.endMs)}
                          </span>

                          {/* 点击说话人标签可修改（对标 iOS SpeakerEditor） */}
                          <button
                            type="button"
                            onClick={(e) => {
                              e.stopPropagation();
                              setEditingSpeakerId(isEditingSpeaker ? null : seg.id);
                              setSpeakerDraft(speakerText);
                              setSpeakerApplyAll(true);
                            }}
                            title="点击修改说话人姓名"
                            className={`px-2 py-0.5 rounded flex items-center gap-1 transition ${
                              seg.channel === "mic"
                                ? "bg-emerald-500/15 text-emerald-300 hover:bg-emerald-500/25"
                                : "bg-sky-500/15 text-sky-300 hover:bg-sky-500/25"
                            }`}
                          >
                            <UserCheck className="w-3 h-3" />
                            <span>{speakerText}</span>
                          </button>

                          {seg.status === "correcting" && (
                            <span className="text-amber-300 animate-pulse">
                              正在修正译文…
                            </span>
                          )}
                        </div>

                        {/* 常驻操作栏：录制中播放译文（Qwen3 克隆）/ 结束或历史记录播放原音 + 修改原文 + 复制 */}
                        <div
                          className="flex items-center gap-1"
                          onClick={(e) => e.stopPropagation()}
                        >
                          {isRecordingMode ? (
                            <button
                              type="button"
                              onClick={() =>
                                void speakSegment(
                                  seg.id,
                                  seg.translatedText || seg.sourceText,
                                  seg.targetLang
                                )
                              }
                              title={
                                isSpeaking
                                  ? "停止播放译文"
                                  : ttsSettings.useVoiceClone
                                  ? "使用 Qwen3-TTS 原声克隆播放本句译文"
                                  : "播放本句译文"
                              }
                              className={`px-2 py-1 rounded flex items-center gap-1 transition ${
                                isSpeaking
                                  ? "bg-emerald-500/20 text-emerald-300 border border-emerald-400/40"
                                  : "hover:bg-white/10 text-slate-300 hover:text-white"
                              }`}
                            >
                              {isPreparingClone ? (
                                <>
                                  <Loader2 className="w-3.5 h-3.5 animate-spin text-brand-400" />
                                  <span>克隆中…</span>
                                </>
                              ) : isSpeaking ? (
                                <>
                                  <Square className="w-3 h-3 fill-current" />
                                  <span>播放中</span>
                                </>
                              ) : (
                                <>
                                  <Volume2 className="w-3.5 h-3.5" />
                                  <span>播放译文</span>
                                </>
                              )}
                            </button>
                          ) : (
                            playback.hasAudio && (
                              <button
                                type="button"
                                onClick={() => void seekPlayback(seg.startMs, true)}
                                title="从该句起始位置播放原始录音（原文原音）"
                                className={`px-2 py-1 rounded flex items-center gap-1 transition ${
                                  isActive && playback.isPlaying
                                    ? "bg-brand-500/25 text-brand-300"
                                    : "hover:bg-white/10 text-slate-300 hover:text-white"
                                }`}
                              >
                                <Play className="w-3.5 h-3.5" />
                                <span>播放原音</span>
                              </button>
                            )
                          )}

                          <button
                            type="button"
                            onClick={() => {
                              setEditingId(isEditing ? null : seg.id);
                              setEditSourceDraft(seg.sourceText);
                            }}
                            title="修改识别原文并重新翻译（对标 iOS 修改原文）"
                            className={`px-2 py-1 rounded flex items-center gap-1 transition ${
                              isEditing
                                ? "bg-brand-500/25 text-brand-300"
                                : "hover:bg-white/10 text-slate-300 hover:text-white"
                            }`}
                          >
                            <Pencil className="w-3.5 h-3.5" />
                            <span>修改原文</span>
                          </button>

                          <button
                            type="button"
                            onClick={() =>
                              void navigator.clipboard?.writeText(
                                `${seg.sourceText}\n${seg.translatedText}`
                              )
                            }
                            title="复制原文与译文"
                            className="p-1 rounded hover:bg-white/10 text-slate-400 hover:text-white"
                          >
                            <Copy className="w-3.5 h-3.5" />
                          </button>
                        </div>
                      </div>

                      {/* 说话人修改面板 */}
                      {isEditingSpeaker && (
                        <div
                          className="mb-2.5 rounded-lg bg-surface-950/90 border border-sky-400/40 p-2.5 space-y-2 text-xs"
                          onClick={(e) => e.stopPropagation()}
                        >
                          <div className="flex items-center gap-2 flex-wrap">
                            <span className="text-slate-400">说话人姓名：</span>
                            <input
                              value={speakerDraft}
                              onChange={(e) => setSpeakerDraft(e.target.value)}
                              placeholder="例如：张总 / Alice / 我"
                              className="rounded bg-surface-900 border border-white/15 px-2.5 py-1 text-xs text-white focus:outline-none focus:border-brand-500"
                            />
                            {knownSpeakers.map((sp) => (
                              <button
                                key={sp}
                                type="button"
                                onClick={() => setSpeakerDraft(sp)}
                                className={`px-2 py-0.5 rounded text-[11px] border ${
                                  speakerDraft === sp
                                    ? "bg-brand-500/25 border-brand-400 text-brand-200"
                                    : "bg-surface-900 border-white/10 text-slate-300 hover:text-white"
                                }`}
                              >
                                {sp}
                              </button>
                            ))}
                          </div>
                          <div className="flex items-center justify-between gap-2">
                            <label className="flex items-center gap-1.5 text-[11px] text-slate-300 cursor-pointer">
                              <input
                                type="checkbox"
                                checked={speakerApplyAll}
                                onChange={(e) => setSpeakerApplyAll(e.target.checked)}
                                className="w-3.5 h-3.5 accent-brand-500"
                              />
                              同步修改当前对话中「{speakerText}」的所有句子
                            </label>
                            <div className="flex items-center gap-1.5">
                              <button
                                type="button"
                                onClick={() => {
                                  void editSegmentSpeaker(
                                    seg.id,
                                    speakerDraft,
                                    speakerApplyAll
                                  );
                                  setEditingSpeakerId(null);
                                }}
                                className="px-2.5 py-1 rounded bg-brand-500 hover:bg-brand-600 text-white text-xs flex items-center gap-1"
                              >
                                <Check className="w-3 h-3" /> 保存说话人
                              </button>
                              <button
                                type="button"
                                onClick={() => setEditingSpeakerId(null)}
                                className="px-2 py-1 rounded bg-surface-800 text-slate-300 text-xs"
                              >
                                取消
                              </button>
                            </div>
                          </div>
                        </div>
                      )}

                      {/* 修改原文面板（双击对话进入，离开输入框自动保存并重译，按 Esc 取消） */}
                      {isEditing ? (
                        <div
                          className="mt-2 rounded-lg bg-surface-950/90 border border-brand-500/50 p-3 space-y-2.5"
                          onClick={(e) => e.stopPropagation()}
                          onDoubleClick={(e) => e.stopPropagation()}
                        >
                          <div className="space-y-1">
                            <label className="text-[11px] text-slate-300 font-medium">
                              修改原文（离开输入框自动保存并重译，Esc 取消）
                            </label>
                            <input
                              autoFocus
                              value={editSourceDraft}
                              onChange={(e) => setEditSourceDraft(e.target.value)}
                              onBlur={commitSourceEdit}
                              onKeyDown={(e) => {
                                if (e.key === "Enter") {
                                  e.preventDefault();
                                  commitSourceEdit();
                                } else if (e.key === "Escape") {
                                  e.preventDefault();
                                  setEditingId(null);
                                }
                              }}
                              className="w-full rounded bg-surface-900 border border-white/15 px-2.5 py-1.5 text-xs text-white focus:outline-none focus:border-brand-500"
                            />
                          </div>
                          {seg.translatedText && (
                            <div className="space-y-1">
                              <label className="text-[11px] text-slate-400">
                                最新译文（保存原文后将自动重新翻译并以高亮色标出修正处）
                              </label>
                              <div className="w-full rounded bg-surface-900/60 border border-white/5 px-2.5 py-1.5 text-xs text-slate-400">
                                {seg.translatedText}
                              </div>
                            </div>
                          )}
                          <div className="flex items-center justify-end gap-2 pt-0.5">
                            <button
                              type="button"
                              onMouseDown={(e) => {
                                e.preventDefault();
                                setEditingId(null);
                              }}
                              className="px-3 py-1.5 rounded bg-surface-800 text-slate-300 text-xs"
                            >
                              取消
                            </button>
                            <button
                              type="button"
                              onMouseDown={(e) => {
                                e.preventDefault();
                                commitSourceEdit();
                              }}
                              className="px-3 py-1.5 rounded bg-brand-500 hover:bg-brand-600 text-white text-xs font-medium flex items-center gap-1"
                            >
                              <RefreshCw className="w-3 h-3" /> 保存并重译
                            </button>
                          </div>
                        </div>
                      ) : (
                        <>
                          {/* 原文：若经过 Whisper 二次校对或手动校对原文，在原文末尾显示魔法棒图标（对标 iOS BubbleView） */}
                          <div className="text-xs text-slate-300 leading-relaxed">
                            <span>{seg.sourceText}</span>
                            {seg.isEdited && (
                              <span
                                title="原文已通过高精度模型或人工校对"
                                className="inline-flex items-center ml-1.5 text-brand-400 align-middle"
                              >
                                <Wand2 className="w-3.5 h-3.5" />
                              </span>
                            )}
                          </div>

                          {/* 译文 + 末尾三态小喇叭（克隆中转圈 / 声音准备好了灰色喇叭 / 播放中绿色喇叭，对标 iOS） */}
                          <div className="text-sm font-medium text-white mt-1 leading-relaxed flex items-baseline gap-1.5 flex-wrap">
                            <span>
                              {diffParts
                                ? diffParts.map((part, pIdx) =>
                                    part.changed ? (
                                      <span
                                        key={pIdx}
                                        className="text-amber-300 font-semibold"
                                        title={`修正前：${seg.baselineTranslated}`}
                                      >
                                        {part.text}
                                      </span>
                                    ) : (
                                      <span key={pIdx}>{part.text}</span>
                                    )
                                  )
                                : seg.translatedText}
                            </span>
                            {canSpeakTranslation && (
                              <button
                                type="button"
                                onClick={(e) => {
                                  e.stopPropagation();
                                  void speakSegment(
                                    seg.id,
                                    seg.translatedText || seg.sourceText,
                                    seg.targetLang
                                  );
                                }}
                                onDoubleClick={(e) => e.stopPropagation()}
                                title={
                                  isPreparingClone
                                    ? "正在克隆原声…"
                                    : isSpeaking
                                    ? "正在播放译文（点击停止）"
                                    : cloneState === "ready"
                                    ? "原声已就绪，点击播放译文"
                                    : "点击播放译文"
                                }
                                className={`inline-flex items-center justify-center p-1 rounded-full align-middle transition ${
                                  isSpeaking
                                    ? "text-emerald-400 bg-emerald-500/15"
                                    : isPreparingClone
                                    ? "text-slate-400"
                                    : "text-slate-400 hover:text-white hover:bg-white/10"
                                }`}
                              >
                                {isPreparingClone ? (
                                  <Loader2 className="w-4 h-4 animate-spin" />
                                ) : (
                                  <Volume2
                                    className={`w-4 h-4 ${
                                      isSpeaking ? "animate-pulse" : ""
                                    }`}
                                  />
                                )}
                              </button>
                            )}
                          </div>
                        </>
                      )}
                    </div>
                  );
                })}

                {(livePartialSource || livePartialTranslation) && (
                  <div className="rounded-xl border border-dashed border-brand-400/40 bg-brand-500/5 p-3.5">
                    <div className="text-[11px] text-brand-400 mb-1">实时识别中…</div>
                    <div className="text-xs text-slate-300 italic">{livePartialSource}</div>
                    <div className="text-sm text-white/90 mt-1">
                      {livePartialTranslation || "…"}
                    </div>
                  </div>
                )}
              </>
            )}
          </div>

          {!autoFollow && (
            <button
              onClick={() => setAutoFollow(true)}
              className="absolute bottom-4 right-5 px-3 py-1.5 rounded-full bg-brand-500 hover:bg-brand-600 text-white text-xs shadow-lg flex items-center gap-1.5"
            >
              <ArrowDownCircle className="w-3.5 h-3.5" />
              恢复自动跟随
            </button>
          )}
        </main>

        {summaryOpen && (
          <aside className="w-80 xl:w-96 border-l border-white/10 bg-surface-900/70 flex flex-col shrink-0">
            <div className="p-3.5 border-b border-white/10 space-y-2.5">
              <div className="flex items-center justify-between gap-2">
                <span className="text-xs font-semibold text-white flex items-center gap-1.5">
                  <Sparkles className="w-4 h-4 text-purple-400" />
                  一键总结（支持时间锚点回跳）
                </span>
                {summaryMarkdown && !summaryGenerating && (
                  <div className="flex items-center gap-1">
                    <button
                      type="button"
                      onClick={() => {
                        void navigator.clipboard?.writeText(summaryMarkdown);
                        setSummaryCopied(true);
                        window.setTimeout(() => setSummaryCopied(false), 1800);
                      }}
                      title="复制总结全文"
                      className="px-2 py-1 rounded bg-surface-950 border border-white/10 hover:bg-white/10 text-[11px] text-slate-300 hover:text-white flex items-center gap-1"
                    >
                      <Copy className="w-3 h-3" />
                      {summaryCopied ? "已复制" : "复制"}
                    </button>
                    {editingSummary ? (
                      <button
                        type="button"
                        onClick={async () => {
                          await saveSummaryMarkdown(summaryDraft);
                          setEditingSummary(false);
                        }}
                        className="px-2 py-1 rounded bg-emerald-600 hover:bg-emerald-500 text-[11px] text-white font-medium"
                      >
                        保存
                      </button>
                    ) : (
                      <button
                        type="button"
                        onClick={() => {
                          setSummaryDraft(summaryMarkdown);
                          setEditingSummary(true);
                        }}
                        title="手动编辑总结并保存到历史"
                        className="px-2 py-1 rounded bg-surface-950 border border-white/10 hover:bg-white/10 text-[11px] text-slate-300 hover:text-white flex items-center gap-1"
                      >
                        <Pencil className="w-3 h-3" />
                        编辑
                      </button>
                    )}
                  </div>
                )}
              </div>
              <div className="flex items-center gap-2">
                <select
                  value={summaryTemplateId}
                  onChange={(e) => setSummaryTemplateId(e.target.value)}
                  className="flex-1 rounded-lg bg-surface-950 border border-white/10 px-2.5 py-1.5 text-xs text-slate-100"
                >
                  {SUMMARY_TEMPLATES.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.title}
                    </option>
                  ))}
                </select>
                <button
                  disabled={segments.length === 0 || summaryGenerating}
                  onClick={() => {
                    setEditingSummary(false);
                    void generateSummary();
                  }}
                  className="px-3 py-1.5 rounded-lg bg-purple-600 hover:bg-purple-500 text-white text-xs font-medium disabled:opacity-40 shrink-0"
                >
                  {summaryGenerating ? "生成中…" : "生成"}
                </button>
              </div>
            </div>

            <div className="flex-1 overflow-y-auto p-4 select-text">
              {editingSummary ? (
                <div className="h-full flex flex-col gap-2">
                  <textarea
                    value={summaryDraft}
                    onChange={(e) => setSummaryDraft(e.target.value)}
                    className="flex-1 w-full rounded-lg bg-surface-950 border border-white/15 p-3 text-xs text-slate-100 leading-relaxed font-mono resize-none focus:outline-none focus:border-purple-400"
                  />
                  <div className="flex justify-end gap-2">
                    <button
                      type="button"
                      onClick={() => setEditingSummary(false)}
                      className="px-2.5 py-1 rounded bg-surface-800 text-xs text-slate-300"
                    >
                      取消
                    </button>
                    <button
                      type="button"
                      onClick={async () => {
                        await saveSummaryMarkdown(summaryDraft);
                        setEditingSummary(false);
                      }}
                      className="px-3 py-1 rounded bg-emerald-600 hover:bg-emerald-500 text-xs text-white font-medium"
                    >
                      保存修改
                    </button>
                  </div>
                </div>
              ) : summaryMarkdown ? (
                <div>{renderSummaryWithAnchors(summaryMarkdown)}</div>
              ) : (
                <div className="h-full flex flex-col items-center justify-center text-center text-xs text-slate-500 px-4">
                  录音或导入音视频出字后，点击「生成」即可调用 LLM 提炼会议纪要与双语要点；摘要中的 [mm:ss] 可直接点击跳转录音位置。
                </div>
              )}
            </div>
          </aside>
        )}
          </div>

          <WaveformPlayer />
        </>
      )}

      <SettingsModal />
    </div>
  );
}
