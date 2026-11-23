import { useEffect, useState } from "react";
import {
  AlertCircle,
  CheckCircle2,
  Cloud,
  Laptop,
  Loader2,
  Palette,
  RefreshCw,
  Save,
  Server,
  Shield,
  Sliders,
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
    settingsOpen,
    activeSettingsTab,
    setSettingsOpen,
    serviceConfig,
    localStatus,
    cloudStatus,
    testingLocal,
    testingCloud,
    subtitleStyle,
    ttsSettings,
    glossary,
    saveServiceConfig,
    testServiceConnection,
    updateSubtitleStyle,
    updateTtsSettings,
    setGlossary,
  } = useHearStore();

  // 使用本地草稿状态，输入过程绝不触发后端请求或任何进程动作
  const [localAddress, setLocalAddress] = useState(serviceConfig.localServiceAddress);
  const [localToken, setLocalToken] = useState(serviceConfig.localAccessToken);
  const [cloudAddress, setCloudAddress] = useState(serviceConfig.cloudServiceAddress);
  const [cloudToken, setCloudToken] = useState(serviceConfig.cloudAccessToken);
  const [savedHint, setSavedHint] = useState<"local" | "cloud" | null>(null);

  useEffect(() => {
    if (settingsOpen) {
      setLocalAddress(serviceConfig.localServiceAddress);
      setLocalToken(serviceConfig.localAccessToken);
      setCloudAddress(serviceConfig.cloudServiceAddress);
      setCloudToken(serviceConfig.cloudAccessToken);
      setSavedHint(null);
    }
  }, [settingsOpen, serviceConfig]);

  if (!settingsOpen) return null;

  const tabs: { id: typeof activeSettingsTab; label: string; icon: React.ReactNode }[] = [
    { id: "server", label: "模型服务与连接", icon: <Server className="w-4 h-4" /> },
    { id: "subtitle", label: "悬浮字幕样式", icon: <Sliders className="w-4 h-4" /> },
    { id: "audio", label: "朗读与原音压低", icon: <Volume2 className="w-4 h-4" /> },
    { id: "general", label: "快捷键与术语表", icon: <Shield className="w-4 h-4" /> },
  ];

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
                    由服务端自行启动与管理，客户端仅连接并检测状态
                  </span>
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
        </div>
      </div>
    </div>
  );
}
