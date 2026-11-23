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
  backgroundColor: string;
  backgroundOpacity: number;
  textStroke: boolean;
  autoFadeSeconds: number;
  traditionalChinese: boolean;
  syncWithPlayback: boolean;
}

export interface ServiceConfig {
  localServiceAddress: string;
  localAccessToken: string;
  cloudServiceAddress: string;
  cloudAccessToken: string;
  asrSource: EngineSource;
  mtSource: EngineSource;
  cloneSource: EngineSource;
}

export interface ServiceProbeResult {
  ok: boolean;
  address: string;
  latencyMs: number;
  summary: string;
  asrReady: boolean;
  asrDetail: string;
  mtReady: boolean;
  mtDetail: string;
  cloneReady: boolean;
  cloneDetail: string;
  authMode: string;
  authOk?: boolean;
  authDetail?: string;
  streamingMt: boolean;
  error?: string;
}

export interface TtsOutputSettings {
  enabled: boolean;
  useVoiceClone: boolean;
  outputDeviceId: string;
  duckOriginalAudio: boolean;
  duckRatio: number;
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
  peaks: number[];
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
  serviceConfig: ServiceConfig;
  localStatus: ServiceProbeResult;
  cloudStatus: ServiceProbeResult;
  ttsSettings: TtsOutputSettings;
  playback: RecordingPlaybackState;
  glossary: string;
}
