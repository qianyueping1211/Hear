import { create } from "zustand";
import type {
  AppSnapshot,
  AudioCaptureMode,
  AudioSourceOption,
  ConversationMeta,
  EngineSource,
  LocalServerInstallStatus,
  LocalServerProgress,
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
  outputDeviceId: "default",
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
  stopSpeakingSegment: () => void;
  generateSummary: () => Promise<void>;
  importMediaFile: () => Promise<void>;
  cancelImportMedia: () => Promise<void>;
  exportRecordingWav: () => Promise<void>;
}

export const useHearStore = create<HearStoreState>((set, get) => ({
  appVersion: "0.1.11",
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
      let tts = snap.ttsSettings;
      if (
        typeof window !== "undefined" &&
        window.localStorage.getItem("hear_voice_clone_v11") !== "1"
      ) {
        window.localStorage.setItem("hear_voice_clone_v11", "1");
        tts = { ...tts, useVoiceClone: true };
        void tauriInvoke("set_tts_settings", { settings: tts });
      }
      set({ ...snap, ttsSettings: tts });
    }
    const sources = await tauriInvoke<AudioSourceOption[]>("list_audio_sources");
    if (sources && sources.length > 0) {
      set({ audioSources: sources });
    }
    if (isTauriRuntime()) {
      const { listen } = await import("@tauri-apps/api/event");
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
    set({ sessionError: null, sessionNotice: null });
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

    // 若开启了 Qwen3-TTS 原声克隆且在桌面端，录制过程中或已录音会话均优先调用服务端 /v1/clone/reference + /v1/clone
    if (isTauriRuntime() && get().ttsSettings.useVoiceClone) {
      set({ preparingCloneSegmentId: id });
      try {
        const raw = await tauriInvoke<ArrayBuffer | Uint8Array>("clone_segment_speech", {
          id,
          text: trimmed,
          lang,
        });
        if (get().speakingSegmentId === id) {
          set({ preparingCloneSegmentId: null });
        }
        if (raw && get().speakingSegmentId === id) {
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
              if (get().speakingSegmentId === id) set({ speakingSegmentId: null });
            };
            audio.onerror = () => {
              stopActiveCloneAudio();
              if (get().speakingSegmentId === id) set({ speakingSegmentId: null });
            };
            await audio.play();
            return;
          }
        }
      } catch {
        // 原声克隆不可用时，平滑回退到系统语音合成
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
    if (typeof window !== "undefined" && "speechSynthesis" in window) {
      window.speechSynthesis.cancel();
    }
    set({ speakingSegmentId: null, preparingCloneSegmentId: null });
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
