import { create } from "zustand";
import type {
  AppSnapshot,
  AudioCaptureMode,
  AudioSourceOption,
  EngineSource,
  LocalServerInstallStatus,
  LocalServerProgress,
  RecordingPlaybackState,
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
  useVoiceClone: false,
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
  searchQuery: string;
  summaryOpen: boolean;
  summaryTemplateId: string;
  summaryMarkdown: string;
  summaryGenerating: boolean;
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

  hydrate: () => Promise<void>;
  setSearchQuery: (q: string) => void;
  setSummaryOpen: (open: boolean) => void;
  setSummaryTemplateId: (id: string) => void;
  setSettingsOpen: (open: boolean, tab?: HearStoreState["activeSettingsTab"]) => void;

  setLanguagePair: (src: string, dst: string, lockSrc: boolean) => Promise<void>;
  setCaptureMode: (mode: AudioCaptureMode, appPid?: number) => Promise<void>;
  toggleRecording: () => Promise<void>;
  clearRecording: () => Promise<void>;

  seekPlayback: (ms: number, autoPlay?: boolean) => Promise<void>;
  togglePlayback: () => Promise<void>;
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
  saveUpdateConfig: (patch: Partial<UpdateConfig>) => Promise<UpdateConfig>;
  checkForUpdates: (override?: UpdateConfig) => Promise<UpdateCheckResult | null>;
  downloadAndInstallUpdate: () => Promise<void>;
  openGithubUrl: (url: string) => Promise<void>;
  updateTtsSettings: (patch: Partial<TtsOutputSettings>) => void;
  setGlossary: (text: string) => void;

  editSegmentSource: (id: string, newSource: string) => Promise<void>;
  generateSummary: () => Promise<void>;
  importMediaFile: () => Promise<void>;
}

export const useHearStore = create<HearStoreState>((set, get) => ({
  appVersion: "0.1.5",
  mode: "idle" as SessionMode,
  sourceLang: "en",
  targetLang: "zh",
  lockSourceLang: false,
  captureMode: "system_loopback",
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
    { id: "sys", label: "系统声音内录（自动排除听见自身）", kind: "system_loopback" },
    { id: "mic", label: "默认麦克风", kind: "microphone" },
    { id: "dual", label: "双路混合（系统声=对方 / 麦克风=我）", kind: "dual_mix" },
  ],
  audioLevel: 0,
  searchQuery: "",
  summaryOpen: true,
  summaryTemplateId: "meeting",
  summaryMarkdown: "",
  summaryGenerating: false,
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

  hydrate: async () => {
    const snap = await tauriInvoke<AppSnapshot>("get_snapshot");
    if (snap) {
      set({ ...snap });
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
    }
  },

  setSearchQuery: (searchQuery) => set({ searchQuery }),
  setSummaryOpen: (summaryOpen) => set({ summaryOpen }),
  setSummaryTemplateId: (summaryTemplateId) => set({ summaryTemplateId }),
  setSettingsOpen: (settingsOpen, tab) =>
    set((s) => ({ settingsOpen, activeSettingsTab: tab ?? s.activeSettingsTab })),

  setLanguagePair: async (sourceLang, targetLang, lockSourceLang) => {
    set({ sourceLang, targetLang, lockSourceLang });
    await tauriInvoke("set_language_pair", { sourceLang, targetLang, lockSourceLang });
  },

  setCaptureMode: async (captureMode, selectedAppPid) => {
    set({ captureMode, selectedAppPid });
    await tauriInvoke("set_capture_mode", { captureMode, selectedAppPid });
  },

  toggleRecording: async () => {
    const nextMode: SessionMode = get().mode === "recording" ? "idle" : "recording";
    set({ mode: nextMode });
    await tauriInvoke("toggle_recording");
  },

  clearRecording: async () => {
    set({
      segments: [],
      livePartialSource: "",
      livePartialTranslation: "",
      summaryMarkdown: "",
      playback: DEFAULT_PLAYBACK,
    });
    await tauriInvoke("clear_recording");
  },

  seekPlayback: async (ms, autoPlay = true) => {
    set((s) => ({
      playback: {
        ...s.playback,
        positionMs: Math.max(0, Math.min(ms, s.playback.durationMs || ms)),
        isPlaying: autoPlay ? true : s.playback.isPlaying,
      },
    }));
    await tauriInvoke("seek_playback", { positionMs: Math.floor(ms), autoPlay });
  },

  togglePlayback: async () => {
    const playing = !get().playback.isPlaying;
    set((s) => ({ playback: { ...s.playback, isPlaying: playing } }));
    await tauriInvoke("set_playback_playing", { playing });
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

  saveUpdateConfig: async (patch) => {
    const merged: UpdateConfig = { ...get().updateConfig, ...patch };
    set({ updateConfig: merged });
    const saved = await tauriInvoke<UpdateConfig>("save_update_config", {
      config: merged,
    });
    return saved ?? merged;
  },

  checkForUpdates: async (override) => {
    set({ checkingUpdate: true, updateDownloadError: null });
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
          ? { ...seg, sourceText: newSource, status: "correcting", isEdited: true }
          : seg
      ),
    }));
    await tauriInvoke("retranslate_segment", { id, newSource });
  },

  generateSummary: async () => {
    if (get().segments.length === 0 || get().summaryGenerating) return;
    set({ summaryGenerating: true, summaryOpen: true });
    try {
      const md = await tauriInvoke<string>("generate_summary", {
        templateId: get().summaryTemplateId,
      });
      if (typeof md === "string") {
        set({ summaryMarkdown: md });
      }
    } finally {
      set({ summaryGenerating: false });
    }
  },

  importMediaFile: async () => {
    await tauriInvoke("import_media_file");
  },
}));
