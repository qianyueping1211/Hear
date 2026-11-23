import { create } from "zustand";
import type {
  AppSnapshot,
  AudioCaptureMode,
  AudioSourceOption,
  ConversationMeta,
  EngineSource,
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
  muteMicWhileSpeaking: false,
  autoSpeakMyMic: false,
  autoSpeakOther: false,
  duckOriginalAudio: true,
  duckRatio: 0.25,
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
  checkForUpdates: (override?: UpdateConfig) => Promise<UpdateCheckResult | null>;
  downloadAndInstallUpdate: () => Promise<void>;
  openGithubUrl: (url: string) => Promise<void>;
  updateTtsSettings: (patch: Partial<TtsOutputSettings>) => void;
  setGlossary: (text: string) => void;

  editSegmentSource: (id: string, newSource: string) => Promise<void>;
  editSegmentTranslation: (id: string, newTranslation: string) => Promise<void>;
  editSegmentSpeaker: (
    id: string,
    speakerLabel: string,
    applyToSameSpeaker: boolean
  ) => Promise<void>;
  speakSegment: (id: string, text: string, lang: string) => Promise<void>;
  prepareSegmentClone: (
    id: string,
    text: string,
    lang: string
  ) => Promise<Uint8Array | null>;
  playSegmentOriginal: (id: string) => Promise<void>;
  stopSpeakingSegment: () => void;
  refreshOutputDevices: () => Promise<void>;
  saveMyVoiceSample: (segmentId?: string) => Promise<boolean>;
  saveRecordedMyVoiceSample: (wavBytes: Uint8Array, refText: string) => Promise<boolean>;
  readMyVoiceSampleWav: () => Promise<Uint8Array | null>;
  clearMyVoiceSample: () => Promise<void>;
  generateSummary: () => Promise<void>;
  importMediaFile: () => Promise<void>;
  cancelImportMedia: () => Promise<void>;
  exportRecordingWav: () => Promise<void>;
}

export const useHearStore = create<HearStoreState>((set, get) => ({
  appVersion: "0.1.12",
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

  hydrate: async () => {
    const snap = await tauriInvoke<AppSnapshot>("get_snapshot");
    if (snap) {
      set({ ...snap, ttsSettings: { ...DEFAULT_TTS, ...snap.ttsSettings } });
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
              });
            } else {
              // 声音克隆已关闭：严格使用系统语音朗读译文，绝不触发声音克隆
              void get().speakSegment(
                seg.id,
                seg.translatedText.trim(),
                seg.targetLang
              );
            }
          } else if (tts.useVoiceClone) {
            void get().prepareSegmentClone(
              seg.id,
              seg.translatedText.trim(),
              seg.targetLang
            );
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

  prepareSegmentClone: async (id, text, lang) => {
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
    const seg = get().segments.find((s) => s.id === id);
    if (!seg) return;
    get().stopSpeakingSegment();
    // 若已结束录音或处于历史会话且整轨音频就绪，直接定位到底部播放器对应位置播放原文原音
    if (get().mode === "idle" && get().playback.hasAudio) {
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

  speakSegment: async (id, text, lang) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    if (get().speakingSegmentId === id) {
      get().stopSpeakingSegment();
      return;
    }
    stopActiveCloneAudio();
    if (typeof window !== "undefined" && "speechSynthesis" in window) {
      window.speechSynthesis.cancel();
    }
    set({ speakingSegmentId: id });

    // 若开启了 Qwen3-TTS 原声克隆且在桌面端，优先使用指定设备输出（会议虚拟麦 / 物理耳机 / 面对面自动静音麦）
    if (isTauriRuntime() && get().ttsSettings.useVoiceClone) {
      const tts = get().ttsSettings;
      const seg = get().segments.find((s) => s.id === id);
      const needsDeviceRoute =
        tts.routingMode === "meeting" ||
        (tts.outputDeviceId && tts.outputDeviceId !== "default") ||
        get().mode === "recording";

      if (needsDeviceRoute) {
        // 先标记克隆中，等后端 tts:state=playing 事件真正开始发声时再点亮绿色播放喇叭
        set({ speakingSegmentId: null, preparingCloneSegmentId: id });
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
          return;
        } catch {
          if (get().preparingCloneSegmentId === id) {
            set({ preparingCloneSegmentId: null });
          }
        }
      }

      set({ preparingCloneSegmentId: id });
      try {
        const wav = await get().prepareSegmentClone(id, trimmed, lang);
        if (get().speakingSegmentId === id) {
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
    if (typeof window !== "undefined" && "speechSynthesis" in window) {
      const voices = window.speechSynthesis.getVoices();
      const matched = voices.find((v) =>
        v.lang.toLowerCase().startsWith(lang.toLowerCase())
      );
      if (voices.length > 0) {
        const utter = new SpeechSynthesisUtterance(trimmed);
        utter.lang = targetBcp;
        if (matched) utter.voice = matched;
        utter.onend = () => {
          if (get().speakingSegmentId === id) set({ speakingSegmentId: null });
        };
        utter.onerror = () => {
          if (get().speakingSegmentId === id) set({ speakingSegmentId: null });
        };
        window.speechSynthesis.speak(utter);
        return;
      }
    }
    try {
      await tauriInvoke("speak_text_sapi", { text: trimmed });
    } finally {
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
        // 如果用户还没选过会议虚拟麦，且系统里检测到了 VB-Cable / Virtual 设备，自动预填方便一键开启会议同传
        const tts = get().ttsSettings;
        if (!tts.meetingMicOutputDeviceId) {
          const virt = devices.find((d) => d.isVirtual);
          if (virt) {
            const next = { ...tts, meetingMicOutputDeviceId: virt.id };
            set({ ttsSettings: next });
            void tauriInvoke("set_tts_settings", { settings: next });
          }
        }
      }
    } catch {
      // ignore
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
