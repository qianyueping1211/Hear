import {
  CheckCircle2,
  Copy,
  RefreshCw,
  Server,
  Shield,
  Sliders,
  Volume2,
  Wifi,
  X,
} from "lucide-react";
import { useHearStore } from "../../stores/useHearStore";
import type { EngineSource, SubtitleLayoutMode } from "../../types/hear";

export function SettingsModal() {
  const {
    settingsOpen,
    activeSettingsTab,
    setSettingsOpen,
    switches,
    serviceStatus,
    subtitleStyle,
    ttsSettings,
    glossary,
    updateSwitches,
    startLocalServer,
    stopLocalServer,
    probeHealth,
    updateSubtitleStyle,
    updateTtsSettings,
    setGlossary,
  } = useHearStore();

  if (!settingsOpen) return null;

  const tabs: { id: typeof activeSettingsTab; label: string; icon: React.ReactNode }[] = [
    { id: "server", label: "本机与云端服务", icon: <Server className="w-4 h-4" /> },
    { id: "subtitle", label: "悬浮字幕样式", icon: <Sliders className="w-4 h-4" /> },
    { id: "audio", label: "朗读与原音压低", icon: <Volume2 className="w-4 h-4" /> },
    { id: "general", label: "快捷键与术语表", icon: <Shield className="w-4 h-4" /> },
  ];

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
        <option value="local">本机托管模型服务</option>
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
              {/* 双开关核心区 */}
              <div className="rounded-xl bg-surface-800/70 border border-white/10 p-4 space-y-4">
                <div className="flex items-start justify-between gap-4">
                  <div>
                    <div className="font-semibold text-white flex items-center gap-2">
                      开关 1：本机模型服务（默认仅限本机访问）
                      <span
                        className={`px-2 py-0.5 rounded-full text-[11px] ${
                          serviceStatus.running
                            ? "bg-emerald-500/20 text-emerald-300"
                            : "bg-slate-700 text-slate-300"
                        }`}
                      >
                        {serviceStatus.running
                          ? `运行中 (${serviceStatus.bindHost}:${serviceStatus.port})`
                          : "已停止"}
                      </span>
                    </div>
                    <p className="text-xs text-slate-400 mt-1">
                      托管现有 server/ 服务（SenseVoice / Whisper / Hy-MT2 / Qwen3-TTS）。关闭局域网共享时严格绑定 127.0.0.1 并使用本机会话密钥，不对外开放端口。
                    </p>
                  </div>
                  <input
                    type="checkbox"
                    checked={switches.localServerEnabled}
                    onChange={(e) =>
                      void updateSwitches({ localServerEnabled: e.target.checked })
                    }
                    className="w-5 h-5 accent-brand-500 mt-0.5 cursor-pointer"
                  />
                </div>

                {switches.localServerEnabled && (
                  <div className="flex items-center gap-2 pt-1">
                    <button
                      onClick={() => void startLocalServer()}
                      className="px-3 py-1.5 rounded-lg bg-brand-500 hover:bg-brand-600 text-xs text-white"
                    >
                      启动 / 重载本机服务
                    </button>
                    <button
                      onClick={() => void stopLocalServer()}
                      className="px-3 py-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-xs text-slate-200"
                    >
                      停止服务
                    </button>
                    <button
                      onClick={() => void probeHealth()}
                      className="px-3 py-1.5 rounded-lg bg-surface-950 border border-white/10 hover:bg-white/5 text-xs text-slate-200 flex items-center gap-1"
                    >
                      <RefreshCw className="w-3.5 h-3.5" /> 刷新状态
                    </button>
                  </div>
                )}

                <div className="border-t border-white/10 pt-4 flex items-start justify-between gap-4">
                  <div>
                    <div className="font-semibold text-white flex items-center gap-2">
                      <Wifi className="w-4 h-4 text-sky-400" />
                      开关 2：共享给 iPhone / 局域网设备
                    </div>
                    <p className="text-xs text-slate-400 mt-1">
                      开启后切换监听 0.0.0.0:8000 并强制启用 HTTPS 证书与访问口令；桌面端与 iPhone 共用同一套模型实例与显存，关闭后立即缩回仅本机访问。
                    </p>
                  </div>
                  <input
                    type="checkbox"
                    disabled={!switches.localServerEnabled}
                    checked={switches.lanShareEnabled}
                    onChange={(e) =>
                      void updateSwitches({ lanShareEnabled: e.target.checked })
                    }
                    className="w-5 h-5 accent-sky-400 mt-0.5 cursor-pointer disabled:opacity-35"
                  />
                </div>

                {switches.lanShareEnabled && (
                  <div className="rounded-lg bg-surface-950/90 border border-sky-500/30 p-3 space-y-2 text-xs">
                    <div className="text-sky-300 font-medium flex items-center gap-1.5">
                      <CheckCircle2 className="w-3.5 h-3.5" />
                      局域网共享已启用（强制口令 + HTTPS 严格配对）
                    </div>
                    <div className="flex items-center justify-between gap-2 bg-surface-900 rounded px-2.5 py-1.5 font-mono text-slate-200">
                      <span className="truncate">
                        {serviceStatus.pairingAddress ||
                          serviceStatus.lanAddresses[0] ||
                          "启动服务后自动生成局域网配对地址 (#hear-root=...)"}
                      </span>
                      {serviceStatus.pairingAddress && (
                        <button
                          onClick={() =>
                            void navigator.clipboard?.writeText(serviceStatus.pairingAddress)
                          }
                          className="p-1 rounded hover:bg-white/10 shrink-0"
                          title="复制 iPhone 专用配对地址"
                        >
                          <Copy className="w-3.5 h-3.5" />
                        </button>
                      )}
                    </div>
                    {serviceStatus.accessTokenMasked && (
                      <div className="text-slate-400">
                        访问口令：<span className="font-mono text-slate-200">{serviceStatus.accessTokenMasked}</span>
                      </div>
                    )}
                  </div>
                )}

                {/* 三个模型就绪态 */}
                <div className="grid grid-cols-3 gap-2.5 pt-1 text-xs">
                  <div className="rounded-lg bg-surface-950/70 p-2.5 border border-white/5">
                    <div className="text-slate-400">语音识别 (ASR)</div>
                    <div className={`mt-1 font-medium ${serviceStatus.asrReady ? "text-emerald-400" : "text-amber-300"}`}>
                      {serviceStatus.asrDetail}
                    </div>
                  </div>
                  <div className="rounded-lg bg-surface-950/70 p-2.5 border border-white/5">
                    <div className="text-slate-400">文本翻译 (MT)</div>
                    <div className={`mt-1 font-medium ${serviceStatus.mtReady ? "text-emerald-400" : "text-amber-300"}`}>
                      {serviceStatus.mtDetail}
                    </div>
                  </div>
                  <div className="rounded-lg bg-surface-950/70 p-2.5 border border-white/5">
                    <div className="text-slate-400">声音克隆 (TTS)</div>
                    <div className={`mt-1 font-medium ${serviceStatus.cloneReady ? "text-emerald-400" : "text-slate-400"}`}>
                      {serviceStatus.cloneDetail}
                    </div>
                  </div>
                </div>
              </div>

              {/* 三个能力独立选本机/云端 */}
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4">
                <div className="font-semibold text-white mb-2">模型路由（各能力独立切换本机 / 云端）</div>
                {renderSourceSelect("语音识别 (SenseVoice + Whisper)", switches.asrSource, (v) =>
                  void updateSwitches({ asrSource: v })
                )}
                {renderSourceSelect("文本翻译 (Hy-MT2)", switches.mtSource, (v) =>
                  void updateSwitches({ mtSource: v })
                )}
                {renderSourceSelect("声音克隆 (Qwen3-TTS)", switches.cloneSource, (v) =>
                  void updateSwitches({ cloneSource: v })
                )}
              </div>

              {/* 远端云端地址 */}
              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-3">
                <div className="font-semibold text-white">远端云端服务地址（与 iPhone 共用同一协议）</div>
                <input
                  type="text"
                  placeholder="https://192.168.x.x:8000 或 https://...#hear-root=..."
                  value={switches.remoteCloudAddress}
                  onChange={(e) =>
                    void updateSwitches({ remoteCloudAddress: e.target.value })
                  }
                  className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-xs font-mono text-slate-100"
                />
                <input
                  type="password"
                  placeholder="访问口令 X-Hear-Token（若远端开启鉴权）"
                  value={switches.remoteAccessToken}
                  onChange={(e) =>
                    void updateSwitches({ remoteAccessToken: e.target.value })
                  }
                  className="w-full rounded-lg bg-surface-950 border border-white/10 px-3 py-2 text-xs font-mono text-slate-100"
                />
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

              <div className="rounded-xl bg-surface-800/60 border border-white/10 p-4 space-y-3">
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
