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
  Lock,
  Mic,
  PanelRight,
  PanelTop,
  Pencil,
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
import {
  buildMarkdown,
  buildSrt,
  findActiveSegmentIndex,
  formatTimestamp,
  parseSummaryTimestampMs,
} from "../../lib/export";
import { SUMMARY_TEMPLATES, useHearStore } from "../../stores/useHearStore";
import type { AudioCaptureMode } from "../../types/hear";
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

export function MainApp() {
  const {
    mode,
    sourceLang,
    targetLang,
    lockSourceLang,
    captureMode,
    audioSources,
    sessionError,
    sessionNotice,
    speakingSegmentId,
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
    conversations,
    viewMode,
    searchQuery,
    summaryOpen,
    summaryTemplateId,
    summaryMarkdown,
    summaryGenerating,
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
    editSegmentTranslation,
    editSegmentSpeaker,
    speakSegment,
    generateSummary,
    importMediaFile,
  } = useHearStore();

  const [autoFollow, setAutoFollow] = useState(true);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editSourceDraft, setEditSourceDraft] = useState("");
  const [editTransDraft, setEditTransDraft] = useState("");
  const [editingSpeakerId, setEditingSpeakerId] = useState<string | null>(null);
  const [speakerDraft, setSpeakerDraft] = useState("");
  const [speakerApplyAll, setSpeakerApplyAll] = useState(true);
  const [historySearch, setHistorySearch] = useState("");
  const [renamingConvId, setRenamingConvId] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState("");
  const listRef = useRef<HTMLDivElement | null>(null);
  const itemRefs = useRef<Record<string, HTMLDivElement | null>>({});

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

  const downloadBlob = (filename: string, content: string) => {
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
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

  return (
    <div className="h-screen w-screen flex flex-col bg-surface-950 text-slate-100">
      {/* 顶部控制栏 */}
      <header className="h-14 border-b border-white/10 bg-surface-900/90 px-4 flex items-center justify-between gap-3 shrink-0">
        <div className="flex items-center gap-2.5 min-w-0">
          {viewMode === "workspace" && (
            <button
              type="button"
              onClick={() => void backToHome()}
              title="返回历史记录主页"
              className="px-2.5 py-1.5 rounded-lg bg-surface-800 border border-white/10 hover:bg-surface-700 text-xs text-slate-200 flex items-center gap-1.5 shrink-0"
            >
              <ArrowLeft className="w-3.5 h-3.5 text-brand-400" />
              <span>返回列表</span>
            </button>
          )}

          <div className="font-semibold tracking-wide text-white flex items-center gap-2 shrink-0">
            <span className="w-2.5 h-2.5 rounded-full bg-brand-500 inline-block" />
            听见 Hear
          </div>

          <select
            value={captureMode}
            onChange={(e) => void setCaptureMode(e.target.value as AudioCaptureMode)}
            className="rounded-lg bg-surface-800 border border-white/10 px-2.5 py-1.5 text-xs text-slate-100 max-w-[230px]"
          >
            {audioSources.map((src) => (
              <option key={src.id} value={src.kind}>
                {src.label}
              </option>
            ))}
          </select>

          <div className="flex items-center gap-1 rounded-lg bg-surface-800 border border-white/10 px-2 py-1 text-xs">
            <select
              value={sourceLang}
              onChange={(e) => void setLanguagePair(e.target.value, targetLang, lockSourceLang)}
              className="bg-transparent text-slate-100 focus:outline-none"
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
              className="bg-transparent text-slate-100 focus:outline-none"
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

          {viewMode === "workspace" && (
            <button
              disabled={mode === "batch_processing"}
              onClick={() => void importMediaFile()}
              title="选择本地 WAV/MP3/MP4 等音视频文件，批量生成双语字幕与时间轴"
              className="px-2.5 py-1.5 rounded-lg bg-surface-800 border border-white/10 hover:bg-surface-700 disabled:opacity-50 text-xs text-slate-200 flex items-center gap-1.5"
            >
              <FileAudio className="w-3.5 h-3.5 text-sky-400" />
              {mode === "batch_processing" ? "批量转写中…" : "导入音视频"}
            </button>
          )}
        </div>

        {/* 右侧：新版本提醒 + 服务状态胶囊 + 悬浮字幕 + 总结 + 设置 */}
        <div className="flex items-center gap-1.5 shrink-0">
          {updateInfo?.hasUpdate && (
            <button
              onClick={() => setSettingsOpen(true, "system")}
              title={`发现新版本 v${updateInfo.latestVersion}，点击查看更新说明并一键更新`}
              className="px-2.5 py-1.5 rounded-lg bg-emerald-500/20 border border-emerald-400/40 text-emerald-300 hover:bg-emerald-500/30 text-xs flex items-center gap-1.5"
            >
              <ArrowUpCircle className="w-3.5 h-3.5" />
              <span>新版本 v{updateInfo.latestVersion}</span>
            </button>
          )}

          <div
            onClick={() => setSettingsOpen(true, "server")}
            title={serviceBadge.tooltip}
            className="px-2.5 py-1.5 rounded-lg bg-surface-800 border border-white/10 hover:bg-surface-700 text-xs flex items-center gap-1.5 cursor-pointer"
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
            className={`p-2 rounded-lg border ${
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
              className={`p-2 rounded-lg border ${
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
            className="p-2 rounded-lg bg-surface-800 border border-white/10 text-slate-300 hover:text-white"
          >
            <Settings className="w-4 h-4" />
          </button>
        </div>
      </header>

      {viewMode === "home" ? (
        /* 默认主页：顶部 3 张快捷功能卡片（开始录音 / 导入文件 / 悬浮字幕） + 下方「最近文件」历史列表 */
        <div className="flex-1 overflow-y-auto px-8 py-7">
          <div className="max-w-5xl mx-auto space-y-7">
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
                disabled={segments.length === 0}
                onClick={() => downloadBlob("hear-subtitles.srt", buildSrt(segments, true))}
                className="px-2.5 py-1 rounded-md bg-surface-900 border border-white/10 text-slate-300 hover:text-white disabled:opacity-35 flex items-center gap-1"
              >
                <Download className="w-3.5 h-3.5" /> 导出 SRT
              </button>
              <button
                disabled={segments.length === 0}
                onClick={() =>
                  downloadBlob("hear-transcript.md", buildMarkdown(segments, summaryMarkdown))
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
                  const speakerText =
                    seg.speakerLabel ?? (seg.channel === "mic" ? "我" : "对方");

                  return (
                    <div
                      key={seg.id}
                      ref={(el) => {
                        itemRefs.current[seg.id] = el;
                      }}
                      onClick={() => {
                        if (
                          !isEditing &&
                          !isEditingSpeaker &&
                          mode === "idle" &&
                          playback.hasAudio
                        ) {
                          void seekPlayback(seg.startMs, true);
                        }
                      }}
                      className={`group rounded-xl border p-3.5 transition ${
                        mode === "idle" && playback.hasAudio ? "cursor-pointer" : ""
                      } ${
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

                          {seg.isEdited && (
                            <span
                              title={
                                seg.baselineTranslated
                                  ? `原译文：${seg.baselineTranslated}`
                                  : "已手动校对修改"
                              }
                              className="px-1.5 py-0.5 rounded bg-brand-500/15 text-brand-300 flex items-center gap-1"
                            >
                              <Wand2 className="w-3 h-3" />
                              已校对
                            </span>
                          )}

                          {seg.status === "correcting" && (
                            <span className="text-amber-300 animate-pulse">
                              正在重新翻译…
                            </span>
                          )}
                        </div>

                        {/* 常驻操作栏：朗读译文 + 修改原文/译文 + 复制（对标 iOS 直观可见） */}
                        <div
                          className="flex items-center gap-1"
                          onClick={(e) => e.stopPropagation()}
                        >
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
                                ? "停止朗读译文"
                                : ttsSettings.useVoiceClone && playback.hasAudio
                                  ? "使用原声克隆朗读本句译文"
                                  : "朗读本句译文"
                            }
                            className={`px-2 py-1 rounded flex items-center gap-1 transition ${
                              isSpeaking
                                ? "bg-emerald-500/20 text-emerald-300 border border-emerald-400/40"
                                : "hover:bg-white/10 text-slate-300 hover:text-white"
                            }`}
                          >
                            {isSpeaking ? (
                              <>
                                <Square className="w-3 h-3 fill-current" />
                                <span>朗读中</span>
                              </>
                            ) : (
                              <>
                                <Volume2 className="w-3.5 h-3.5" />
                                <span>朗读</span>
                              </>
                            )}
                          </button>

                          <button
                            type="button"
                            onClick={() => {
                              setEditingId(isEditing ? null : seg.id);
                              setEditSourceDraft(seg.sourceText);
                              setEditTransDraft(seg.translatedText);
                            }}
                            title="修改原文重译，或直接修改译文"
                            className={`px-2 py-1 rounded flex items-center gap-1 transition ${
                              isEditing
                                ? "bg-brand-500/25 text-brand-300"
                                : "hover:bg-white/10 text-slate-300 hover:text-white"
                            }`}
                          >
                            <Pencil className="w-3.5 h-3.5" />
                            <span>修改</span>
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

                      {/* 原文 + 译文双框编辑面板（对标 iOS：可改原文重译，也可直接改译文） */}
                      {isEditing ? (
                        <div
                          className="mt-2 rounded-lg bg-surface-950/90 border border-brand-500/50 p-3 space-y-2.5"
                          onClick={(e) => e.stopPropagation()}
                        >
                          <div className="space-y-1">
                            <label className="text-[11px] text-slate-400">
                              修改识别原文（点「保存原文并重译」将保留旧译文对照并自动重新翻译）
                            </label>
                            <input
                              value={editSourceDraft}
                              onChange={(e) => setEditSourceDraft(e.target.value)}
                              className="w-full rounded bg-surface-900 border border-white/15 px-2.5 py-1.5 text-xs text-white focus:outline-none focus:border-brand-500"
                            />
                          </div>
                          <div className="space-y-1">
                            <label className="text-[11px] text-slate-400">
                              或直接修改译文（无需等待模型，立即保存人工校对译文）
                            </label>
                            <input
                              value={editTransDraft}
                              onChange={(e) => setEditTransDraft(e.target.value)}
                              className="w-full rounded bg-surface-900 border border-white/15 px-2.5 py-1.5 text-xs text-white focus:outline-none focus:border-emerald-500"
                            />
                          </div>
                          <div className="flex items-center justify-end gap-2 pt-0.5">
                            <button
                              type="button"
                              onClick={() => {
                                if (editSourceDraft.trim()) {
                                  void editSegmentSource(seg.id, editSourceDraft.trim());
                                }
                                setEditingId(null);
                              }}
                              className="px-3 py-1.5 rounded bg-brand-500 hover:bg-brand-600 text-white text-xs font-medium flex items-center gap-1"
                            >
                              <RefreshCw className="w-3 h-3" /> 保存原文并重译
                            </button>
                            <button
                              type="button"
                              onClick={() => {
                                if (
                                  editSourceDraft.trim() &&
                                  editSourceDraft.trim() !== seg.sourceText
                                ) {
                                  void editSegmentSource(seg.id, editSourceDraft.trim());
                                }
                                if (editTransDraft.trim()) {
                                  void editSegmentTranslation(
                                    seg.id,
                                    editTransDraft.trim()
                                  );
                                }
                                setEditingId(null);
                              }}
                              className="px-3 py-1.5 rounded bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-medium flex items-center gap-1"
                            >
                              <Check className="w-3 h-3" /> 直接保存译文
                            </button>
                            <button
                              type="button"
                              onClick={() => setEditingId(null)}
                              className="px-2.5 py-1.5 rounded bg-surface-800 text-slate-300 text-xs"
                            >
                              取消
                            </button>
                          </div>
                        </div>
                      ) : (
                        <>
                          <div className="text-xs text-slate-300 leading-relaxed">
                            {seg.sourceText}
                          </div>
                          <div className="text-sm font-medium text-white mt-1 leading-relaxed">
                            {seg.translatedText}
                          </div>
                          {seg.baselineTranslated &&
                            seg.baselineTranslated !== seg.translatedText && (
                              <div className="text-[11px] text-slate-500 mt-1">
                                校对前原译：{seg.baselineTranslated}
                              </div>
                            )}
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
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold text-white flex items-center gap-1.5">
                  <Sparkles className="w-4 h-4 text-purple-400" />
                  一键总结（支持时间锚点回跳）
                </span>
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
                  onClick={() => void generateSummary()}
                  className="px-3 py-1.5 rounded-lg bg-purple-600 hover:bg-purple-500 text-white text-xs font-medium disabled:opacity-40 shrink-0"
                >
                  {summaryGenerating ? "生成中…" : "生成"}
                </button>
              </div>
            </div>

            <div className="flex-1 overflow-y-auto p-4 select-text">
              {summaryMarkdown ? (
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
