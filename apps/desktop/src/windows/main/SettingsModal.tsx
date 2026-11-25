import { useEffect, useState } from "react";
import {
  AlertCircle,
  ArrowUpCircle,
  CheckCircle2,
  Cloud,
  Download,
  ExternalLink,
  Eye,
  EyeOff,
  FolderOpen,
  Laptop,
  Loader2,
  Mic,
  Palette,
  Play,
  RefreshCw,
  RotateCcw,
  Save,
  Server,
  Shield,
  Sliders,
  Trash2,
  Volume2,
  X,
} from "lucide-react";
import { invoke } from "@tauri-apps/api/core";
import { useHearStore } from "../../stores/useHearStore";
import { VoiceSampleRecorderModal } from "./VoiceSampleRecorderModal";
import type {
  EngineSource,
  ServiceProbeResult,
  SubtitleLayoutMode,
} from "../../types/hear";

const BG_COLOR_PRESETS = [
  { name: "深邃黑", hex: "#0b0f17" },
  { name: "纯黑", hex: "#000000" },
  { name: "海军蓝", hex: "#0f172a" },
  { name: "墨绿", hex: "#06281e" },
  { name: "炭灰", hex: "#1f2937" },
  { name: "柔白", hex: "#f8fafc" },
];

function maskSecret(token: string): string {
  const t = token.trim();
  if (!t) return "";
  if (t.length <= 8) return "•".repeat(Math.max(4, t.length));
  return `${t.slice(0, 4)}••••••${t.slice(-4)}`;
}

function StatusPanel({ status }: { status: ServiceProbeResult }) {
  const hasTested = Boolean(status.address || status.error || status.latencyMs > 0);
  return (
    <div className="rounded-lg bg-surface-950/80 border border-white/10 p-3 space-y-2.5 text-xs">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-1.5 font-medium">
          {!hasTested ? (
            <>
              <span className="w-2 h-2 rounded-full bg-slate-500" />
              <span className="text-slate-400">{status.summary}</span>
            </>
          ) : status.ok ? (
            <>
              <CheckCircle2 className="w-4 h-4 text-emerald-400 shrink-0" />
              <span className="text-emerald-300">{status.summary}</span>
            </>
          ) : (
            <>
              <AlertCircle className="w-4 h-4 text-rose-400 shrink-0" />
              <span className="text-rose-300">{status.summary}</span>
            </>
          )}
        </div>
        {hasTested && status.authMode && status.authMode !== "unknown" && (
          <span className="px-2 py-0.5 rounded bg-white/5 text-[11px] text-slate-400">
            鉴权：{status.authMode}
          </span>
        )}
      </div>

      {status.authDetail && (
        <div
          className={`text-[11px] ${
            status.authOk === false ? "text-amber-300" : "text-emerald-300/90"
          }`}
        >
          口令状态：{status.authDetail}
        </div>
      )}

      {status.error && (
        <div className="text-[11px] text-rose-300/90 break-all">{status.error}</div>
      )}

      <div className="grid grid-cols-3 gap-2 pt-0.5">
        <div className="rounded-md bg-surface-900/90 p-2 border border-white/5">
          <div className="text-[11px] text-slate-400">语音识别 (ASR)</div>
          <div
            className={`mt-1 font-medium truncate ${
              status.asrReady
                ? "text-emerald-400"
                : hasTested
                ? "text-amber-300"
                : "text-slate-500"
            }`}
            title={status.asrDetail}
          >
            {status.asrDetail}
          </div>
        </div>
        <div className="rounded-md bg-surface-900/90 p-2 border border-white/5">
          <div className="text-[11px] text-slate-400">文本翻译 (MT)</div>
          <div
            className={`mt-1 font-medium truncate ${
              status.mtReady
                ? "text-emerald-400"
                : hasTested
                ? "text-amber-300"
                : "text-slate-500"
            }`}
            title={status.mtDetail}
          >
            {status.mtDetail}
          </div>
        </div>
        <div className="rounded-md bg-surface-900/90 p-2 border border-white/5">
          <div className="text-[11px] text-slate-400">声音克隆 (TTS)</div>
          <div
            className={`mt-1 font-medium truncate ${
              status.cloneReady
                ? "text-emerald-400"
                : hasTested
                ? "text-slate-300"
                : "text-slate-500"
            }`}
            title={status.cloneDetail}
          >
            {status.cloneDetail}
          </div>
        </div>
      </div>
    </div>
  );
}

export function SettingsModal() {
  const {
    appVersion,
    hydrated,
    settingsOpen,
    activeSettingsTab,
    setSettingsOpen,
    serviceConfig,
    localStatus,
    cloudStatus,
    localServerInstall,
    testingLocal,
    testingCloud,
    localServerBusy,
    localServerProgress,
    localServerMessage,
    localServerError,
    subtitleStyle,
    ttsSettings,
    outputDevices,
    inputDevices,
    hasMyVoiceSample,
    refreshOutputDevices,
    saveRecordedMyVoiceSample,
    readMyVoiceSampleWav,
    clearMyVoiceSample,
    glossary,
    llmConfig,
    saveLlmConfig,
    fetchLlmModels,
    updateConfig,
    updateInfo,
    checkingUpdate,
    downloadingUpdate,
    updateDownloadProgress,
    updateDownloadError,
    saveServiceConfig,
    testServiceConnection,
    refreshLocalServerInstallStatus,
    installLocalServer,
    reinstallLocalServer,
    uninstallLocalServer,
    openLocalServerDir,
    openLogsDir,
    saveUpdateConfig,
    checkForUpdates,
    downloadAndInstallUpdate,
    openGithubUrl,
    updateSubtitleStyle,
    updateTtsSettings,
    setGlossary,
  } = useHearStore();

  // 使用本地草稿状态，输入过程绝不触发后端请求或任何进程动作
  const [localAddress, setLocalAddress] = useState(serviceConfig.localServiceAddress);
  const [localToken, setLocalToken] = useState(serviceConfig.localAccessToken);
  const [cloudAddress, setCloudAddress] = useState(serviceConfig.cloudServiceAddress);
  const [cloudToken, setCloudToken] = useState(serviceConfig.cloudAccessToken);
  const [ghRepo, setGhRepo] = useState(updateConfig.repo);
  const [ghToken, setGhToken] = useState(updateConfig.githubToken);
  const [showGhToken, setShowGhToken] = useState(false);
  const [autoCheck, setAutoCheck] = useState(updateConfig.autoCheckOnStartup);
  const [llmEnabled, setLlmEnabled] = useState(llmConfig.enabled);
  const [llmProvider, setLlmProvider] = useState(llmConfig.provider);
  const [llmBaseUrl, setLlmBaseUrl] = useState(llmConfig.baseUrl);
  const [llmApiKey, setLlmApiKey] = useState(llmConfig.apiKey);
  const [llmModel, setLlmModel] = useState(llmConfig.model);
  const [showLlmKey, setShowLlmKey] = useState(false);
  const [llmModels, setLlmModels] = useState<string[]>([]);
  const [fetchingLlmModels, setFetchingLlmModels] = useState(false);
  const [llmFetchError, setLlmFetchError] = useState<string | null>(null);
  const [savedHint, setSavedHint] = useState<"local" | "cloud" | "llm" | "system" | null>(null);
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [removeModelsOnUninstall, setRemoveModelsOnUninstall] = useState(false);
  const [voiceRecorderOpen, setVoiceRecorderOpen] = useState(false);
  const [previewingVoiceSample, setPreviewingVoiceSample] = useState(false);

  // 仅在弹窗打开瞬间（或刚完成首屏 hydrate 时）同步草稿，避免刚启动点开设置读到空默认值
  useEffect(() => {
    if (!settingsOpen || !hydrated) return;
    const snap = useHearStore.getState();
    setLocalAddress(snap.serviceConfig.localServiceAddress);
    setLocalToken(snap.serviceConfig.localAccessToken);
    setCloudAddress(snap.serviceConfig.cloudServiceAddress);
    setCloudToken(snap.serviceConfig.cloudAccessToken);
    setGhRepo(snap.updateConfig.repo);
    setGhToken(snap.updateConfig.githubToken);
    setShowGhToken(false);
    setAutoCheck(snap.updateConfig.autoCheckOnStartup);
    setLlmEnabled(snap.llmConfig.enabled);
    setLlmProvider(snap.llmConfig.provider || "openai");
    setLlmBaseUrl(snap.llmConfig.baseUrl);
    setLlmApiKey(snap.llmConfig.apiKey);
    setLlmModel(snap.llmConfig.model);
    setShowLlmKey(false);
    setSavedHint(null);
    setConfirmUninstall(false);
    void refreshLocalServerInstallStatus();
  }, [settingsOpen, hydrated, refreshLocalServerInstallStatus]);

  // 每次打开设置窗口或切到「模型服务」页时，自动重新测试一次已配置的本机/远端连接状态
  useEffect(() => {
    if (!settingsOpen || !hydrated || activeSettingsTab !== "server") return;
    const snap = useHearStore.getState();
    if (snap.serviceConfig.localServiceAddress.trim()) {
      void testServiceConnection("local");
    }
    if (snap.serviceConfig.cloudServiceAddress.trim()) {
      void testServiceConnection("cloud");
    }
  }, [settingsOpen, hydrated, activeSettingsTab, testServiceConnection]);

  if (!settingsOpen) return null;

  const tabs: { id: typeof activeSettingsTab; label: string; icon: React.ReactNode }[] = [
    { id: "server", label: "模型服务", icon: <Server className="w-4 h-4" /> },
    { id: "subtitle", label: "悬浮字幕", icon: <Sliders className="w-4 h-4" /> },
    { id: "audio", label: "朗读与音频", icon: <Volume2 className="w-4 h-4" /> },
    { id: "general", label: "快捷键与术语", icon: <Shield className="w-4 h-4" /> },
    { id: "system", label: "系统与更新", icon: <ArrowUpCircle className="w-4 h-4" /> },
  ];

  const handleSaveSystem = async () => {
    await saveUpdateConfig({
      repo: ghRepo.trim() || "qianyueping1211/Hear",
      githubToken: ghToken.trim(),
      autoCheckOnStartup: autoCheck,
    });
    setSavedHint("system");
    setTimeout(() => setSavedHint((h) => (h === "system" ? null : h)), 2000);
  };

  const handleCheckUpdate = async () => {
    const storedTok = useHearStore.getState().updateConfig.githubToken.trim();
    const cfg = {
      repo: ghRepo.trim() || "qianyueping1211/Hear",
      githubToken: ghToken.trim() || storedTok,
      autoCheckOnStartup: autoCheck,
    };
    await checkForUpdates(cfg);
  };

  const handleSaveLocal = async () => {
    const addr = localAddress.trim();
    const tok = localToken.trim();
    await saveServiceConfig({
      localServiceAddress: addr,
      localAccessToken: tok,
    });
    setSavedHint("local");
    setTimeout(() => setSavedHint((h) => (h === "local" ? null : h)), 2000);
    if (addr) {
      await testServiceConnection("local", addr, tok);
    }
  };

  const handleTestLocal = async () => {
    const addr = localAddress.trim();
    const tok = localToken.trim();
    await saveServiceConfig({ localServiceAddress: addr, localAccessToken: tok });
    await testServiceConnection("local", addr, tok);
  };

  const handleSaveLlm = async () => {
    await saveLlmConfig({
      enabled: llmEnabled,
      provider: llmProvider,
      baseUrl: llmBaseUrl.trim(),
      apiKey: llmApiKey.trim(),
      model: llmModel.trim(),
    });
    setSavedHint("llm");
    setTimeout(() => setSavedHint((h) => (h === "llm" ? null : h)), 2000);
  };

  const handleFetchLlmModels = async () => {
    setFetchingLlmModels(true);
    setLlmFetchError(null);
    try {
      const list = await fetchLlmModels(llmProvider, llmBaseUrl.trim(), llmApiKey.trim());
      setLlmModels(list);
      if (list.length > 0 && !list.includes(llmModel.trim())) {
        setLlmModel(list[0]);
      } else if (list.length === 0) {
        setLlmFetchError("接口返回为空，可手动输入模型名称");
      }
    } catch (err) {
      setLlmFetchError(err instanceof Error ? err.message : String(err));
    } finally {
      setFetchingLlmModels(false);
    }
  };

  const handleSaveCloud = async () => {
    const addr = cloudAddress.trim();
    const tok = cloudToken.trim();
    await saveServiceConfig({
      cloudServiceAddress: addr,
      cloudAccessToken: tok,
    });
    setSavedHint("cloud");
    setTimeout(() => setSavedHint((h) => (h === "cloud" ? null : h)), 2000);
    if (addr) {
      await testServiceConnection("cloud", addr, tok);
    }
  };

  const handleTestCloud = async () => {
    const addr = cloudAddress.trim();
    const tok = cloudToken.trim();
    await saveServiceConfig({ cloudServiceAddress: addr, cloudAccessToken: tok });
    await testServiceConnection("cloud", addr, tok);
  };

  const renderSourceSelect = (
    label: string,
    value: EngineSource,
    onChange: (v: EngineSource) => void
  ) => (
    <div className="flex items-center justify-between py-2 border-b border-white/5 last:border-b-0">
      <span className="text-sm text-slate-200">{label}</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value as EngineSource)}
        className="rounded-lg bg-surface-950 border border-white/10 px-3 py-1.5 text-xs text-slate-100"
      >
        <option value="local">本机模型服务</option>
        <option value="cloud">远端云端服务</option>
      </select>
    </div>
  );

  return (
    <div className="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm flex items-center justify-center p-6">
      <div className="w-full max-w-3xl max-h-[85vh] rounded-2xl bg-surface-900 border border-white/10 shadow-2xl flex flex-col overflow-hidden">
        {/* 顶栏 */}
        <div className="px-5 py-3.5 border-b border-white/10 flex items-center justify-between">
          <div className="flex items-center gap-2">
            {tabs.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setSettingsOpen(true, tab.id)}
                className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition ${
                  activeSettingsTab === tab.id
                    ? "bg-brand-500 text-white"
                    : "text-slate-300 hover:bg-white/5"
                }`}
              >
                {tab.icon}
                {tab.label}
              </button>
            ))}
          </div>
          <button
            onClick={() => setSettingsOpen(false)}
            className="p-1.5 rounded-lg text-slate-400 hover:bg-white/10 hover:text-white"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* 内容区 */}
        <div className="p-5 overflow-y-auto space-y-5 text-sm">
          {activeSettingsTab === "server" && (
            <>
              {/* 区块 1：本机模型服务（仅连接与检测，不发起进程管理） */}
              <div className="rounded-xl bg-surface-800/70 border border-white/10 p-4 space-y-3">
                <div className="flex items-center justify-between gap-2">
                  <div className="font-semibold text-white flex items-center gap-2">
                    <Laptop className="w-4 h-4 text-emerald-400" />
                    本机模型服务
                  </div>
                  <span className="text-[11px] text-slate-400">
                    服务端独立运行，客户端支持一键部署包管理与状态检测
                  </span>
                </div>

                {/* 本机模型服务端安装包管理：三态联动（托管已装 / 外部独立服务运行中 / 未安装） */}
                <div className="rounded-lg bg-surface-950/80 border border-white/10 p-3 space-y-2.5 text-xs">
                  <div className="flex items-center justify-between gap-2 flex-wrap">
                    <div className="flex items-center gap-2 min-w-0">
                      <span
                        className={`w-2 h-2 rounded-full shrink-0 ${
                          localServerInstall.installed
                            ? "bg-emerald-400"
                            : localStatus.ok
                            ? "bg-sky-400"
                            : "bg-slate-500"
                        }`}
                      />
                      <span className="font-medium text-slate-200">
                        {localServerInstall.installed
                          ? `已安装本机模型服务${
                              localServerInstall.installedVersion
                                ? ` v${localServerInstall.installedVersion}`
                                : ""
                            }`
                          : localStatus.ok
                          ? "已检测到外部独立部署的本机服务（运行中）"
                          : "未在默认目录安装模型服务端"}
                      </span>
                      {localServerInstall.installed && localServerInstall.hasBundledRuntime && (
                        <span className="px-1.5 py-0.5 rounded bg-emerald-500/15 text-emerald-300 text-[11px]">
                          内置 faster-whisper / sherpa-onnx
                        </span>
                      )}
                      {!localServerInstall.installed && localStatus.ok && (
                        <span className="px-1.5 py-0.5 rounded bg-sky-500/15 text-sky-300 text-[11px]">
                          外部服务已就绪
                        </span>
                      )}
                    </div>
                    {localServerInstall.installDir && (
                      <span
                        className="text-[11px] font-mono text-slate-500 truncate max-w-[260px]"
                        title={`客户端默认托管安装目录：${localServerInstall.installDir}`}
                      >
                        {localServerInstall.installDir}
                      </span>
                    )}
                  </div>

                  <div className="flex items-center gap-2 flex-wrap">
                    {!localServerInstall.installed ? (
                      <button
                        type="button"
                        disabled={localServerBusy !== null}
                        onClick={() => void installLocalServer()}
                        className={`px-3 py-1.5 rounded-lg font-medium flex items-center gap-1.5 disabled:opacity-50 ${
                          localStatus.ok
                            ? "bg-surface-900 border border-white/10 hover:bg-white/5 text-slate-300"
                            : "bg-emerald-600 hover:bg-emerald-500 text-white"
                        }`}
                      >
                        {localServerBusy === "install" ? (
                          <Loader2 className="w-3.5 h-3.5 animate-spin" />
                        ) : (
                          <Download className="w-3.5 h-3.5" />
                        )}
                        {localServerBusy === "install"
                          ? "正在安装…"
                          : localStatus.ok
                          ? "另行安装一份到客户端默认目录"
                          : "一键安装模型服务"}
                      </button>
                    ) : (
                      <>
                        <button
                          type="button"
                          disabled={localServerBusy !== null}
                          onClick={() => {
                            setConfirmUninstall(false);
                            void reinstallLocalServer();
                          }}
                          title="下载并覆盖最新服务端整合包（自动保留已下载的模型权重与证书）"
                          className="px-3 py-1.5 rounded-lg bg-brand-500/90 hover:bg-brand-500 text-white font-medium flex items-center gap-1.5 disabled:opacity-50"
                        >
                          {localServerBusy === "reinstall" ? (
                            <Loader2 className="w-3.5 h-3.5 animate-spin" />
                          ) : (
                            <RotateCcw className="w-3.5 h-3.5" />
                          )}
                          {localServerBusy === "reinstall" ? "正在重装…" : "一键重新安装"}
                        </button>
                        <button
                          type="button"
                          disabled={localServerBusy !== null}
                          onClick={() => setConfirmUninstall((v) => !v)}
                          className="px-3 py-1.5 rounded-lg bg-rose-500/15 border border-rose-400/30 hover:bg-rose-500/25 text-rose-300 flex items-center gap-1.5 disabled:opacity-50"
                        >
                          <Trash2 className="w-3.5 h-3.5" />
                          一键卸载
                        </button>
                      </>
                    )}

                    {localServerInstall.installed && (
                      <button
                        type="button"
                        onClick={() => void openLocalServerDir()}
                        title="打开安装目录，双击 start-hear-cloud.bat 启动本机服务"
                        className="px-2.5 py-1.5 rounded-lg bg-surface-900 border border-white/10 hover:bg-white/5 text-slate-300 flex items-center gap-1.5"
                      >
                        <FolderOpen className="w-3.5 h-3.5" />
                        打开服务端目录
                      </button>
                    )}
                  </div>

                  {/* 卸载二次确认栏 */}
                  {confirmUninstall && localServerInstall.installed && (
                    <div className="rounded-md bg-rose-950/40 border border-rose-400/30 p-2.5 space-y-2">
                      <div className="text-rose-200">
                        确认卸载本机模型服务？卸载前请确保已关闭正在运行的服务端窗口。
                      </div>
                      <label className="flex items-center gap-2 text-[11px] text-slate-300 cursor-pointer">
                        <input
                          type="checkbox"
                          checked={removeModelsOnUninstall}
                          onChange={(e) => setRemoveModelsOnUninstall(e.target.checked)}
                          className="w-3.5 h-3.5 accent-rose-500"
                        />
                        同时删除已下载的模型权重文件（server/models，不勾选则保留以便下次重装免重下）
                      </label>
                      <div className="flex items-center gap-2">
                        <button
                          type="button"
                          disabled={localServerBusy !== null}
                          onClick={async () => {
                            setConfirmUninstall(false);
                            await uninstallLocalServer(removeModelsOnUninstall);
                          }}
                          className="px-3 py-1 rounded bg-rose-600 hover:bg-rose-500 text-white font-medium disabled:opacity-50"
                        >
                          {localServerBusy === "uninstall" ? "正在卸载…" : "确认卸载"}
                        </button>
                        <button
                          type="button"
                          onClick={() => setConfirmUninstall(false)}
                          className="px-2.5 py-1 rounded bg-surface-800 text-slate-300 hover:text-white"
                        >
                          取消
                        </button>
                      </div>
                    </div>
                  )}

                  {/* 下载与解压进度条 */}
                  {localServerProgress && (
                    <div className="space-y-1">
                      <div className="flex justify-between text-[11px] text-sky-300 font-mono">
                        <span className="truncate pr-2">{localServerProgress.message}</span>
                        {localServerProgress.stage === "downloading" && (
                          <span className="shrink-0">
                            {(localServerProgress.downloaded / 1048576).toFixed(1)} MB
                            {localServerProgress.total > 0
                              ? ` / ${(localServerProgress.total / 1048576).toFixed(1)} MB (${Math.round(
                                  (localServerProgress.downloaded / localServerProgress.total) * 100
                                )}%)`
                              : ""}
                          </span>
                        )}
                      </div>
                      <div className="h-1.5 rounded-full bg-surface-800 overflow-hidden">
                        <div
                          className="h-full bg-emerald-500 transition-all"
                          style={{
                            width:
                              localServerProgress.stage === "downloading" &&
                              localServerProgress.total > 0
                                ? `${Math.min(
                                    100,
                                    Math.round(
                                      (localServerProgress.downloaded /
                                        localServerProgress.total) *
                                        100
                                    )
                                  )}%`
                                : localServerProgress.stage === "extracting"
                                ? "92%"
                                : "30%",
                          }}
                        />
                      </div>
                    </div>
                  )}

                  {localServerMessage && !localServerError && (
                    <div className="text-[11px] text-emerald-300">{localServerMessage}</div>
                  )}
                  {localServerError && (
                    <div className="text-[11px] text-rose-300 break-all">{localServerError}</div>
                  )}

                  <div className="text-[11px] text-slate-500 leading-relaxed">
                    {localServerInstall.installed
                      ? "安装完成后请点击「打开服务端目录」，双击 start-hear-cloud.bat 启动本机服务，再点击下方「测试连接」验证三模型状态。"
                      : localStatus.ok
                      ? "当前已连通你自行部署的本机模型服务，可直接使用，无需重复安装。"
                      : "一键安装会自动拉取最新内置 Python + faster-whisper + sherpa-onnx 的服务端整合包，无需手工装依赖；若已在其他目录手动运行服务，直接填写下方地址并测试连接即可。"}
                  </div>
                </div>

                <div className="space-y-2">
                  <input
                    type="text"
                    placeholder="https://127.0.0.1:8000 或 http://127.0.0.1:8000"
                    value={localAddress}
                    onChange={(e) => setLocalAddress(e.target.value)}
                    className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-xs font-mono text-slate-100 focus:outline-none focus:border-brand-500"
                  />
                  <input
                    type="password"
                    placeholder="访问口令 X-Hear-Token（若本机服务已开启口令校验）"
                    value={localToken}
                    onChange={(e) => setLocalToken(e.target.value)}
                    className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-xs font-mono text-slate-100 focus:outline-none focus:border-brand-500"
                  />
                </div>

                <div className="flex items-center gap-2">
                  <button
                    onClick={() => void handleSaveLocal()}
                    className="px-3 py-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-xs text-slate-200 flex items-center gap-1.5"
                  >
                    <Save className="w-3.5 h-3.5" />
                    {savedHint === "local" ? "已保存" : "保存配置"}
                  </button>
                  <button
                    disabled={testingLocal}
                    onClick={() => void handleTestLocal()}
                    className="px-3 py-1.5 rounded-lg bg-brand-500 hover:bg-brand-600 text-xs text-white flex items-center gap-1.5 disabled:opacity-50"
                  >
                    {testingLocal ? (
                      <Loader2 className="w-3.5 h-3.5 animate-spin" />
                    ) : (
                      <RefreshCw className="w-3.5 h-3.5" />
                    )}
                    {testingLocal ? "正在测试连接…" : "测试连接"}
                  </button>
                </div>

                <StatusPanel status={localStatus} />
              </div>

              {/* 区块 2：远端云端服务 */}
              <div className="rounded-xl bg-surface-800/70 border border-white/10 p-4 space-y-3">
                <div className="font-semibold text-white flex items-center gap-2">
                  <Cloud className="w-4 h-4 text-sky-400" />
                  远端云端服务地址
                </div>

                <div className="space-y-2">
                  <input
                    type="text"
                    placeholder="https://服务器地址:8000 或带指纹地址 https://...#hear-root=..."
                    value={cloudAddress}
                    onChange={(e) => setCloudAddress(e.target.value)}
                    className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-xs font-mono text-slate-100 focus:outline-none focus:border-brand-500"
                  />
                  <input
                    type="password"
                    placeholder="访问口令 X-Hear-Token（若远端服务开启鉴权）"
                    value={cloudToken}
                    onChange={(e) => setCloudToken(e.target.value)}
                    className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-xs font-mono text-slate-100 focus:outline-none focus:border-brand-500"
                  />
                </div>

                <div className="flex items-center gap-2">
                  <button
                    onClick={() => void handleSaveCloud()}
                    className="px-3 py-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-xs text-slate-200 flex items-center gap-1.5"
                  >
                    <Save className="w-3.5 h-3.5" />
                    {savedHint === "cloud" ? "已保存" : "保存配置"}
                  </button>
                  <button
                    disabled={testingCloud}
                    onClick={() => void handleTestCloud()}
                    className="px-3 py-1.5 rounded-lg bg-brand-500 hover:bg-brand-600 text-xs text-white flex items-center gap-1.5 disabled:opacity-50"
                  >
                    {testingCloud ? (
                      <Loader2 className="w-3.5 h-3.5 animate-spin" />
                    ) : (
                      <RefreshCw className="w-3.5 h-3.5" />
                    )}
                    {testingCloud ? "正在测试连接…" : "测试连接"}
                  </button>
                </div>

                <StatusPanel status={cloudStatus} />
              </div>

              {/* 区块 3：模型路由 */}
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4">
                <div className="font-semibold text-white mb-2">
                  模型路由（各能力独立选择本机或云端服务）
                </div>
                {renderSourceSelect(
                  "语音识别 (SenseVoice + Whisper)",
                  serviceConfig.asrSource,
                  (v) => void saveServiceConfig({ asrSource: v })
                )}
                {renderSourceSelect("文本翻译 (Hy-MT2)", serviceConfig.mtSource, (v) =>
                  void saveServiceConfig({ mtSource: v })
                )}
                {renderSourceSelect("声音克隆 (Qwen3-TTS)", serviceConfig.cloneSource, (v) =>
                  void saveServiceConfig({ cloneSource: v })
                )}
              </div>

              {/* 区块 4：外部大模型总结 API（对齐 iOS，仅用于会议纪要，不参与实时翻译） */}
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-3">
                <div className="flex items-center justify-between gap-2">
                  <div>
                    <div className="font-semibold text-white">外部大模型 API（仅用于会议纪要总结）</div>
                    <div className="text-xs text-slate-400 mt-0.5">
                      支持 DeepSeek / 通义千问 / OpenAI / Anthropic 等，关闭或未填时自动回退 Hy-MT2。
                    </div>
                  </div>
                  <label className="inline-flex items-center gap-2 text-xs text-slate-200 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={llmEnabled}
                      onChange={(e) => setLlmEnabled(e.target.checked)}
                      className="w-4 h-4 accent-brand-500"
                    />
                    <span>启用外部大模型</span>
                  </label>
                </div>

                <div className="flex flex-wrap gap-1.5 text-[11px]">
                  {[
                    { label: "MiniMax", provider: "openai", baseUrl: "https://api.minimaxi.com/v1", model: "MiniMax-M1" },
                    { label: "DeepSeek", provider: "openai", baseUrl: "https://api.deepseek.com/v1", model: "deepseek-chat" },
                    { label: "通义千问", provider: "openai", baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus" },
                    { label: "Kimi", provider: "openai", baseUrl: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k" },
                    { label: "OpenAI", provider: "openai", baseUrl: "https://api.openai.com/v1", model: "gpt-4o-mini" },
                    { label: "Anthropic", provider: "anthropic", baseUrl: "https://api.anthropic.com", model: "claude-3-5-sonnet-latest" },
                    { label: "OpenRouter", provider: "openai", baseUrl: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini" },
                    { label: "自定义", provider: llmProvider, baseUrl: "", model: "" },
                  ].map((preset) => {
                    const isCustom = preset.label === "自定义";
                    const isActive = isCustom
                      ? ![
                          "https://api.minimaxi.com/v1",
                          "https://api.deepseek.com/v1",
                          "https://dashscope.aliyuncs.com/compatible-mode/v1",
                          "https://api.moonshot.cn/v1",
                          "https://api.openai.com/v1",
                          "https://api.anthropic.com",
                          "https://openrouter.ai/api/v1",
                        ].includes(llmBaseUrl.trim())
                      : llmBaseUrl.trim() === preset.baseUrl;
                    return (
                      <button
                        key={preset.label}
                        type="button"
                        onClick={() => {
                          setLlmEnabled(true);
                          setLlmFetchError(null);
                          setLlmModels([]);
                          if (!isCustom) {
                            setLlmProvider(preset.provider);
                            setLlmBaseUrl(preset.baseUrl);
                            setLlmModel(preset.model);
                          } else {
                            setLlmBaseUrl("");
                            setLlmModel("");
                          }
                        }}
                        className={`px-2.5 py-1 rounded-md border transition ${
                          isActive
                            ? "bg-brand-500/20 border-brand-400/50 text-brand-300"
                            : "bg-white/5 hover:bg-white/10 border-white/10 text-slate-300 hover:text-white"
                        }`}
                      >
                        {preset.label}
                      </button>
                    );
                  })}
                </div>

                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs">
                  <label className="space-y-1">
                    <span className="text-slate-400">接口协议</span>
                    <select
                      value={llmProvider}
                      onChange={(e) => setLlmProvider(e.target.value)}
                      className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-slate-100"
                    >
                      <option value="openai">OpenAI 兼容（MiniMax / DeepSeek / 通义 / Kimi / GPT）</option>
                      <option value="anthropic">Anthropic (/v1/messages)</option>
                    </select>
                  </label>
                  <label className="space-y-1">
                    <span className="text-slate-400">API Base URL</span>
                    <input
                      type="text"
                      value={llmBaseUrl}
                      onChange={(e) => setLlmBaseUrl(e.target.value)}
                      placeholder="https://api.minimaxi.com/v1"
                      className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-slate-100"
                    />
                  </label>
                  <label className="space-y-1 sm:col-span-2">
                    <span className="text-slate-400">API Key / Token（仅存本机配置文件）</span>
                    <div className="flex gap-2">
                      <input
                        type={showLlmKey ? "text" : "password"}
                        value={llmApiKey}
                        onChange={(e) => setLlmApiKey(e.target.value)}
                        placeholder="填好 Token 后点击右侧「拉取模型」"
                        className="flex-1 rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-slate-100"
                      />
                      <button
                        type="button"
                        onClick={() => setShowLlmKey((v) => !v)}
                        className="px-2.5 rounded-lg bg-white/5 hover:bg-white/10 border border-white/10 text-slate-300"
                      >
                        {showLlmKey ? "隐藏" : "显示"}
                      </button>
                      <button
                        type="button"
                        disabled={fetchingLlmModels || !llmBaseUrl.trim()}
                        onClick={() => void handleFetchLlmModels()}
                        className="px-3 rounded-lg bg-white/10 hover:bg-white/15 border border-white/10 text-slate-100 inline-flex items-center gap-1.5 disabled:opacity-50"
                      >
                        {fetchingLlmModels ? (
                          <Loader2 className="w-3.5 h-3.5 animate-spin" />
                        ) : (
                          <RefreshCw className="w-3.5 h-3.5" />
                        )}
                        <span>{fetchingLlmModels ? "拉取中…" : "拉取模型"}</span>
                      </button>
                    </div>
                  </label>
                  <div className="space-y-1 sm:col-span-2">
                    <span className="text-slate-400">
                      选择或填写模型名称{llmModels.length > 0 ? `（已拉取 ${llmModels.length} 个模型）` : ""}
                    </span>
                    <div className="flex gap-2">
                      {llmModels.length > 0 && (
                        <select
                          value={llmModels.includes(llmModel) ? llmModel : ""}
                          onChange={(e) => {
                            if (e.target.value) setLlmModel(e.target.value);
                          }}
                          className="w-1/2 rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-slate-100"
                        >
                          <option value="">从已拉取模型选择…</option>
                          {llmModels.map((m) => (
                            <option key={m} value={m}>
                              {m}
                            </option>
                          ))}
                        </select>
                      )}
                      <input
                        type="text"
                        value={llmModel}
                        onChange={(e) => setLlmModel(e.target.value)}
                        placeholder="选择已拉取模型，或手动输入模型名（如 MiniMax-M1 / deepseek-chat）"
                        className="flex-1 rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-slate-100"
                      />
                    </div>
                    {llmFetchError && (
                      <div className="text-[11px] text-amber-400 pt-0.5">{llmFetchError}</div>
                    )}
                  </div>
                </div>

                <div className="flex items-center justify-end gap-2">
                  {savedHint === "llm" && (
                    <span className="text-xs text-emerald-400">大模型总结配置已保存</span>
                  )}
                  <button
                    type="button"
                    onClick={() => void handleSaveLlm()}
                    className="px-3 py-1.5 rounded-lg bg-brand-500 hover:bg-brand-600 text-xs text-white"
                  >
                    保存大模型配置
                  </button>
                </div>
              </div>
            </>
          )}

          {activeSettingsTab === "subtitle" && (
            <div className="space-y-4">
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-3">
                <label className="flex items-center justify-between">
                  <span>显示悬浮字幕窗</span>
                  <input
                    type="checkbox"
                    checked={subtitleStyle.visible}
                    onChange={(e) => void updateSubtitleStyle({ visible: e.target.checked })}
                    className="w-4 h-4 accent-brand-500"
                  />
                </label>
                <label className="flex items-center justify-between">
                  <span>锁定鼠标穿透（点击直达底层应用，Ctrl+Shift+L 解锁）</span>
                  <input
                    type="checkbox"
                    checked={subtitleStyle.clickThrough}
                    onChange={(e) =>
                      void updateSubtitleStyle({ clickThrough: e.target.checked })
                    }
                    className="w-4 h-4 accent-brand-500"
                  />
                </label>
                <label className="flex items-center justify-between">
                  <span>防共享 / 防录屏隐私保护（会议共享屏幕时对方不可见）</span>
                  <input
                    type="checkbox"
                    checked={subtitleStyle.excludeFromCapture}
                    onChange={(e) =>
                      void updateSubtitleStyle({ excludeFromCapture: e.target.checked })
                    }
                    className="w-4 h-4 accent-emerald-400"
                  />
                </label>
                <label className="flex items-center justify-between">
                  <span>文字清晰描边（浅色 PPT / 视频高对比）</span>
                  <input
                    type="checkbox"
                    checked={subtitleStyle.textStroke}
                    onChange={(e) =>
                      void updateSubtitleStyle({ textStroke: e.target.checked })
                    }
                    className="w-4 h-4 accent-brand-500"
                  />
                </label>
                <label className="flex items-center justify-between">
                  <span>回放录音时同步在悬浮字幕窗显示当前句</span>
                  <input
                    type="checkbox"
                    checked={subtitleStyle.syncWithPlayback}
                    onChange={(e) =>
                      void updateSubtitleStyle({ syncWithPlayback: e.target.checked })
                    }
                    className="w-4 h-4 accent-brand-500"
                  />
                </label>
              </div>

              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-3.5">
                <div className="flex items-center justify-between">
                  <span>排版模式</span>
                  <select
                    value={subtitleStyle.layout}
                    onChange={(e) =>
                      void updateSubtitleStyle({
                        layout: e.target.value as SubtitleLayoutMode,
                      })
                    }
                    className="rounded-lg bg-surface-950 border border-white/10 px-3 py-1.5 text-xs"
                  >
                    <option value="bilingual">双语对照（原文 + 译文）</option>
                    <option value="translation_focus">译文优先（弱化原文）</option>
                    <option value="translation_only">仅显示译文</option>
                  </select>
                </div>

                {/* 背景颜色设置（快捷色板 + 自定义取色器） */}
                <div className="flex items-center justify-between gap-4">
                  <span className="flex items-center gap-1.5">
                    <Palette className="w-4 h-4 text-sky-400" />
                    背景颜色
                  </span>
                  <div className="flex items-center gap-2">
                    {BG_COLOR_PRESETS.map((preset) => {
                      const active =
                        subtitleStyle.backgroundColor.toLowerCase() ===
                        preset.hex.toLowerCase();
                      return (
                        <button
                          key={preset.hex}
                          type="button"
                          title={`${preset.name} (${preset.hex})`}
                          onClick={() =>
                            void updateSubtitleStyle({ backgroundColor: preset.hex })
                          }
                          style={{ backgroundColor: preset.hex }}
                          className={`w-6 h-6 rounded-full border-2 transition ${
                            active
                              ? "border-brand-400 scale-110"
                              : "border-white/25 hover:border-white/60"
                          }`}
                        />
                      );
                    })}
                    <label
                      className="flex items-center gap-1.5 pl-1.5 ml-1 border-l border-white/10 cursor-pointer"
                      title="自定义悬浮字幕背景颜色"
                    >
                      <input
                        type="color"
                        value={subtitleStyle.backgroundColor}
                        onChange={(e) =>
                          void updateSubtitleStyle({ backgroundColor: e.target.value })
                        }
                        className="w-7 h-7 rounded bg-transparent border-0 cursor-pointer"
                      />
                      <span className="text-xs font-mono text-slate-300 uppercase">
                        {subtitleStyle.backgroundColor}
                      </span>
                    </label>
                  </div>
                </div>

                <div className="flex items-center justify-between">
                  <span>背景不透明度：{Math.round(subtitleStyle.backgroundOpacity * 100)}%</span>
                  <input
                    type="range"
                    min={0}
                    max={0.95}
                    step={0.05}
                    value={subtitleStyle.backgroundOpacity}
                    onChange={(e) =>
                      void updateSubtitleStyle({
                        backgroundOpacity: Number(e.target.value),
                      })
                    }
                    className="w-48 accent-brand-500"
                  />
                </div>

                <div className="flex items-center justify-between">
                  <span>译文字号：{subtitleStyle.fontSize}px</span>
                  <input
                    type="range"
                    min={14}
                    max={44}
                    value={subtitleStyle.fontSize}
                    onChange={(e) =>
                      void updateSubtitleStyle({ fontSize: Number(e.target.value) })
                    }
                    className="w-48 accent-brand-500"
                  />
                </div>

                <div className="flex items-center justify-between">
                  <span>最大显示句数：{subtitleStyle.maxLines} 句</span>
                  <input
                    type="range"
                    min={1}
                    max={4}
                    value={subtitleStyle.maxLines}
                    onChange={(e) =>
                      void updateSubtitleStyle({ maxLines: Number(e.target.value) })
                    }
                    className="w-48 accent-brand-500"
                  />
                </div>
              </div>
            </div>
          )}

          {activeSettingsTab === "audio" && (
            <div className="space-y-4">
              {/* 场景切换：场景1 面对面 vs 场景2 会议同传 */}
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-3">
                <div className="font-semibold text-white">同传与声音克隆使用场景</div>
                <div className="grid grid-cols-2 gap-3 text-xs">
                  <button
                    type="button"
                    onClick={() =>
                      void useHearStore.getState().deactivateMeetingVirtualCables(true)
                    }
                    className={`p-3 rounded-lg border text-left space-y-1 transition ${
                      ttsSettings.routingMode !== "meeting"
                        ? "bg-brand-500/20 border-brand-400/60 text-white"
                        : "bg-surface-900/70 border-white/10 text-slate-300 hover:border-white/20"
                    }`}
                  >
                    <div className="font-semibold">场景 1：面对面交流</div>
                    <div className="text-[11px] text-slate-400 leading-relaxed">
                      我和老外在一起：把我说的中文克隆成英文外放给对方听，内置全双工回声消除（AEC），边播边说不漏录。
                    </div>
                  </button>
                  <button
                    type="button"
                    onClick={() => void useHearStore.getState().activateMeetingMode()}
                    className={`p-3 rounded-lg border text-left space-y-1 transition ${
                      ttsSettings.routingMode === "meeting"
                        ? "bg-emerald-500/20 border-emerald-400/60 text-white"
                        : "bg-surface-900/70 border-white/10 text-slate-300 hover:border-white/20"
                    }`}
                  >
                    <div className="font-semibold">场景 2：会议同传（腾讯会议 / Teams / 微信）</div>
                    <div className="text-[11px] text-slate-400 leading-relaxed">
                      对方说外语 → 翻译送到我的耳机；我说中文 → 克隆我的英文送到虚拟麦克风给会议对方听。
                    </div>
                  </button>
                </div>

                {/* 输出设备路由配置 */}
                <div className="pt-2 space-y-3 border-t border-white/10">
                  <div className="flex items-center justify-between">
                    <span className="text-xs font-medium text-slate-200">输出设备路由</span>
                    <button
                      type="button"
                      onClick={() => void refreshOutputDevices()}
                      className="px-2.5 py-1 rounded bg-surface-900 border border-white/10 hover:bg-surface-700 text-[11px] text-slate-300"
                    >
                      刷新设备
                    </button>
                  </div>

                  <div className="grid grid-cols-1 gap-2.5 text-xs">
                    <label className="space-y-1">
                      <span className="text-slate-300">我的麦克风</span>
                      <select
                        value={ttsSettings.inputDeviceId || "default"}
                        onChange={(e) =>
                          updateTtsSettings({ inputDeviceId: e.target.value })
                        }
                        className="w-full rounded-lg bg-surface-900 border border-white/10 px-3 py-2 text-xs text-white focus:outline-none focus:border-brand-500"
                      >
                        <option value="default">自动（优先耳机麦克风）</option>
                        {inputDevices.map((d) => (
                          <option key={d.id} value={d.id}>
                            {d.name}
                            {d.isDefault ? "（系统默认）" : ""}
                          </option>
                        ))}
                      </select>
                    </label>

                    <label className="space-y-1">
                      <span className="text-slate-300">
                        {ttsSettings.routingMode === "meeting"
                          ? "我听译文的耳机 / 扬声器"
                          : "译文播报输出设备"}
                      </span>
                      <select
                        value={ttsSettings.outputDeviceId || "default"}
                        onChange={(e) =>
                          updateTtsSettings({ outputDeviceId: e.target.value })
                        }
                        className="w-full rounded-lg bg-surface-900 border border-white/10 px-3 py-2 text-xs text-white focus:outline-none focus:border-brand-500"
                      >
                        <option value="default">系统默认耳机 / 扬声器</option>
                        {outputDevices
                          .filter((d) => !d.isVirtual)
                          .map((d) => (
                            <option key={d.id} value={d.id}>
                              {d.name}
                              {d.isDefault ? "（默认）" : ""}
                            </option>
                          ))}
                      </select>
                    </label>
                  </div>
                </div>

                {/* 虚拟声卡独立区域（仅会议同传模式显示，使用横线与上方输出设备路由区分） */}
                {ttsSettings.routingMode === "meeting" && (() => {
                  const standardVirtuals = outputDevices.filter(
                    (d) => d.isVirtual && !d.name.toLowerCase().includes("16ch")
                  );
                  const virtualDevices =
                    standardVirtuals.length > 0
                      ? standardVirtuals
                      : outputDevices.filter((d) => d.isVirtual);
                  const hasHiFiCable = virtualDevices.some((d) =>
                    d.name.toLowerCase().includes("hi-fi")
                  );
                  const hasVbCable = virtualDevices.some((d) => {
                    const lower = d.name.toLowerCase();
                    return (
                      lower.includes("vb-audio virtual cable") ||
                      (lower.includes("cable input") && !lower.includes("hi-fi"))
                    );
                  });
                  return (
                  <div className="pt-3 space-y-3 border-t border-white/10">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <span className="text-xs font-medium text-slate-200">
                          虚拟声卡（会议同传）
                        </span>
                        {virtualDevices.length > 0 ? (
                          <span className="px-1.5 py-0.5 rounded bg-emerald-500/20 text-emerald-300 text-[10px] font-medium">
                            已检测到 {virtualDevices.length} 路
                          </span>
                        ) : (
                          <span className="px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-300 text-[10px] font-medium">
                            未安装
                          </span>
                        )}
                      </div>
                      <button
                        type="button"
                        onClick={() => void refreshOutputDevices()}
                        className="px-2.5 py-1 rounded bg-surface-900 border border-white/10 hover:bg-surface-700 text-[11px] text-slate-300"
                      >
                        刷新虚拟声卡
                      </button>
                    </div>

                    <div className="grid grid-cols-1 gap-3 text-xs">
                      <label className="space-y-1 block">
                        <span className="text-sky-300 font-medium">听对方（屏蔽原声）</span>
                        <select
                          value={ttsSettings.meetingLoopbackDeviceId || ""}
                          onChange={(e) => {
                            const val = e.target.value;
                            const clearMic =
                              val && val === ttsSettings.meetingMicOutputDeviceId;
                            void updateTtsSettings({
                              meetingLoopbackDeviceId: val,
                              ...(clearMic ? { meetingMicOutputDeviceId: "" } : {}),
                            });
                          }}
                          className="w-full rounded-lg bg-surface-900 border border-sky-500/30 px-3 py-2 text-xs text-white focus:outline-none focus:border-sky-400"
                        >
                          <option value="">不使用（保留原声，朗读译文时自动调小）</option>
                          {virtualDevices.map((d) => (
                            <option key={d.id} value={d.id}>
                              {d.name}
                              {d.id === ttsSettings.meetingMicOutputDeviceId
                                ? "（已用于「给对方听」，选中将切换）"
                                : ""}
                            </option>
                          ))}
                        </select>
                        <div className="text-[11px] text-slate-400">
                          会议软件「扬声器」也选此项，耳机里就只听译文（重启收音生效）。
                        </div>
                      </label>

                      <label className="space-y-1 block">
                        <span className="text-emerald-300 font-medium">给对方听（发送我的译文）</span>
                        <select
                          value={ttsSettings.meetingMicOutputDeviceId || ""}
                          onChange={(e) => {
                            const val = e.target.value;
                            const clearLoopback =
                              val && val === ttsSettings.meetingLoopbackDeviceId;
                            void updateTtsSettings({
                              meetingMicOutputDeviceId: val,
                              ...(clearLoopback ? { meetingLoopbackDeviceId: "" } : {}),
                            });
                          }}
                          className="w-full rounded-lg bg-surface-900 border border-emerald-500/30 px-3 py-2 text-xs text-white focus:outline-none focus:border-emerald-400"
                        >
                          <option value="">不使用</option>
                          {virtualDevices.map((d) => (
                            <option key={d.id} value={d.id}>
                              {d.name}
                              {d.id === ttsSettings.meetingLoopbackDeviceId
                                ? "（已用于「听对方」，选中将切换）"
                                : ""}
                            </option>
                          ))}
                        </select>
                        <div className="text-[11px] text-slate-400">
                          会议软件「麦克风」选对应的 Output，对方就只听你的译文。
                        </div>
                      </label>

                      {!hasVbCable && !hasHiFiCable ? (
                        <div className="rounded-lg bg-amber-500/10 border border-amber-400/30 p-2.5 text-[11px] text-amber-200 flex flex-wrap items-center justify-between gap-2">
                          <span>未检测到虚拟声卡（VB-Cable / Hi-Fi Cable），可按需分别安装。</span>
                          <div className="flex flex-wrap items-center gap-2">
                            <button
                              type="button"
                              onClick={() => {
                                void invoke("install_vb_cable").catch(() => {});
                              }}
                              className="px-2.5 py-1 rounded-md bg-amber-500/25 hover:bg-amber-500/35 border border-amber-400/50 text-amber-100 font-medium transition"
                            >
                              安装 VB-Cable
                            </button>
                            <button
                              type="button"
                              onClick={() => {
                                void invoke("install_hifi_cable").catch(() => {});
                              }}
                              className="px-2.5 py-1 rounded-md bg-amber-500/25 hover:bg-amber-500/35 border border-amber-400/50 text-amber-100 font-medium transition"
                            >
                              安装 Hi-Fi Cable
                            </button>
                            <button
                              type="button"
                              onClick={() => {
                                void invoke("open_github_url", {
                                  url: "https://vb-audio.com/Cable/",
                                }).catch(() => {});
                              }}
                              className="px-2.5 py-1 rounded-md bg-surface-900/80 hover:bg-surface-800 border border-white/15 text-slate-200 transition"
                            >
                              官网下载
                            </button>
                          </div>
                        </div>
                      ) : !hasVbCable || !hasHiFiCable ? (
                        <div className="rounded-lg bg-emerald-500/10 border border-emerald-400/30 p-2.5 text-[11px] text-emerald-200 flex flex-wrap items-center justify-between gap-2">
                          <span>
                            {hasVbCable
                              ? "已有 VB-Cable，缺少 Hi-Fi Cable（双路可同时屏蔽双方原声）。"
                              : "已有 Hi-Fi Cable，缺少 VB-Cable（双路可同时屏蔽双方原声）。"}
                          </span>
                          <button
                            type="button"
                            onClick={() => {
                              const cmd = hasVbCable
                                ? "install_hifi_cable"
                                : "install_vb_cable";
                              void invoke(cmd).catch(() => {});
                            }}
                            className="px-2.5 py-1 rounded-md bg-emerald-500/25 hover:bg-emerald-500/35 border border-emerald-400/50 text-emerald-100 font-medium transition"
                          >
                            {hasVbCable ? "安装缺少的 Hi-Fi Cable" : "安装缺少的 VB-Cable"}
                          </button>
                        </div>
                      ) : (
                        <div className="rounded-lg bg-emerald-500/10 border border-emerald-400/30 p-2.5 text-[11px] text-emerald-200">
                          已就绪 2 路独立虚拟声卡（VB-Cable + Hi-Fi Cable），上下分别选择即可双向只听译文。
                        </div>
                      )}
                    </div>
                  </div>
                  );
                })()}
              </div>

              {/* 声音克隆与自动播报开关 */}
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-3.5">
                <label className="flex items-center justify-between">
                  <div>
                    <div className="font-medium text-white">开启自动译文朗读总开关</div>
                    <div className="text-xs text-slate-400">
                      开启后可在下方按需启用「我说的话自动克隆播报」与「对方译文自动播报」。
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={ttsSettings.enabled}
                    onChange={(e) => updateTtsSettings({ enabled: e.target.checked })}
                    className="w-4 h-4 accent-brand-500"
                  />
                </label>

                <label className="flex items-center justify-between">
                  <span>优先使用 Qwen3-TTS 声音克隆（关闭后直接使用系统语音朗读）</span>
                  <input
                    type="checkbox"
                    checked={ttsSettings.useVoiceClone}
                    onChange={(e) => updateTtsSettings({ useVoiceClone: e.target.checked })}
                    className="w-4 h-4 accent-brand-500"
                  />
                </label>

                <label className="flex items-center justify-between gap-4">
                  <div>
                    <div className="text-slate-200">系统朗读声音</div>
                    <div className="text-[11px] text-slate-400">
                      关闭声音克隆或克隆降级时，按所选性别使用 Windows 系统语音朗读。
                    </div>
                  </div>
                  <select
                    value={ttsSettings.systemVoicePreference || "auto"}
                    onChange={(e) =>
                      updateTtsSettings({
                        systemVoicePreference: e.target.value as "auto" | "female" | "male",
                      })
                    }
                    className="rounded-lg bg-surface-900 border border-white/10 px-3 py-1.5 text-xs text-white focus:outline-none focus:border-brand-500"
                  >
                    <option value="auto">自动识别</option>
                    <option value="female">女声</option>
                    <option value="male">男声</option>
                  </select>
                </label>

                <label className="flex items-center justify-between">
                  <span>
                    我说的话译完自动克隆播报（
                    {ttsSettings.routingMode === "meeting" ? "送给会议虚拟麦" : "面对面外放"}）
                  </span>
                  <input
                    type="checkbox"
                    disabled={!ttsSettings.enabled}
                    checked={ttsSettings.autoSpeakMyMic}
                    onChange={(e) =>
                      updateTtsSettings({ autoSpeakMyMic: e.target.checked })
                    }
                    className="w-4 h-4 accent-brand-500 disabled:opacity-35"
                  />
                </label>

                <label className="flex items-center justify-between">
                  <span>对方说的话译完自动播报到我的耳机</span>
                  <input
                    type="checkbox"
                    disabled={!ttsSettings.enabled}
                    checked={ttsSettings.autoSpeakOther}
                    onChange={(e) =>
                      updateTtsSettings({ autoSpeakOther: e.target.checked })
                    }
                    className="w-4 h-4 accent-brand-500 disabled:opacity-35"
                  />
                </label>

                <label className="flex items-center justify-between gap-4">
                  <div>
                    <div className="text-slate-200">播报译文时完全静音麦克风（仅在极端外放回声时开启）</div>
                    <div className="text-[11px] text-slate-400">
                      默认关闭：使用全双工声学回声消除（AEC）并自动屏蔽系统内录回环，边播放边说话也能完整录入。
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={ttsSettings.muteMicWhileSpeaking}
                    onChange={(e) =>
                      updateTtsSettings({ muteMicWhileSpeaking: e.target.checked })
                    }
                    className="w-4 h-4 accent-brand-500 shrink-0"
                  />
                </label>

                <label className="flex items-center justify-between">
                  <span>播报译文时平滑压低原音频（Audio Ducking）</span>
                  <input
                    type="checkbox"
                    disabled={!ttsSettings.enabled}
                    checked={ttsSettings.duckOriginalAudio}
                    onChange={(e) =>
                      updateTtsSettings({ duckOriginalAudio: e.target.checked })
                    }
                    className="w-4 h-4 accent-brand-500 disabled:opacity-35"
                  />
                </label>

                <div className="flex items-center justify-between">
                  <span>压低目标音量：{Math.round(ttsSettings.duckRatio * 100)}%</span>
                  <input
                    type="range"
                    disabled={!ttsSettings.enabled || !ttsSettings.duckOriginalAudio}
                    min={0.1}
                    max={0.8}
                    step={0.05}
                    value={ttsSettings.duckRatio}
                    onChange={(e) =>
                      updateTtsSettings({ duckRatio: Number(e.target.value) })
                    }
                    className="w-48 accent-brand-500 disabled:opacity-35"
                  />
                </div>
              </div>

              {/* 固定我的声纹样本（弹出按指定文本录制 3~10 秒，本地与云端声纹克隆通用） */}
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 flex items-center justify-between gap-3">
                <div className="space-y-1">
                  <div className="font-medium text-white flex items-center gap-2">
                    <span>我的固定声纹样本</span>
                    <span
                      className={`px-2 py-0.5 rounded-full text-[11px] ${
                        hasMyVoiceSample
                          ? "bg-emerald-500/20 text-emerald-300"
                          : "bg-surface-900 text-slate-400"
                      }`}
                    >
                      {hasMyVoiceSample ? "已录制" : "未设置"}
                    </span>
                  </div>
                  <div className="text-xs text-slate-400">
                    按 Qwen3-TTS 模型要求弹出录制 3~10 秒指定朗读文本，本地与云端克隆服务均可直接复用，首句即原声。
                  </div>
                </div>
                <div className="flex items-center gap-2 shrink-0">
                  {hasMyVoiceSample && (
                    <button
                      type="button"
                      disabled={previewingVoiceSample}
                      onClick={async () => {
                        setPreviewingVoiceSample(true);
                        try {
                          const wav = await readMyVoiceSampleWav();
                          if (wav && wav.byteLength > 44) {
                            const copy = new Uint8Array(wav.byteLength);
                            copy.set(wav);
                            const url = URL.createObjectURL(
                              new Blob([copy.buffer], { type: "audio/wav" })
                            );
                            const audio = new Audio(url);
                            audio.onended = () => {
                              URL.revokeObjectURL(url);
                              setPreviewingVoiceSample(false);
                            };
                            audio.onerror = () => {
                              URL.revokeObjectURL(url);
                              setPreviewingVoiceSample(false);
                            };
                            await audio.play();
                            return;
                          }
                        } catch {
                          // ignore
                        }
                        setPreviewingVoiceSample(false);
                      }}
                      className="px-2.5 py-1.5 rounded-lg bg-surface-900 border border-white/10 text-slate-200 hover:bg-white/10 text-xs inline-flex items-center gap-1 disabled:opacity-50"
                    >
                      <Play className="w-3.5 h-3.5 text-emerald-400" />
                      <span>{previewingVoiceSample ? "试听中…" : "试听"}</span>
                    </button>
                  )}
                  <button
                    type="button"
                    onClick={() => setVoiceRecorderOpen(true)}
                    className="px-3 py-1.5 rounded-lg bg-brand-500 hover:bg-brand-600 text-white text-xs font-medium inline-flex items-center gap-1.5"
                  >
                    <Mic className="w-3.5 h-3.5" />
                    <span>{hasMyVoiceSample ? "重新录制" : "录制声纹"}</span>
                  </button>
                  {hasMyVoiceSample && (
                    <button
                      type="button"
                      onClick={() => void clearMyVoiceSample()}
                      className="px-2.5 py-1.5 rounded-lg bg-surface-900 border border-white/10 text-slate-300 hover:text-rose-300 text-xs"
                    >
                      清除
                    </button>
                  )}
                </div>
              </div>
              <VoiceSampleRecorderModal
                open={voiceRecorderOpen}
                onClose={() => setVoiceRecorderOpen(false)}
                onSave={saveRecordedMyVoiceSample}
              />
            </div>
          )}

          {activeSettingsTab === "general" && (
            <div className="space-y-4">
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-2 text-xs">
                <div className="font-semibold text-sm text-white mb-2">全局快捷键</div>
                <div className="grid grid-cols-2 gap-2 text-slate-300">
                  <div>开始 / 暂停录音翻译</div>
                  <div className="font-mono text-right text-sky-300">Ctrl + Shift + H</div>
                  <div>显示 / 隐藏悬浮字幕窗</div>
                  <div className="font-mono text-right text-sky-300">Ctrl + Shift + S</div>
                  <div>锁定 / 解锁鼠标穿透</div>
                  <div className="font-mono text-right text-sky-300">Ctrl + Shift + L</div>
                  <div>切换双语 / 仅译文</div>
                  <div className="font-mono text-right text-sky-300">Ctrl + Shift + B</div>
                  <div>复制最新一句译文</div>
                  <div className="font-mono text-right text-sky-300">Ctrl + Shift + C</div>
                </div>
              </div>

              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-2">
                <div className="font-semibold text-white">自定义术语表（每行「原文=译文」）</div>
                <textarea
                  rows={5}
                  value={glossary}
                  onChange={(e) => setGlossary(e.target.value)}
                  placeholder={"Hy-MT2=混元翻译\nSenseVoice=SenseVoice\nAPI design=接口设计"}
                  className="w-full rounded-lg bg-surface-950 border border-white/10 p-3 text-xs font-mono text-slate-100"
                />
              </div>
            </div>
          )}

          {activeSettingsTab === "system" && (
            <div className="space-y-4">
              {/* 当前版本与 GitHub 仓库快捷入口 */}
              <div className="rounded-xl bg-surface-800/70 border border-white/10 p-4 flex items-center justify-between gap-4">
                <div>
                  <div className="font-semibold text-white">
                    听见 Windows 客户端{" "}
                    <span className="ml-1.5 px-2 py-0.5 rounded-full bg-brand-500/20 text-brand-400 font-mono text-xs">
                      v{appVersion}
                    </span>
                  </div>
                  <p className="text-xs text-slate-400 mt-1">
                    版本检测仅追踪 Windows 发布标签（win-v*），支持启动自动检测与手动一键更新。
                  </p>
                </div>
                <div className="flex items-center gap-2 shrink-0">
                  <button
                    onClick={() =>
                      void openGithubUrl(
                        `https://github.com/${(ghRepo.trim() || "qianyueping1211/Hear").replace(/^https?:\/\/github\.com\//, "")}`
                      )
                    }
                    className="px-3 py-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-xs text-slate-200 flex items-center gap-1.5"
                  >
                    <ExternalLink className="w-3.5 h-3.5" /> GitHub 仓库
                  </button>
                  <button
                    onClick={() => void openLogsDir()}
                    title="打开客户端运行日志目录（hear-desktop.log）"
                    className="px-3 py-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-xs text-slate-200 flex items-center gap-1.5"
                  >
                    <FolderOpen className="w-3.5 h-3.5" /> 打开日志目录
                  </button>
                  <button
                    onClick={() =>
                      void openGithubUrl(
                        `https://github.com/${(ghRepo.trim() || "qianyueping1211/Hear").replace(/^https?:\/\/github\.com\//, "")}/releases`
                      )
                    }
                    className="px-3 py-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-xs text-slate-200 flex items-center gap-1.5"
                  >
                    <ExternalLink className="w-3.5 h-3.5" /> 全部发布页
                  </button>
                </div>
              </div>

              {/* GitHub Token 与自动检测设置 */}
              <div className="rounded-xl bg-surface-800/70 border border-white/10 p-4 space-y-3">
                <div className="font-semibold text-white">更新源与 GitHub Token</div>

                <div className="space-y-2">
                  <div>
                    <label className="text-xs text-slate-400 block mb-1">GitHub 仓库（owner/repo）</label>
                    <input
                      type="text"
                      value={ghRepo}
                      onChange={(e) => setGhRepo(e.target.value)}
                      placeholder="qianyueping1211/Hear"
                      className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-xs font-mono text-slate-100 focus:outline-none focus:border-brand-500"
                    />
                  </div>
                  <div>
                    <div className="flex items-center justify-between gap-2 mb-1">
                      <label className="text-xs text-slate-400">
                        GitHub Token（可选：私有仓库必填，公开仓库可避免 API 限频；持久化保存在本机）
                      </label>
                      {updateConfig.githubToken.trim() && (
                        <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-300 font-mono text-[11px] shrink-0">
                          已保存：{maskSecret(updateConfig.githubToken)}
                        </span>
                      )}
                    </div>
                    <div className="relative flex items-center">
                      <input
                        type={showGhToken ? "text" : "password"}
                        value={ghToken}
                        onChange={(e) => setGhToken(e.target.value)}
                        placeholder={
                          updateConfig.githubToken.trim()
                            ? `已加密保存（${maskSecret(updateConfig.githubToken)}）`
                            : "github_pat_... 或 ghp_..."
                        }
                        className="w-full rounded-lg bg-surface-950 border border-white/10 pl-3 pr-10 py-2 text-xs font-mono text-slate-100 focus:outline-none focus:border-brand-500"
                      />
                      <button
                        type="button"
                        onClick={() => setShowGhToken((v) => !v)}
                        title={showGhToken ? "隐藏 Token" : "显示 Token"}
                        className="absolute right-2 p-1 rounded text-slate-400 hover:text-white hover:bg-white/10"
                      >
                        {showGhToken ? <EyeOff className="w-3.5 h-3.5" /> : <Eye className="w-3.5 h-3.5" />}
                      </button>
                    </div>
                  </div>
                </div>

                <label className="flex items-center justify-between pt-1">
                  <span className="text-xs text-slate-200">每次打开软件自动检查新版本</span>
                  <input
                    type="checkbox"
                    checked={autoCheck}
                    onChange={(e) => setAutoCheck(e.target.checked)}
                    className="w-4 h-4 accent-brand-500"
                  />
                </label>

                <div className="flex items-center gap-2 pt-1">
                  <button
                    onClick={() => void handleSaveSystem()}
                    className="px-3 py-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-xs text-slate-200 flex items-center gap-1.5"
                  >
                    <Save className="w-3.5 h-3.5" />
                    {savedHint === "system" ? "已保存" : "保存设置"}
                  </button>
                  {updateInfo?.hasUpdate && updateInfo.assetApiUrl ? (
                    <>
                      <button
                        disabled={downloadingUpdate}
                        onClick={() => void downloadAndInstallUpdate()}
                        className="px-3.5 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-xs text-white font-medium flex items-center gap-1.5 disabled:opacity-50"
                      >
                        {downloadingUpdate ? (
                          <Loader2 className="w-3.5 h-3.5 animate-spin" />
                        ) : (
                          <Download className="w-3.5 h-3.5" />
                        )}
                        {downloadingUpdate ? "正在下载更新…" : "下载并更新"}
                      </button>
                      <button
                        disabled={checkingUpdate || downloadingUpdate}
                        onClick={() => void handleCheckUpdate()}
                        title="重新检查更新"
                        className="p-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-slate-400 hover:text-white disabled:opacity-50"
                      >
                        <RefreshCw
                          className={`w-3.5 h-3.5 ${checkingUpdate ? "animate-spin" : ""}`}
                        />
                      </button>
                    </>
                  ) : (
                    <button
                      disabled={checkingUpdate}
                      onClick={() => void handleCheckUpdate()}
                      className="px-3 py-1.5 rounded-lg bg-brand-500 hover:bg-brand-600 text-xs text-white flex items-center gap-1.5 disabled:opacity-50"
                    >
                      {checkingUpdate ? (
                        <Loader2 className="w-3.5 h-3.5 animate-spin" />
                      ) : (
                        <RefreshCw className="w-3.5 h-3.5" />
                      )}
                      {checkingUpdate ? "正在检查更新…" : "立即检查更新"}
                    </button>
                  )}
                </div>
              </div>

              {/* 新版本详情与一键更新卡片 */}
              {updateInfo && (
                <div className="rounded-xl bg-surface-950/90 border border-white/10 p-4 space-y-3 text-xs">
                  {updateInfo.error ? (
                    <div className="flex items-center gap-2 text-rose-300">
                      <AlertCircle className="w-4 h-4 shrink-0" />
                      <span>{updateInfo.error}</span>
                    </div>
                  ) : (
                    <>
                      <div className="flex items-center justify-between gap-2">
                        <div className="flex items-center gap-2">
                          {updateInfo.hasUpdate ? (
                            <>
                              <ArrowUpCircle className="w-4 h-4 text-emerald-400" />
                              <span className="font-semibold text-emerald-300">
                                发现新版本：{updateInfo.releaseTitle || `v${updateInfo.latestVersion}`}
                              </span>
                            </>
                          ) : (
                            <>
                              <CheckCircle2 className="w-4 h-4 text-emerald-400" />
                              <span className="font-semibold text-slate-200">
                                当前已是最新版本（最新：v{updateInfo.latestVersion}）
                              </span>
                            </>
                          )}
                        </div>
                        {updateInfo.publishedAt && (
                          <span className="text-slate-500 font-mono">
                            {updateInfo.publishedAt.slice(0, 10)}
                          </span>
                        )}
                      </div>

                      {/* 新版本介绍 */}
                      {updateInfo.releaseNotes && (
                        <div className="rounded-lg bg-surface-900 border border-white/5 p-3 max-h-44 overflow-y-auto whitespace-pre-wrap text-slate-300 leading-relaxed select-text">
                          {updateInfo.releaseNotes}
                        </div>
                      )}

                      {/* 下载进度条 */}
                      {downloadingUpdate && updateDownloadProgress && (
                        <div className="space-y-1">
                          <div className="flex justify-between text-[11px] text-sky-300 font-mono">
                            <span>正在下载 {updateInfo.assetName}…</span>
                            <span>
                              {(updateDownloadProgress.downloaded / 1048576).toFixed(1)} MB
                              {updateDownloadProgress.total > 0
                                ? ` / ${(updateDownloadProgress.total / 1048576).toFixed(1)} MB (${Math.round(
                                    (updateDownloadProgress.downloaded /
                                      updateDownloadProgress.total) *
                                      100
                                  )}%)`
                                : ""}
                            </span>
                          </div>
                          <div className="h-2 rounded-full bg-surface-800 overflow-hidden">
                            <div
                              className="h-full bg-brand-500 transition-all"
                              style={{
                                width:
                                  updateDownloadProgress.total > 0
                                    ? `${Math.min(
                                        100,
                                        Math.round(
                                          (updateDownloadProgress.downloaded /
                                            updateDownloadProgress.total) *
                                            100
                                        )
                                      )}%`
                                    : "35%",
                              }}
                            />
                          </div>
                        </div>
                      )}

                      {updateDownloadError && (
                        <div className="text-rose-300">{updateDownloadError}</div>
                      )}

                      <div className="flex items-center gap-2 pt-1">
                        {updateInfo.releaseUrl && (
                          <button
                            onClick={() => void openGithubUrl(updateInfo.releaseUrl!)}
                            className="px-3 py-1.5 rounded-lg bg-surface-800 border border-white/10 hover:bg-surface-700 text-slate-200 flex items-center gap-1.5"
                          >
                            <ExternalLink className="w-3.5 h-3.5" />
                            在 GitHub 查看此版本详情
                          </button>
                        )}
                      </div>
                    </>
                  )}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
