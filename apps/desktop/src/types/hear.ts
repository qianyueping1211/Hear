export type SessionMode = "idle" | "recording" | "paused" | "playing" | "batch_processing";

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

export type TtsRoutingMode = "face_to_face" | "meeting";

export interface OutputAudioDevice {
  id: string;
  name: string;
  isDefault: boolean;
  isVirtual: boolean;
}

export interface TtsOutputSettings {
  enabled: boolean;
  useVoiceClone: boolean;
  routingMode: TtsRoutingMode;
  outputDeviceId: string;
  inputDeviceId: string;
  meetingMicOutputDeviceId: string;
  meetingLoopbackDeviceId: string;
  muteMicWhileSpeaking: boolean;
  autoSpeakMyMic: boolean;
  autoSpeakOther: boolean;
  duckOriginalAudio: boolean;
  duckRatio: number;
  systemVoicePreference?: "auto" | "female" | "male";
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

export interface LlmApiConfig {
  enabled: boolean;
  provider: "openai" | "anthropic" | string;
  baseUrl: string;
  apiKey: string;
  model: string;
}

export interface UpdateConfig {
  repo: string;
  githubToken: string;
  autoCheckOnStartup: boolean;
}

export interface UpdateCheckResult {
  currentVersion: string;
  latestVersion?: string;
  hasUpdate: boolean;
  tagName?: string;
  releaseTitle?: string;
  releaseNotes: string;
  publishedAt?: string;
  releaseUrl?: string;
  repoUrl: string;
  assetName?: string;
  assetApiUrl?: string;
  assetBrowserUrl?: string;
  assetSize?: number;
  error?: string;
}

export interface LocalServerInstallStatus {
  installed: boolean;
  installDir: string;
  installedVersion?: string;
  hasBundledRuntime: boolean;
  hasModels: boolean;
  launcherPath?: string;
}

export interface LocalServerProgress {
  action: "install" | "reinstall" | "uninstall";
  stage: "checking" | "downloading" | "extracting" | "cleaning" | "done";
  downloaded: number;
  total: number;
  message: string;
}

export interface ConversationMeta {
  id: string;
  title: string;
  createdAtMs: number;
  updatedAtMs: number;
  durationMs?: number;
  segmentCount: number;
  preview: string;
  langPair: string;
  hasAudio: boolean;
  hasSummary: boolean;
}

export interface SavedConversation {
  meta: ConversationMeta;
  segments: SubtitleSegment[];
  summaryMarkdown: string;
  playback: RecordingPlaybackState;
}

export interface AppSnapshot {
  appVersion: string;
  activeConversationId?: string;
  conversations?: ConversationMeta[];
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
  localServerInstall: LocalServerInstallStatus;
  ttsSettings: TtsOutputSettings;
  playback: RecordingPlaybackState;
  glossary: string;
  llmConfig?: LlmApiConfig;
  updateConfig: UpdateConfig;
  updateInfo?: UpdateCheckResult;
}
