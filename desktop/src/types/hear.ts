export type SessionMode = "idle" | "recording" | "playing" | "batch_processing";

export type AudioChannel = "system" | "mic" | "file";

export type AudioCaptureMode =
  | "system_loopback"
  | "app_loopback"
  | "microphone"
  | "dual_mix";

export type SubtitleLayoutMode = "bilingual" | "translation_focus" | "translation_only";

export type EngineSource = "local" | "cloud";

export interface SubtitleSegment {
  id: string;
  seq: number;
  startMs: number;
  endMs: number;
  channel: AudioChannel;
  speakerLabel?: string;
  sourceLang: string;
  targetLang: string;
  sourceText: string;
  translatedText: string;
  baselineTranslated?: string;
  status: "preview" | "final" | "correcting" | "error";
  isEdited?: boolean;
}

export interface AudioSourceOption {
  id: string;
  label: string;
  kind: AudioCaptureMode;
  processId?: number;
  processName?: string;
}

export interface SubtitleStyle {
  visible: boolean;
  clickThrough: boolean;
  excludeFromCapture: boolean;
  layout: SubtitleLayoutMode;
  fontSize: number;
  maxLines: number;
  backgroundOpacity: number;
  textStroke: boolean;
  autoFadeSeconds: number;
  traditionalChinese: boolean;
  syncWithPlayback: boolean;
}

export interface ServerSwitches {
  /** 开关 1：启用本机模型服务（默认仅绑定 127.0.0.1，防外网与局域网未授权访问） */
  localServerEnabled: boolean;
  /** 开关 2：允许局域网共享给 iPhone / 其他电脑（切换 0.0.0.0 + 强制 HTTPS 与访问口令） */
  lanShareEnabled: boolean;
  /** 三个模型各自选择本机或远端云端 */
  asrSource: EngineSource;
  mtSource: EngineSource;
  cloneSource: EngineSource;
  /** 远端云端模式地址（支持 #hear-root=... 严格模式配对地址） */
  remoteCloudAddress: string;
  remoteAccessToken: string;
  remoteStrictFingerprint: string;
}

export interface ServiceStatus {
  running: boolean;
  bindHost: string;
  port: number;
  lanShared: boolean;
  lanAddresses: string[];
  pairingAddress: string;
  accessTokenMasked: string;
  asrReady: boolean;
  asrDetail: string;
  mtReady: boolean;
  mtDetail: string;
  cloneReady: boolean;
  cloneDetail: string;
  streamingMt: boolean;
  lastError?: string;
}

export interface TtsOutputSettings {
  enabled: boolean;
  useVoiceClone: boolean;
  outputDeviceId: string;
  duckOriginalAudio: boolean;
  duckRatio: number; // 0.1 - 1.0
}

export interface RecordingPlaybackState {
  hasAudio: boolean;
  audioPath?: string;
  durationMs: number;
  positionMs: number;
  isPlaying: boolean;
  speed: number;
  systemVolume: number;
  micVolume: number;
  peaks: number[]; // 0..1 归一化波形峰值（每 50ms 一个点）
}

export interface SummaryTemplateOption {
  id: string;
  title: string;
  description: string;
}

export interface AppSnapshot {
  mode: SessionMode;
  sourceLang: string;
  targetLang: string;
  lockSourceLang: boolean;
  captureMode: AudioCaptureMode;
  selectedAppPid?: number;
  selectedMicId?: string;
  segments: SubtitleSegment[];
  livePartialSource: string;
  livePartialTranslation: string;
  subtitleStyle: SubtitleStyle;
  switches: ServerSwitches;
  serviceStatus: ServiceStatus;
  ttsSettings: TtsOutputSettings;
  playback: RecordingPlaybackState;
  glossary: string;
}
