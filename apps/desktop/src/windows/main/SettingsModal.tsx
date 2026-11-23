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
  Palette,
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
import { useHearStore } from "../../stores/useHearStore";
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
    glossary,
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
  const [savedHint, setSavedHint] = useState<"local" | "cloud" | "system" | null>(null);
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [removeModelsOnUninstall, setRemoveModelsOnUninstall] = useState(false);

  // 仅在弹窗打开瞬间同步一次草稿并做只读状态探测，避免保存单项配置时把其它草稿或「已保存」提示冲掉
  useEffect(() => {
    if (!settingsOpen) return;
    const snap = useHearStore.getState();
    setLocalAddress(snap.serviceConfig.localServiceAddress);
    setLocalToken(snap.serviceConfig.localAccessToken);
    setCloudAddress(snap.serviceConfig.cloudServiceAddress);
    setCloudToken(snap.serviceConfig.cloudAccessToken);
    setGhRepo(snap.updateConfig.repo);
    setGhToken(snap.updateConfig.githubToken);
    setShowGhToken(false);
    setAutoCheck(snap.updateConfig.autoCheckOnStartup);
    setSavedHint(null);
    setConfirmUninstall(false);
    void refreshLocalServerInstallStatus();
    // 若已配置本机地址且本次尚未探测过，打开设置页自动做一次只读 /health 检测
    const localTested = Boolean(
      snap.localStatus.address || snap.localStatus.error || snap.localStatus.latencyMs > 0
    );
    if (!localTested && snap.serviceConfig.localServiceAddress.trim()) {
      void testServiceConnection("local");
    }
  }, [settingsOpen, refreshLocalServerInstallStatus, testServiceConnection]);

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
    const cfg = {
      repo: ghRepo.trim() || "qianyueping1211/Hear",
      githubToken: ghToken.trim(),
      autoCheckOnStartup: autoCheck,
    };
    await checkForUpdates(cfg);
  };

  const handleSaveLocal = async () => {
    await saveServiceConfig({
      localServiceAddress: localAddress.trim(),
      localAccessToken: localToken.trim(),
    });
    setSavedHint("local");
    setTimeout(() => setSavedHint((h) => (h === "local" ? null : h)), 2000);
  };

  const handleTestLocal = async () => {
    const addr = localAddress.trim();
    const tok = localToken.trim();
    await saveServiceConfig({ localServiceAddress: addr, localAccessToken: tok });
    await testServiceConnection("local", addr, tok);
  };

  const handleSaveCloud = async () => {
    await saveServiceConfig({
      cloudServiceAddress: cloudAddress.trim(),
      cloudAccessToken: cloudToken.trim(),
    });
    setSavedHint("cloud");
    setTimeout(() => setSavedHint((h) => (h === "cloud" ? null : h)), 2000);
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
            <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-4">
              <label className="flex items-center justify-between">
                <div>
                  <div className="font-medium text-white">开启桌面译文朗读（默认关闭，仅看字幕）</div>
                  <div className="text-xs text-slate-400">
                    系统内录会自动排除听见自身进程树音频，防止朗读声回环录入。
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
                <span>优先使用 Qwen3-TTS 声音克隆（不可用时自动退回系统语音）</span>
                <input
                  type="checkbox"
                  disabled={!ttsSettings.enabled}
                  checked={ttsSettings.useVoiceClone}
                  onChange={(e) => updateTtsSettings({ useVoiceClone: e.target.checked })}
                  className="w-4 h-4 accent-brand-500 disabled:opacity-35"
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
                        {updateInfo.hasUpdate && updateInfo.assetApiUrl && (
                          <button
                            disabled={downloadingUpdate}
                            onClick={() => void downloadAndInstallUpdate()}
                            className="px-3.5 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white font-medium flex items-center gap-1.5 disabled:opacity-50"
                          >
                            {downloadingUpdate ? (
                              <Loader2 className="w-3.5 h-3.5 animate-spin" />
                            ) : (
                              <Download className="w-3.5 h-3.5" />
                            )}
                            {downloadingUpdate
                              ? "正在下载安装程序…"
                              : `下载并更新（${updateInfo.assetName ?? "安装包"}）`}
                          </button>
                        )}
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
