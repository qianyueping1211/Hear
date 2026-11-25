import { create } from "zustand";
import type {
  AppSnapshot,
  AudioCaptureMode,
  AudioSourceOption,
  ConversationMeta,
  EngineSource,
  LlmApiConfig,
  LocalServerInstallStatus,
  LocalServerProgress,
  OutputAudioDevice,
  RecordingPlaybackState,
  SavedConversation,
  ServiceConfig,
  ServiceProbeResult,
  SessionMode,
  SubtitleSegment,
  SubtitleStyle,
  SummaryTemplateOption,
  TtsOutputSettings,
  UpdateCheckResult,
  UpdateConfig,
} from "../types/hear";

let activeCloneAudio: HTMLAudioElement | null = null;
let activeCloneUrl: string | null = null;
let tauriListenersRegistered = false;
const autoSpokenSegmentIds = new Set<string>();
const cloneWavCache = new Map<string, { text: string; wav: Uint8Array }>();
const cloneInflight = new Map<
  string,
  { text: string; promise: Promise<Uint8Array | null> }
>();

function stopActiveCloneAudio() {
  if (activeCloneAudio) {
    try {
      activeCloneAudio.pause();
      activeCloneAudio.src = "";
    } catch {
      // ignore
    }
    activeCloneAudio = null;
  }
  if (activeCloneUrl) {
    URL.revokeObjectURL(activeCloneUrl);
    activeCloneUrl = null;
  }
}

const isTauriRuntime = () =>
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

const isSubtitleWindow = () =>
  typeof window !== "undefined" &&
  window.location.pathname.toLowerCase().includes("subtitle");

async function tauriInvoke<T>(
  cmd: string,
  args?: Record<string, unknown>
): Promise<T | null> {
  if (!isTauriRuntime()) return null;
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(cmd, args);
}

export const SUMMARY_TEMPLATES: SummaryTemplateOption[] = [
  {
    id: "meeting",
    title: "会议纪要（带时间锚点）",
    description: "提炼核心议题、关键结论与行动项，附带可点击 [mm:ss] 时间戳",
  },
  {
    id: "bilingual",
    title: "双语核心要点",
    description: "按主题整理中英对照摘要，适合外语讲座与技术分享复盘",
  },
  {
    id: "qa",
    title: "问答与待办清单",
    description: "抽取提问、回答与负责人/截止日期",
  },
];

const DEFAULT_STYLE: SubtitleStyle = {
  visible: false,
  clickThrough: false,
  excludeFromCapture: true,
  layout: "bilingual",
  fontSize: 22,
  maxLines: 2,
  backgroundColor: "#0b0f17",
  backgroundOpacity: 0.72,
  textStroke: true,
  autoFadeSeconds: 0,
  traditionalChinese: false,
  syncWithPlayback: true,
};

const DEFAULT_SERVICE_CONFIG: ServiceConfig = {
  localServiceAddress: "https://127.0.0.1:8000",
  localAccessToken: "",
  cloudServiceAddress: "",
  cloudAccessToken: "",
  asrSource: "local",
  mtSource: "local",
  cloneSource: "local",
};

const DEFAULT_PROBE: ServiceProbeResult = {
  ok: false,
  address: "",
  latencyMs: 0,
  summary: "尚未检测连接",
  asrReady: false,
  asrDetail: "未检测",
  mtReady: false,
  mtDetail: "未检测",
  cloneReady: false,
  cloneDetail: "未检测",
  authMode: "unknown",
  streamingMt: false,
};

const DEFAULT_TTS: TtsOutputSettings = {
  enabled: false,
  useVoiceClone: true,
  routingMode: "face_to_face",
  outputDeviceId: "default",
  inputDeviceId: "default",
  meetingMicOutputDeviceId: "",
  meetingLoopbackDeviceId: "",
  muteMicWhileSpeaking: false,
  autoSpeakMyMic: false,
  autoSpeakOther: false,
  duckOriginalAudio: true,
  duckRatio: 0.25,
  systemVoicePreference: "auto",
};

const DEFAULT_PLAYBACK: RecordingPlaybackState = {
  hasAudio: false,
  durationMs: 0,
  positionMs: 0,
  isPlaying: false,
  speed: 1.0,
  systemVolume: 1.0,
  micVolume: 1.0,
  peaks: [],
};

const DEFAULT_LLM_CONFIG: LlmApiConfig = {
  enabled: false,
  provider: "openai",
  baseUrl: "https://api.deepseek.com/v1",
  apiKey: "",
  model: "deepseek-chat",
};

const DEFAULT_UPDATE_CONFIG: UpdateConfig = {
  repo: "qianyueping1211/Hear",
  githubToken: "",
  autoCheckOnStartup: true,
};

const DEFAULT_LOCAL_SERVER_INSTALL: LocalServerInstallStatus = {
  installed: false,
  installDir: "",
  hasBundledRuntime: false,
  hasModels: false,
};

interface HearStoreState extends AppSnapshot {
  audioSources: AudioSourceOption[];
  audioLevel: number;
  sessionError: string | null;
  sessionNotice: string | null;
  speakingSegmentId: string | null;
  lastSpokenSegmentId: string | null;
  preparingCloneSegmentId: string | null;
  cloneStates: Record<string, "cloning" | "ready">;
  outputDevices: OutputAudioDevice[];
  inputDevices: OutputAudioDevice[];
  hasMyVoiceSample: boolean;
  seekNonce: number;
  seekTargetMs: number;
  searchQuery: string;
  summaryOpen: boolean;
  summaryTemplateId: string;
  summaryMarkdown: string;
  summaryGenerating: boolean;
  viewMode: "home" | "workspace";
  historyOpen: boolean;
  settingsOpen: boolean;
  activeSettingsTab: "server" | "subtitle" | "audio" | "general" | "system";
  testingLocal: boolean;
  testingCloud: boolean;
  localServerBusy: "install" | "reinstall" | "uninstall" | null;
  localServerProgress: LocalServerProgress | null;
  localServerMessage: string | null;
  localServerError: string | null;
  checkingUpdate: boolean;
  downloadingUpdate: boolean;
  updateDownloadProgress: { downloaded: number; total: number } | null;
  updateDownloadError: string | null;
  importProgress: { current: number; total: number; active: boolean } | null;
  hydrated: boolean;

  hydrate: () => Promise<void>;
  clearSessionError: () => void;
  clearSessionNotice: () => void;
  setSearchQuery: (q: string) => void;
  setSummaryOpen: (open: boolean) => void;
  setSummaryTemplateId: (id: string) => void;
  setViewMode: (view: "home" | "workspace") => void;
  backToHome: () => Promise<void>;
  setHistoryOpen: (open: boolean) => void;
  setSettingsOpen: (open: boolean, tab?: HearStoreState["activeSettingsTab"]) => void;
  loadConversation: (id: string) => Promise<void>;
  renameConversation: (id: string, title: string) => Promise<void>;
  deleteConversation: (id: string) => Promise<void>;

  setLanguagePair: (src: string, dst: string, lockSrc: boolean) => Promise<void>;
  setCaptureMode: (mode: AudioCaptureMode, appPid?: number) => Promise<void>;
  startRecording: (fresh?: boolean) => Promise<void>;
  pauseRecording: () => Promise<void>;
  resumeRecording: () => Promise<void>;
  stopRecording: () => Promise<void>;
  toggleRecording: () => Promise<void>;
  clearRecording: () => Promise<void>;

  seekPlayback: (ms: number, autoPlay?: boolean) => Promise<void>;
  togglePlayback: () => Promise<void>;
  setPlaybackPlaying: (playing: boolean) => Promise<void>;
  syncPlaybackPosition: (ms: number) => void;
  readRecordingAudio: () => Promise<Uint8Array | null>;
  setPlaybackSpeed: (speed: number) => void;
  setTrackVolumes: (systemVolume: number, micVolume: number) => void;

  updateSubtitleStyle: (patch: Partial<SubtitleStyle>) => Promise<void>;
  toggleSubtitleVisible: () => Promise<void>;
  saveServiceConfig: (patch: Partial<ServiceConfig>) => Promise<ServiceConfig>;
  testServiceConnection: (
    target: EngineSource,
    overrideAddress?: string,
    overrideToken?: string
  ) => Promise<ServiceProbeResult | null>;
  refreshLocalServerInstallStatus: () => Promise<void>;
  installLocalServer: () => Promise<void>;
  reinstallLocalServer: () => Promise<void>;
  uninstallLocalServer: (removeModels: boolean) => Promise<void>;
  openLocalServerDir: () => Promise<void>;
  openLogsDir: () => Promise<void>;
  saveUpdateConfig: (patch: Partial<UpdateConfig>) => Promise<UpdateConfig>;
  llmConfig: LlmApiConfig;
  saveLlmConfig: (patch: Partial<LlmApiConfig>) => Promise<LlmApiConfig>;
  fetchLlmModels: (provider: string, baseUrl: string, apiKey: string) => Promise<string[]>;
  checkForUpdates: (override?: UpdateConfig) => Promise<UpdateCheckResult | null>;
  downloadAndInstallUpdate: () => Promise<void>;
  openGithubUrl: (url: string) => Promise<void>;
  updateTtsSettings: (patch: Partial<TtsOutputSettings>) => void;
  activateMeetingMode: () => Promise<void>;
  deactivateMeetingVirtualCables: (switchToFaceToFace?: boolean) => Promise<void>;
  setGlossary: (text: string) => void;

  editSegmentSource: (id: string, newSource: string) => Promise<void>;
  editSegmentTranslation: (id: string, newTranslation: string) => Promise<void>;
  editSegmentSpeaker: (
    id: string,
    speakerLabel: string,
    applyToSameSpeaker: boolean
  ) => Promise<void>;
  speakSegment: (
    id: string,
    text: string,
    lang: string,
    options?: { fromResume?: boolean }
  ) => Promise<void>;
  resumeAutoSpeakFromNext: () => Promise<void>;
  prepareSegmentClone: (
    id: string,
    text: string,
    lang: string,
    isPreclone?: boolean
  ) => Promise<Uint8Array | null>;
  playSegmentOriginal: (id: string) => Promise<void>;
  stopSpeakingSegment: () => void;
  refreshOutputDevices: () => Promise<void>;
  saveMyVoiceSample: (segmentId?: string) => Promise<boolean>;
  saveRecordedMyVoiceSample: (wavBytes: Uint8Array, refText: string) => Promise<boolean>;
  readMyVoiceSampleWav: () => Promise<Uint8Array | null>;
  clearMyVoiceSample: () => Promise<void>;
  generateSummary: () => Promise<void>;
  saveSummaryMarkdown: (markdown: string) => Promise<void>;
  exportTextFile: (
    defaultName: string,
    ext: string,
    filterName: string,
    content: string
  ) => Promise<boolean>;
  importMediaFile: () => Promise<void>;
  cancelImportMedia: () => Promise<void>;
  exportRecordingWav: () => Promise<void>;
}

export const useHearStore = create<HearStoreState>((set, get) => ({
  appVersion: "0.1.28",
  activeConversationId: "",
  conversations: [],
  mode: "idle" as SessionMode,
  sourceLang: "en",
  targetLang: "zh",
  lockSourceLang: false,
  captureMode: "dual_mix",
  segments: [],
  livePartialSource: "",
  livePartialTranslation: "",
  subtitleStyle: DEFAULT_STYLE,
  serviceConfig: DEFAULT_SERVICE_CONFIG,
  localStatus: DEFAULT_PROBE,
  cloudStatus: DEFAULT_PROBE,
  localServerInstall: DEFAULT_LOCAL_SERVER_INSTALL,
  ttsSettings: DEFAULT_TTS,
  playback: DEFAULT_PLAYBACK,
  glossary: "",
  llmConfig: DEFAULT_LLM_CONFIG,
  updateConfig: DEFAULT_UPDATE_CONFIG,
  updateInfo: undefined,

  audioSources: [
    { id: "dual", label: "双路混合（电脑播放声 + 麦克风说话声）", kind: "dual_mix" },
    { id: "mic", label: "默认麦克风（录人声说话）", kind: "microphone" },
    { id: "sys", label: "系统声音内录（仅录电脑播放的声音）", kind: "system_loopback" },
  ],
  audioLevel: 0,
  sessionError: null,
  sessionNotice: null,
  speakingSegmentId: null,
  lastSpokenSegmentId: null,
  preparingCloneSegmentId: null,
  cloneStates: {},
  outputDevices: [],
  inputDevices: [],
  hasMyVoiceSample: false,
  seekNonce: 0,
  seekTargetMs: 0,
  searchQuery: "",
  summaryOpen: true,
  summaryTemplateId: "meeting",
  summaryMarkdown: "",
  summaryGenerating: false,
  viewMode: "home",
  historyOpen: false,
  settingsOpen: false,
  activeSettingsTab: "server",
  testingLocal: false,
  testingCloud: false,
  localServerBusy: null,
  localServerProgress: null,
  localServerMessage: null,
  localServerError: null,
  checkingUpdate: false,
  downloadingUpdate: false,
  updateDownloadProgress: null,
  updateDownloadError: null,
  importProgress: null,
  hydrated: false,

  hydrate: async () => {
    const snap = await tauriInvoke<AppSnapshot>("get_snapshot");
    if (snap) {
      set({
        ...snap,
        ttsSettings: { ...DEFAULT_TTS, ...snap.ttsSettings },
        llmConfig: { ...DEFAULT_LLM_CONFIG, ...(snap.llmConfig ?? {}) },
        hydrated: true,
      });
    } else {
      set({ hydrated: true });
    }
    const sources = await tauriInvoke<AudioSourceOption[]>("list_audio_sources");
    if (sources && sources.length > 0) {
      set({ audioSources: sources });
    }
    if (!isSubtitleWindow()) {
      await get().refreshOutputDevices();
      const hasSample = await tauriInvoke<boolean>("get_my_voice_sample_status");
      if (typeof hasSample === "boolean") {
        set({ hasMyVoiceSample: hasSample });
      }
    }
    if (isTauriRuntime() && !tauriListenersRegistered) {
      tauriListenersRegistered = true;
      const { listen } = await import("@tauri-apps/api/event");
      await listen<{ id: string; state: "cloning" | "playing" | "ready" }>(
        "tts:state",
        (ev) => {
          const { id, state: ttsState } = ev.payload;
          if (ttsState === "cloning") {
            set((s) => ({
              cloneStates: { ...s.cloneStates, [id]: "cloning" },
              preparingCloneSegmentId: id,
            }));
          } else if (ttsState === "playing") {
            set((s) => ({
              cloneStates: { ...s.cloneStates, [id]: "ready" },
              preparingCloneSegmentId:
                s.preparingCloneSegmentId === id ? null : s.preparingCloneSegmentId,
              speakingSegmentId: id,
              lastSpokenSegmentId: id,
            }));
          } else {
            set((s) => ({
              cloneStates: { ...s.cloneStates, [id]: "ready" },
              preparingCloneSegmentId:
                s.preparingCloneSegmentId === id ? null : s.preparingCloneSegmentId,
              speakingSegmentId:
                s.speakingSegmentId === id ? null : s.speakingSegmentId,
            }));
          }
        }
      );
      await listen<SubtitleSegment>("segment:upsert", (ev) => {
        set((state) => {
          const idx = state.segments.findIndex((s) => s.id === ev.payload.id);
          if (idx >= 0) {
            const next = state.segments.slice();
            next[idx] = ev.payload;
            return { segments: next };
          }
          return { segments: [...state.segments, ev.payload] };
        });
        // 对标 iOS：句子翻译完成时自动在后台发起 Qwen3-TTS 声音克隆预合成，驱动小喇叭从「克隆中」变为「声音准备好了」
        const seg = ev.payload;
        // 悬浮字幕窗口（subtitle.html）只负责展示，绝不触发自动朗读或预克隆，避免主窗+字幕窗各播一遍！
        if (
          !isSubtitleWindow() &&
          seg.status === "final" &&
          seg.translatedText.trim() &&
          seg.translatedText !== "翻译中…"
        ) {
          const tts = get().ttsSettings;
          const isRecording = get().mode === "recording";
          const autoMyMic =
            isRecording && tts.enabled && tts.autoSpeakMyMic && seg.channel === "mic";
          const autoOther =
            isRecording && tts.enabled && tts.autoSpeakOther && seg.channel === "system";
          if (autoMyMic || autoOther) {
            // 每条对话只自动播报一次，防止 Whisper 二次精修或重复事件导致同一句反复朗读
            if (autoSpokenSegmentIds.has(seg.id)) {
              return;
            }
            autoSpokenSegmentIds.add(seg.id);
            if (tts.useVoiceClone) {
              const target =
                tts.routingMode === "meeting" && seg.channel === "mic"
                  ? "meeting_mic"
                  : "local";
              set((s) => ({
                cloneStates: { ...s.cloneStates, [seg.id]: "cloning" },
              }));
              void tauriInvoke("play_cloned_segment_to_device", {
                id: seg.id,
                text: seg.translatedText.trim(),
                lang: seg.targetLang,
                target,
                isAuto: true,
              }).catch(() => {
                set((s) => ({
                  cloneStates: { ...s.cloneStates, [seg.id]: "ready" },
                  speakingSegmentId:
                    s.speakingSegmentId === seg.id ? null : s.speakingSegmentId,
                }));
                // 克隆失败/超时时自动降级到系统语音朗读，确保会议同传不会静默无声
                if (get().mode === "recording" && get().ttsSettings.enabled) {
                  void get().speakSegment(
                    seg.id,
                    seg.translatedText.trim(),
                    seg.targetLang,
                    { fromResume: true }
                  );
                }
              });
            } else {
              // 声音克隆已关闭：严格使用系统语音朗读译文，传 fromResume: true 避免误把自动朗读总开关关掉
              void get().speakSegment(
                seg.id,
                seg.translatedText.trim(),
                seg.targetLang,
                { fromResume: true }
              );
            }
          } else if (tts.useVoiceClone) {
            const trText = seg.translatedText.trim();
            // 后台自动预克隆跳过 <= 2 字的极短词（如「好」「嗯」「OK」），避免占满单并发克隆队列；用户手动点击小喇叭仍可按需合成/朗读
            const cleanLen = trText.replace(/[\s\p{P}\p{S}]/gu, "").length;
            if (cleanLen > 2) {
              void get().prepareSegmentClone(seg.id, trText, seg.targetLang, true);
            } else {
              set((s) => ({ cloneStates: { ...s.cloneStates, [seg.id]: "ready" } }));
            }
          }
        }
      });
      await listen<{ source: string; translation: string }>("subtitle:partial", (ev) => {
        set({
          livePartialSource: ev.payload.source,
          livePartialTranslation: ev.payload.translation,
        });
      });
      await listen<{ positionMs: number; durationMs: number; isPlaying: boolean }>(
        "playback:tick",
        (ev) => {
          set((state) => ({
            playback: {
              ...state.playback,
              positionMs: ev.payload.positionMs,
              durationMs: ev.payload.durationMs,
              isPlaying: ev.payload.isPlaying,
            },
          }));
        }
      );
      await listen<ServiceProbeResult>("service:local_status", (ev) => {
        set({ localStatus: ev.payload });
      });
      await listen<ServiceProbeResult>("service:cloud_status", (ev) => {
        set({ cloudStatus: ev.payload });
      });
      await listen<LocalServerInstallStatus>("local_server:install_status", (ev) => {
        set({ localServerInstall: ev.payload });
      });
      await listen<LocalServerProgress>("local_server:progress", (ev) => {
        set({ localServerProgress: ev.payload });
      });
      await listen<SubtitleStyle>("subtitle:style", (ev) => {
        set({ subtitleStyle: ev.payload });
      });
      await listen<UpdateCheckResult>("update:info", (ev) => {
        set({ updateInfo: ev.payload });
      });
      await listen<{ downloaded: number; total: number }>("update:progress", (ev) => {
        set({ updateDownloadProgress: ev.payload });
      });
      await listen<number>("audio:level", (ev) => {
        set({ audioLevel: ev.payload });
      });
      await listen<SessionMode>("session:mode", (ev) => {
        set((s) => ({
          mode: ev.payload,
          viewMode:
            ev.payload === "recording" ||
            ev.payload === "paused" ||
            ev.payload === "batch_processing"
              ? "workspace"
              : s.viewMode,
        }));
      });
      await listen<string>("session:error", (ev) => {
        set({ sessionError: ev.payload });
      });
      await listen<string>("session:notice", (ev) => {
        set({ sessionNotice: ev.payload });
      });
      await listen<RecordingPlaybackState>("recording:ready", (ev) => {
        set({ playback: ev.payload });
      });
      await listen<{ durationMs: number; peaks: number[] }>("recording:live_tick", (ev) => {
        set((state) => ({
          playback: {
            ...state.playback,
            durationMs: ev.payload.durationMs,
            peaks: ev.payload.peaks,
          },
        }));
      });
      await listen<string>("summary:delta", (ev) => {
        set({ summaryMarkdown: ev.payload, summaryOpen: true });
      });
      await listen<ConversationMeta[]>("history:updated", (ev) => {
        set({ conversations: ev.payload });
      });
      await listen<{ current: number; total: number; active: boolean }>(
        "import:progress",
        (ev) => {
          set({
            importProgress: ev.payload.active ? ev.payload : null,
          });
        }
      );
      await listen("shortcut:copy_latest", () => {
        const segs = get().segments;
        const last = segs[segs.length - 1];
        if (!last) return;
        const text = last.translatedText || last.sourceText;
        if (text) {
          void navigator.clipboard?.writeText(text);
        }
      });
    }
    // 主窗口启动监听就绪后，主动触发一次服务健康检测，避免错过 Rust 启动早期发出的状态事件导致首页显示未就绪
    if (!isSubtitleWindow() && isTauriRuntime()) {
      const cfg = get().serviceConfig;
      if (cfg.localServiceAddress?.trim() && !get().localStatus.ok) {
        void get().testServiceConnection("local");
      }
      if (cfg.cloudServiceAddress?.trim() && !get().cloudStatus.ok) {
        void get().testServiceConnection("cloud");
      }
    }
  },

  clearSessionError: () => set({ sessionError: null }),
  clearSessionNotice: () => set({ sessionNotice: null }),
  setSearchQuery: (searchQuery) => set({ searchQuery }),
  setSummaryOpen: (summaryOpen) => set({ summaryOpen }),
  setSummaryTemplateId: (summaryTemplateId) => set({ summaryTemplateId }),
  setViewMode: (viewMode) => set({ viewMode }),
  backToHome: async () => {
    stopActiveCloneAudio();
    if (get().playback.isPlaying) {
      await get().setPlaybackPlaying(false);
    }
    if (get().mode === "recording" || get().mode === "paused") {
      await get().stopRecording();
    }
    set({ viewMode: "home", historyOpen: false });
  },
  setHistoryOpen: (historyOpen) => set({ historyOpen }),
  setSettingsOpen: (settingsOpen, tab) =>
    set((s) => ({ settingsOpen, activeSettingsTab: tab ?? s.activeSettingsTab })),

  loadConversation: async (id) => {
    stopActiveCloneAudio();
    cloneWavCache.clear();
    cloneInflight.clear();
    autoSpokenSegmentIds.clear();
    set({ sessionError: null, sessionNotice: null, cloneStates: {} });
    try {
      const conv = await tauriInvoke<SavedConversation>("load_conversation", { id });
      if (conv) {
        set({
          viewMode: "workspace",
          activeConversationId: conv.meta.id,
          mode: "idle",
          segments: conv.segments,
          summaryMarkdown: conv.summaryMarkdown || "",
          summaryOpen: true,
          playback: {
            ...conv.playback,
            isPlaying: false,
            positionMs: 0,
          },
          livePartialSource: "",
          livePartialTranslation: "",
          historyOpen: false,
        });
      }
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  renameConversation: async (id, title) => {
    try {
      const metas = await tauriInvoke<ConversationMeta[]>("rename_conversation", {
        id,
        title,
      });
      if (metas) {
        set({ conversations: metas });
      }
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  deleteConversation: async (id) => {
    try {
      const wasActive = get().activeConversationId === id;
      const metas = await tauriInvoke<ConversationMeta[]>("delete_conversation", { id });
      if (metas) {
        set({
          conversations: metas,
          ...(wasActive
            ? {
                segments: [],
                summaryMarkdown: "",
                playback: DEFAULT_PLAYBACK,
                livePartialSource: "",
                livePartialTranslation: "",
              }
            : {}),
        });
      }
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  setLanguagePair: async (sourceLang, targetLang, lockSourceLang) => {
    set({ sourceLang, targetLang, lockSourceLang });
    await tauriInvoke("set_language_pair", { sourceLang, targetLang, lockSourceLang });
  },

  setCaptureMode: async (captureMode, selectedAppPid) => {
    set({ captureMode, selectedAppPid, sessionNotice: null });
    await tauriInvoke("set_capture_mode", { captureMode, selectedAppPid });
  },

  startRecording: async (fresh = false) => {
    set({
      sessionError: null,
      sessionNotice: null,
      viewMode: "workspace",
      summaryOpen: true,
    });
    if (fresh) {
      await get().clearRecording();
    }
    if (!isTauriRuntime()) {
      set({ mode: "recording", viewMode: "workspace" });
      return;
    }
    try {
      // 仅在「会议同传 + 正在录音」时启用系统虚拟声卡；开始录音前先拉起虚拟声卡并绑定两路通道
      if (get().ttsSettings.routingMode === "meeting") {
        await tauriInvoke("set_virtual_cables_os_enabled", { enabled: true }).catch(() => {});
        await new Promise((r) => window.setTimeout(r, 450));
        await get().refreshOutputDevices();
        await get().activateMeetingMode();
      }
      const mode = await tauriInvoke<SessionMode>("start_recording");
      if (mode) set({ mode, viewMode: "workspace" });
    } catch (err) {
      set({
        mode: "idle",
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  pauseRecording: async () => {
    if (!isTauriRuntime()) {
      set({ mode: "paused" });
      return;
    }
    try {
      const mode = await tauriInvoke<SessionMode>("pause_recording");
      if (mode) set({ mode });
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  resumeRecording: async () => {
    set({ sessionError: null, sessionNotice: null });
    if (!isTauriRuntime()) {
      set({ mode: "recording" });
      return;
    }
    try {
      const mode = await tauriInvoke<SessionMode>("resume_recording");
      if (mode) set({ mode });
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  stopRecording: async () => {
    if (!isTauriRuntime()) {
      set({ mode: "idle" });
      return;
    }
    try {
      const mode = await tauriInvoke<SessionMode>("stop_recording");
      if (mode) set({ mode });
    } catch (err) {
      set({
        mode: "idle",
        sessionError: err instanceof Error ? err.message : String(err),
      });
    } finally {
      // 关闭录音后自动禁用虚拟声卡（同时在 Windows 声音设备中禁用，确保仅在同传+录音期间生效）
      await get().deactivateMeetingVirtualCables(false);
    }
  },

  toggleRecording: async () => {
    set({ sessionError: null, sessionNotice: null });
    if (!isTauriRuntime()) {
      const nextMode: SessionMode = get().mode === "recording" ? "paused" : "recording";
      set({ mode: nextMode });
      return;
    }
    try {
      const mode = await tauriInvoke<SessionMode>("toggle_recording");
      if (mode) {
        set({ mode });
      }
    } catch (err) {
      set({
        mode: "idle",
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  clearRecording: async () => {
    set({
      segments: [],
      livePartialSource: "",
      livePartialTranslation: "",
      summaryMarkdown: "",
      sessionError: null,
      sessionNotice: null,
      playback: DEFAULT_PLAYBACK,
    });
    await tauriInvoke("clear_recording");
  },

  seekPlayback: async (ms, autoPlay = true) => {
    set((s) => {
      const clamped = Math.max(0, Math.min(ms, s.playback.durationMs || ms));
      return {
        seekNonce: s.seekNonce + 1,
        seekTargetMs: clamped,
        playback: {
          ...s.playback,
          positionMs: clamped,
          isPlaying: autoPlay ? true : s.playback.isPlaying,
        },
      };
    });
    await tauriInvoke("seek_playback", { positionMs: Math.floor(ms), autoPlay });
  },

  togglePlayback: async () => {
    const playing = !get().playback.isPlaying;
    await get().setPlaybackPlaying(playing);
  },

  setPlaybackPlaying: async (playing) => {
    set((s) => ({ playback: { ...s.playback, isPlaying: playing } }));
    await tauriInvoke("set_playback_playing", { playing });
  },

  syncPlaybackPosition: (ms) => {
    set((s) => ({
      playback: {
        ...s.playback,
        positionMs: Math.max(0, Math.min(ms, s.playback.durationMs || ms)),
      },
    }));
  },

  readRecordingAudio: async () => {
    if (!isTauriRuntime()) return null;
    const raw = await tauriInvoke<ArrayBuffer | Uint8Array>("read_recording_audio");
    if (!raw) return null;
    return raw instanceof Uint8Array ? raw : new Uint8Array(raw);
  },

  setPlaybackSpeed: (speed) => {
    set((s) => ({ playback: { ...s.playback, speed } }));
    void tauriInvoke("set_playback_speed", { speed });
  },

  setTrackVolumes: (systemVolume, micVolume) => {
    set((s) => ({ playback: { ...s.playback, systemVolume, micVolume } }));
    void tauriInvoke("set_track_volumes", { systemVolume, micVolume });
  },

  updateSubtitleStyle: async (patch) => {
    const next = { ...get().subtitleStyle, ...patch };
    set({ subtitleStyle: next });
    await tauriInvoke("set_subtitle_style", { style: next });
  },

  toggleSubtitleVisible: async () => {
    const next = !get().subtitleStyle.visible;
    await get().updateSubtitleStyle({ visible: next });
  },

  saveServiceConfig: async (patch) => {
    if (!get().hydrated) {
      await get().hydrate();
    }
    const merged: ServiceConfig = { ...get().serviceConfig, ...patch };
    set({ serviceConfig: merged });
    const saved = await tauriInvoke<ServiceConfig>("save_service_config", {
      config: merged,
    });
    return saved ?? merged;
  },

  testServiceConnection: async (target, overrideAddress, overrideToken) => {
    const cfg = get().serviceConfig;
    const address =
      overrideAddress ??
      (target === "local" ? cfg.localServiceAddress : cfg.cloudServiceAddress);
    const accessToken =
      overrideToken ??
      (target === "local" ? cfg.localAccessToken : cfg.cloudAccessToken);

    if (target === "local") set({ testingLocal: true });
    else set({ testingCloud: true });

    try {
      const result = await tauriInvoke<ServiceProbeResult>("test_service_connection", {
        target,
        address,
        accessToken,
      });
      if (result) {
        if (target === "local") set({ localStatus: result });
        else set({ cloudStatus: result });
      }
      return result;
    } finally {
      if (target === "local") set({ testingLocal: false });
      else set({ testingCloud: false });
    }
  },

  refreshLocalServerInstallStatus: async () => {
    const status = await tauriInvoke<LocalServerInstallStatus>(
      "get_local_server_install_status"
    );
    if (status) set({ localServerInstall: status });
  },

  installLocalServer: async () => {
    set({
      localServerBusy: "install",
      localServerError: null,
      localServerMessage: null,
      localServerProgress: {
        action: "install",
        stage: "checking",
        downloaded: 0,
        total: 0,
        message: "正在准备安装本机模型服务…",
      },
    });
    try {
      const status = await tauriInvoke<LocalServerInstallStatus>("install_local_server");
      if (status) {
        set({
          localServerInstall: status,
          localServerMessage: `本机模型服务${
            status.installedVersion ? ` v${status.installedVersion}` : ""
          } 已安装完成（内置 faster-whisper / sherpa-onnx）`,
        });
      }
    } catch (err) {
      set({
        localServerError: err instanceof Error ? err.message : String(err),
      });
    } finally {
      set({ localServerBusy: null, localServerProgress: null });
    }
  },

  reinstallLocalServer: async () => {
    set({
      localServerBusy: "reinstall",
      localServerError: null,
      localServerMessage: null,
      localServerProgress: {
        action: "reinstall",
        stage: "checking",
        downloaded: 0,
        total: 0,
        message: "正在准备重新安装本机模型服务（保留已下载模型）…",
      },
    });
    try {
      const status = await tauriInvoke<LocalServerInstallStatus>("reinstall_local_server");
      if (status) {
        set({
          localServerInstall: status,
          localServerMessage: `本机模型服务${
            status.installedVersion ? ` v${status.installedVersion}` : ""
          } 已重新安装完成（原有模型文件已保留）`,
        });
      }
    } catch (err) {
      set({
        localServerError: err instanceof Error ? err.message : String(err),
      });
    } finally {
      set({ localServerBusy: null, localServerProgress: null });
    }
  },

  uninstallLocalServer: async (removeModels) => {
    set({
      localServerBusy: "uninstall",
      localServerError: null,
      localServerMessage: null,
    });
    try {
      const status = await tauriInvoke<LocalServerInstallStatus>("uninstall_local_server", {
        removeModels,
      });
      if (status) {
        set({
          localServerInstall: status,
          localServerMessage: removeModels
            ? "已彻底卸载本机模型服务及已下载的模型文件"
            : "已卸载本机模型服务（已下载的模型权重文件已保留）",
        });
      }
    } catch (err) {
      set({
        localServerError: err instanceof Error ? err.message : String(err),
      });
    } finally {
      set({ localServerBusy: null });
    }
  },

  openLocalServerDir: async () => {
    try {
      await tauriInvoke("open_local_server_dir");
    } catch (err) {
      set({
        localServerError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  openLogsDir: async () => {
    try {
      await tauriInvoke("open_logs_dir");
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  saveLlmConfig: async (patch) => {
    if (!get().hydrated) {
      await get().hydrate();
    }
    const merged: LlmApiConfig = { ...get().llmConfig, ...patch };
    set({ llmConfig: merged });
    const saved = await tauriInvoke<LlmApiConfig>("save_llm_config", {
      config: merged,
    });
    return saved ?? merged;
  },

  fetchLlmModels: async (provider, baseUrl, apiKey) => {
    const res = await tauriInvoke<string[]>("fetch_llm_models", {
      provider,
      baseUrl,
      apiKey,
    });
    return res ?? [];
  },

  saveUpdateConfig: async (patch) => {
    const merged: UpdateConfig = { ...get().updateConfig, ...patch };
    set({ updateConfig: merged });
    const saved = await tauriInvoke<UpdateConfig>("save_update_config", {
      config: merged,
    });
    return saved ?? merged;
  },

  checkForUpdates: async (override) => {
    set({
      checkingUpdate: true,
      updateDownloadError: null,
      ...(override ? { updateConfig: override } : {}),
    });
    try {
      const res = await tauriInvoke<UpdateCheckResult>("check_for_updates", {
        overrideConfig: override ?? null,
      });
      if (res) set({ updateInfo: res });
      return res;
    } finally {
      set({ checkingUpdate: false });
    }
  },

  downloadAndInstallUpdate: async () => {
    set({
      downloadingUpdate: true,
      updateDownloadError: null,
      updateDownloadProgress: { downloaded: 0, total: get().updateInfo?.assetSize ?? 0 },
    });
    try {
      await tauriInvoke<string>("download_and_install_update");
    } catch (err) {
      set({
        updateDownloadError:
          err instanceof Error ? err.message : String(err),
      });
    } finally {
      set({ downloadingUpdate: false });
    }
  },

  openGithubUrl: async (url) => {
    if (isTauriRuntime()) {
      await tauriInvoke("open_github_url", { url });
    } else {
      window.open(url, "_blank", "noopener,noreferrer");
    }
  },

  updateTtsSettings: (patch) => {
    const next = { ...get().ttsSettings, ...patch };
    set({ ttsSettings: next });
    void tauriInvoke("set_tts_settings", { settings: next });
    if (patch.useVoiceClone === false) {
      // 关闭声音克隆时立即清空所有克隆缓存并终止正在排队/播放的克隆音频
      cloneWavCache.clear();
      cloneInflight.clear();
      stopActiveCloneAudio();
      if (isTauriRuntime()) {
        void tauriInvoke("stop_device_tts");
      }
      set({ cloneStates: {}, preparingCloneSegmentId: null });
    }
    if (patch.enabled === false) {
      get().stopSpeakingSegment();
    }
  },

  setGlossary: (glossary) => {
    set({ glossary });
    void tauriInvoke("set_glossary", { glossary });
  },

  editSegmentSource: async (id, newSource) => {
    set((s) => ({
      segments: s.segments.map((seg) =>
        seg.id === id
          ? {
              ...seg,
              sourceText: newSource,
              baselineTranslated: seg.baselineTranslated ?? seg.translatedText,
              status: "correcting",
              isEdited: true,
            }
          : seg
      ),
    }));
    try {
      await tauriInvoke("retranslate_segment", { id, newSource });
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  editSegmentTranslation: async (id, newTranslation) => {
    set((s) => ({
      segments: s.segments.map((seg) =>
        seg.id === id
          ? {
              ...seg,
              baselineTranslated: seg.baselineTranslated ?? seg.translatedText,
              translatedText: newTranslation,
              status: "final",
              isEdited: true,
            }
          : seg
      ),
    }));
    await tauriInvoke("update_segment_translation", { id, newTranslation });
  },

  editSegmentSpeaker: async (id, speakerLabel, applyToSameSpeaker) => {
    const clean = speakerLabel.trim();
    set((s) => {
      const target = s.segments.find((seg) => seg.id === id);
      if (!target) return {};
      return {
        segments: s.segments.map((seg) => {
          const match =
            seg.id === id ||
            (applyToSameSpeaker &&
              seg.channel === target.channel &&
              seg.speakerLabel === target.speakerLabel);
          return match ? { ...seg, speakerLabel: clean || undefined } : seg;
        }),
      };
    });
    await tauriInvoke("update_segment_speaker", {
      id,
      speakerLabel: clean,
      applyToSameSpeaker,
    });
  },

  prepareSegmentClone: async (id, text, lang, isPreclone = false) => {
    const trimmed = text.trim();
    if (!trimmed || !isTauriRuntime()) return null;
    const cached = cloneWavCache.get(id);
    if (cached && cached.text === trimmed) {
      if (get().cloneStates[id] !== "ready") {
        set((s) => ({ cloneStates: { ...s.cloneStates, [id]: "ready" } }));
      }
      return cached.wav;
    }
    const existing = cloneInflight.get(id);
    if (existing && existing.text === trimmed) {
      return existing.promise;
    }
    set((s) => ({ cloneStates: { ...s.cloneStates, [id]: "cloning" } }));
    const entry: { text: string; promise: Promise<Uint8Array | null> } = {
      text: trimmed,
      promise: Promise.resolve(null),
    };
    const promise = (async (): Promise<Uint8Array | null> => {
      try {
        const raw = await tauriInvoke<ArrayBuffer | Uint8Array>(
          "clone_segment_speech",
          {
            id,
            text: trimmed,
            lang,
            isPreclone,
          }
        );
        // 若期间 Whisper 二次校对或手动修改已发起更新版本的克隆任务，丢弃过期结果，避免覆盖新译文缓存
        if (cloneInflight.get(id) !== entry) {
          return null;
        }
        if (raw) {
          const bytes = raw instanceof Uint8Array ? raw : new Uint8Array(raw);
          if (bytes.byteLength > 44) {
            const copy = new Uint8Array(bytes.byteLength);
            copy.set(bytes);
            cloneWavCache.set(id, { text: trimmed, wav: copy });
            set((s) => ({ cloneStates: { ...s.cloneStates, [id]: "ready" } }));
            return copy;
          }
        }
      } catch {
        // 克隆不可用时标记为 ready，点击小喇叭会平滑使用系统语音播放
      } finally {
        if (cloneInflight.get(id) === entry) {
          cloneInflight.delete(id);
        }
      }
      if (cloneInflight.get(id) === undefined) {
        set((s) => ({ cloneStates: { ...s.cloneStates, [id]: "ready" } }));
      }
      return null;
    })();
    entry.promise = promise;
    cloneInflight.set(id, entry);
    return promise;
  },

  playSegmentOriginal: async (id) => {
    // 仅在结束录音后或查看历史会话（idle 状态）允许播放原文原音，实时录音期间绝不外放原音导致回环重录
    if (get().mode !== "idle") return;
    const seg = get().segments.find((s) => s.id === id);
    if (!seg) return;
    get().stopSpeakingSegment();
    // 若整轨音频就绪，直接定位到底部播放器对应位置播放原文原音
    if (get().playback.hasAudio) {
      await get().seekPlayback(seg.startMs, true);
      return;
    }
    // 录制过程中（或未开启整轨回放）：从后端内存/切片读取该句原始 16kHz 录音并直接播放原音
    if (isTauriRuntime()) {
      try {
        const raw = await tauriInvoke<ArrayBuffer | Uint8Array>(
          "read_segment_original_wav",
          { id }
        );
        if (raw) {
          const bytes = raw instanceof Uint8Array ? raw : new Uint8Array(raw);
          if (bytes.byteLength > 44) {
            const copy = new Uint8Array(bytes.byteLength);
            copy.set(bytes);
            const blob = new Blob([copy.buffer], { type: "audio/wav" });
            const url = URL.createObjectURL(blob);
            activeCloneUrl = url;
            const audio = new Audio(url);
            activeCloneAudio = audio;
            audio.onended = () => {
              stopActiveCloneAudio();
            };
            audio.onerror = () => {
              stopActiveCloneAudio();
            };
            await audio.play();
            return;
          }
        }
      } catch {
        // ignore and fallback
      }
    }
  },

  speakSegment: async (id, text, lang, options) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    if (get().speakingSegmentId === id) {
      get().stopSpeakingSegment();
      return;
    }
    // 用户手动点击某句译文播放时：自动将顶栏「自动朗读译文」置为暂停状态，
    // 方便用户专心回听该句；之后再次点开「自动朗读译文」时会从本句的下一行继续往下播
    if (!options?.fromResume && get().ttsSettings.enabled) {
      void get().updateTtsSettings({ enabled: false });
    }
    stopActiveCloneAudio();
    if (typeof window !== "undefined" && "speechSynthesis" in window) {
      window.speechSynthesis.cancel();
    }
    set({ speakingSegmentId: id, lastSpokenSegmentId: id });

    // 若开启了 Qwen3-TTS 原声克隆且在桌面端，优先使用指定设备输出（会议虚拟麦 / 物理耳机 / 面对面自动静音麦）
    if (isTauriRuntime() && get().ttsSettings.useVoiceClone) {
      const tts = get().ttsSettings;
      const seg = get().segments.find((s) => s.id === id);
      const needsDeviceRoute =
        tts.routingMode === "meeting" ||
        (tts.outputDeviceId && tts.outputDeviceId !== "default") ||
        get().mode === "recording";

      if (needsDeviceRoute) {
        // 若该句已经克隆完成（小喇叭就绪），不再显示「克隆中…」，后端将 0ms 命中缓存直接播放
        const alreadyReady =
          get().cloneStates[id] === "ready" ||
          cloneWavCache.get(id)?.text === trimmed;
        set({
          speakingSegmentId: alreadyReady ? id : null,
          preparingCloneSegmentId: alreadyReady ? null : id,
        });
        try {
          const target =
            tts.routingMode === "meeting" && seg?.channel === "mic"
              ? "meeting_mic"
              : "local";
          await tauriInvoke("play_cloned_segment_to_device", {
            id,
            text: trimmed,
            lang,
            target,
          });
          if (get().speakingSegmentId === id) {
            set({ speakingSegmentId: null });
          }
          return;
        } catch {
          // 克隆超时/失败时立刻清理播放与克隆中状态，直接降级到下方系统语音朗读，不再二次重复克隆或卡死在「播放中」
          set((s) => ({
            preparingCloneSegmentId:
              s.preparingCloneSegmentId === id ? null : s.preparingCloneSegmentId,
            speakingSegmentId:
              s.speakingSegmentId === id ? null : s.speakingSegmentId,
            sessionNotice: "声音克隆服务响应超时，已自动改用系统语音朗读",
          }));
        }
      } else {
        set({ preparingCloneSegmentId: id });
        try {
          const wav = await get().prepareSegmentClone(id, trimmed, lang);
          if (get().preparingCloneSegmentId === id) {
            set({ preparingCloneSegmentId: null });
          }
          if (wav && wav.byteLength > 44 && get().speakingSegmentId === id) {
            const copy = new Uint8Array(wav.byteLength);
            copy.set(wav);
            const blob = new Blob([copy.buffer], { type: "audio/wav" });
            const url = URL.createObjectURL(blob);
            activeCloneUrl = url;
            const audio = new Audio(url);
            activeCloneAudio = audio;
            const muteMic =
              get().ttsSettings.muteMicWhileSpeaking && get().mode === "recording";
            if (muteMic) void tauriInvoke("set_mic_muted", { muted: true });
            const releaseMute = () => {
              if (muteMic) {
                window.setTimeout(() => {
                  void tauriInvoke("set_mic_muted", { muted: false });
                }, 220);
              }
            };
            audio.onended = () => {
              stopActiveCloneAudio();
              releaseMute();
              if (get().speakingSegmentId === id) set({ speakingSegmentId: null });
            };
            audio.onerror = () => {
              stopActiveCloneAudio();
              releaseMute();
              if (get().speakingSegmentId === id) set({ speakingSegmentId: null });
            };
            await audio.play();
            return;
          }
        } catch {
          if (get().preparingCloneSegmentId === id) {
            set({ preparingCloneSegmentId: null });
          }
        }
      }
    }

    set({ speakingSegmentId: id });
    const guardLoopback = isTauriRuntime() && get().mode === "recording";
    const startSystemGuard = () => {
      if (guardLoopback) {
        void tauriInvoke("set_system_tts_muted", {
          muted: true,
          spokenText: trimmed,
        });
      }
    };
    const endSystemGuard = () => {
      if (guardLoopback) {
        void tauriInvoke("set_system_tts_muted", {
          muted: true,
          spokenText: trimmed,
        });
        window.setTimeout(() => {
          void tauriInvoke("set_system_tts_muted", {
            muted: false,
            spokenText: null,
          });
        }, 400);
      }
    };

    const bcp47Map: Record<string, string> = {
      zh: "zh-CN",
      en: "en-US",
      ja: "ja-JP",
      ko: "ko-KR",
      fr: "fr-FR",
      de: "de-DE",
      es: "es-ES",
    };
    const targetBcp = bcp47Map[lang] ?? "zh-CN";
    // Windows Tauri 桌面端优先使用原生 SAPI（speak_text_sapi），规避 Edge WebView2 speechSynthesis 偶发静默无声且不触发 onend 导致卡在「播放中」的问题
    if (!isTauriRuntime() && typeof window !== "undefined" && "speechSynthesis" in window) {
      const voices = window.speechSynthesis.getVoices();
      const matched = voices.find((v) =>
        v.lang.toLowerCase().startsWith(lang.toLowerCase())
      );
      if (voices.length > 0) {
        const utter = new SpeechSynthesisUtterance(trimmed);
        utter.lang = targetBcp;
        if (matched) utter.voice = matched;
        utter.onend = () => {
          endSystemGuard();
          if (get().speakingSegmentId === id) set({ speakingSegmentId: null });
        };
        utter.onerror = () => {
          endSystemGuard();
          if (get().speakingSegmentId === id) set({ speakingSegmentId: null });
        };
        startSystemGuard();
        window.speechSynthesis.speak(utter);
        return;
      }
    }
    try {
      startSystemGuard();
      await tauriInvoke("speak_text_sapi", {
        text: trimmed,
        lang: targetBcp,
        segmentId: id,
      });
    } finally {
      endSystemGuard();
      if (get().speakingSegmentId === id) {
        set({ speakingSegmentId: null });
      }
    }
  },

  stopSpeakingSegment: () => {
    stopActiveCloneAudio();
    if (isTauriRuntime()) {
      void tauriInvoke("stop_device_tts");
    }
    if (typeof window !== "undefined" && "speechSynthesis" in window) {
      window.speechSynthesis.cancel();
    }
    set({ speakingSegmentId: null, preparingCloneSegmentId: null });
  },

  resumeAutoSpeakFromNext: async () => {
    const { segments, lastSpokenSegmentId, targetLang } = get();
    if (segments.length === 0) return;
    const foundIdx = lastSpokenSegmentId
      ? segments.findIndex((s) => s.id === lastSpokenSegmentId)
      : -1;
    const startIdx = foundIdx >= 0 ? foundIdx + 1 : 0;
    const queue = segments
      .slice(startIdx)
      .filter(
        (s) =>
          s.translatedText.trim().length > 0 &&
          s.translatedText.trim() !== s.sourceText.trim()
      );
    for (const seg of queue) {
      if (!get().ttsSettings.enabled) break;
      autoSpokenSegmentIds.add(seg.id);
      await get().speakSegment(
        seg.id,
        seg.translatedText,
        seg.targetLang || targetLang,
        { fromResume: true }
      );
    }
  },

  refreshOutputDevices: async () => {
    if (!isTauriRuntime()) return;
    try {
      const [devices, inputs] = await Promise.all([
        tauriInvoke<OutputAudioDevice[]>("list_output_devices"),
        tauriInvoke<OutputAudioDevice[]>("list_input_devices"),
      ]);
      if (inputs) {
        set({ inputDevices: inputs });
      }
      if (devices) {
        set({ outputDevices: devices });
        // 优先选择标准 2 声道虚拟声卡（跳过 CABLE In 16ch），且绝不与另一路会议监听设备冲突
        const tts = get().ttsSettings;
        const standardVirtuals = devices.filter(
          (d) => d.isVirtual && !d.name.toLowerCase().includes("16ch")
        );
        // 若之前误存了 16ch 且存在标准 CABLE Input，自动迁移到标准设备（面对面模式绝不自动启用虚拟声卡）
        let patched = { ...tts };
        let changed = false;
        if (
          patched.meetingMicOutputDeviceId.toLowerCase().includes("16ch") &&
          standardVirtuals.length > 0
        ) {
          const candidate = standardVirtuals.find(
            (d) => d.id !== patched.meetingLoopbackDeviceId
          );
          patched.meetingMicOutputDeviceId = candidate ? candidate.id : "";
          changed = true;
        }
        if (
          patched.meetingLoopbackDeviceId.toLowerCase().includes("16ch") &&
          standardVirtuals.length > 0
        ) {
          const candidate = standardVirtuals.find(
            (d) => d.id !== patched.meetingMicOutputDeviceId
          );
          patched.meetingLoopbackDeviceId = candidate ? candidate.id : "";
          changed = true;
        }
        if (changed) {
          set({ ttsSettings: patched });
          void tauriInvoke("set_tts_settings", { settings: patched });
        }
      }
    } catch {
      // ignore
    }
  },

  activateMeetingMode: async () => {
    if (get().outputDevices.length === 0) {
      await get().refreshOutputDevices();
    }
    const devices = get().outputDevices;
    const standardVirtuals = devices.filter(
      (d) => d.isVirtual && !d.name.toLowerCase().includes("16ch")
    );
    const virtuals =
      standardVirtuals.length > 0
        ? standardVirtuals
        : devices.filter((d) => d.isVirtual);

    let savedLoopback = "";
    let savedMic = "";
    try {
      savedLoopback = localStorage.getItem("hear_saved_meeting_loopback") || "";
      savedMic = localStorage.getItem("hear_saved_meeting_mic") || "";
    } catch {
      // ignore
    }
    const validIds = new Set(virtuals.map((v) => v.id));
    let loopbackId = validIds.has(savedLoopback) ? savedLoopback : "";
    let micId = validIds.has(savedMic) && savedMic !== loopbackId ? savedMic : "";

    if (virtuals.length >= 2) {
      if (!loopbackId) {
        loopbackId = virtuals.find((v) => v.id !== micId)?.id || virtuals[0].id;
      }
      if (!micId) {
        micId = virtuals.find((v) => v.id !== loopbackId)?.id || "";
      }
    } else if (virtuals.length === 1) {
      if (!loopbackId && !micId) {
        micId = virtuals[0].id;
      }
    }

    const tts = get().ttsSettings;
    await get().updateTtsSettings({
      routingMode: "meeting",
      enabled: true,
      ...(tts.autoSpeakOther || tts.autoSpeakMyMic ? {} : { autoSpeakOther: true }),
      meetingLoopbackDeviceId: loopbackId,
      meetingMicOutputDeviceId: micId,
    });
  },

  deactivateMeetingVirtualCables: async (switchToFaceToFace = false) => {
    const tts = get().ttsSettings;
    try {
      if (tts.meetingLoopbackDeviceId) {
        localStorage.setItem("hear_saved_meeting_loopback", tts.meetingLoopbackDeviceId);
      }
      if (tts.meetingMicOutputDeviceId) {
        localStorage.setItem("hear_saved_meeting_mic", tts.meetingMicOutputDeviceId);
      }
    } catch {
      // ignore
    }
    await get().updateTtsSettings({
      meetingLoopbackDeviceId: "",
      meetingMicOutputDeviceId: "",
      ...(switchToFaceToFace ? { routingMode: "face_to_face" } : {}),
    });
    if (isTauriRuntime()) {
      await tauriInvoke("set_virtual_cables_os_enabled", { enabled: false }).catch(() => {});
    }
  },

  saveMyVoiceSample: async (segmentId) => {
    if (!isTauriRuntime()) return false;
    try {
      const ok = await tauriInvoke<boolean>("save_my_voice_sample", {
        segmentId: segmentId ?? null,
      });
      if (ok) {
        set({
          hasMyVoiceSample: true,
          sessionNotice: "已锁定「我的声纹样本」，会议与面对面克隆将优先复用你的声纹。",
        });
        return true;
      }
      return false;
    } catch (e) {
      set({ sessionError: String(e) });
      return false;
    }
  },

  saveRecordedMyVoiceSample: async (wavBytes, refText) => {
    if (!isTauriRuntime()) return false;
    try {
      const ok = await tauriInvoke<boolean>("save_recorded_my_voice_sample", {
        wavBytes: Array.from(wavBytes),
        refText,
      });
      if (ok) {
        set({
          hasMyVoiceSample: true,
          sessionNotice: "已保存我的固定声纹样本（本地与云端声纹克隆均可直接使用）",
        });
        return true;
      }
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
    return false;
  },

  readMyVoiceSampleWav: async () => {
    if (!isTauriRuntime()) return null;
    try {
      const raw = await tauriInvoke<ArrayBuffer | Uint8Array>("read_my_voice_sample_wav");
      if (raw) {
        const bytes = raw instanceof Uint8Array ? raw : new Uint8Array(raw);
        if (bytes.byteLength > 44) return bytes;
      }
    } catch {
      // ignore
    }
    return null;
  },

  clearMyVoiceSample: async () => {
    if (!isTauriRuntime()) return;
    await tauriInvoke("clear_my_voice_sample");
    set({ hasMyVoiceSample: false });
  },

  generateSummary: async () => {
    if (get().segments.length === 0 || get().summaryGenerating) return;
    set({
      summaryGenerating: true,
      summaryOpen: true,
      summaryMarkdown: "",
      sessionError: null,
    });
    try {
      const md = await tauriInvoke<string>("generate_summary", {
        templateId: get().summaryTemplateId,
      });
      if (typeof md === "string") {
        set({ summaryMarkdown: md });
      }
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    } finally {
      set({ summaryGenerating: false });
    }
  },

  saveSummaryMarkdown: async (markdown) => {
    const clean = markdown.trim();
    set({ summaryMarkdown: clean });
    if (isTauriRuntime()) {
      await tauriInvoke("save_summary_markdown", { markdown: clean });
    }
  },

  exportTextFile: async (defaultName, ext, filterName, content) => {
    if (isTauriRuntime()) {
      try {
        const { save } = await import("@tauri-apps/plugin-dialog");
        const dest = await save({
          title: `导出 ${filterName}`,
          defaultPath: defaultName,
          filters: [{ name: filterName, extensions: [ext] }],
        });
        if (!dest) return false;
        await tauriInvoke("export_text_file", { destPath: dest, content });
        set({ sessionNotice: `已导出至：${dest}` });
        return true;
      } catch (err) {
        set({
          sessionError: err instanceof Error ? err.message : String(err),
        });
        return false;
      }
    }
    const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = defaultName;
    a.click();
    URL.revokeObjectURL(url);
    return true;
  },

  importMediaFile: async () => {
    if (!isTauriRuntime()) return;
    set({ sessionError: null });
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const selected = await open({
        multiple: false,
        title: "选择本地音频或视频文件",
        filters: [
          {
            name: "音视频文件",
            extensions: [
              "wav",
              "mp3",
              "m4a",
              "mp4",
              "mkv",
              "flac",
              "ogg",
              "aac",
              "webm",
              "mov",
            ],
          },
        ],
      });
      if (!selected || Array.isArray(selected)) return;
      set({
        viewMode: "workspace",
        summaryOpen: true,
        segments: [],
        summaryMarkdown: "",
      });
      await tauriInvoke("import_media_file", { filePath: selected });
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  cancelImportMedia: async () => {
    await tauriInvoke("cancel_import_media");
    set({ importProgress: null });
  },

  exportRecordingWav: async () => {
    if (!isTauriRuntime() || !get().playback.hasAudio) return;
    try {
      const { save } = await import("@tauri-apps/plugin-dialog");
      const dest = await save({
        title: "导出原始 WAV 录音文件",
        defaultPath: "hear-recording.wav",
        filters: [{ name: "WAV 音频文件", extensions: ["wav"] }],
      });
      if (!dest) return;
      await tauriInvoke("export_recording_wav", { destPath: dest });
    } catch (err) {
      set({
        sessionError: err instanceof Error ? err.message : String(err),
      });
    }
  },
}));
