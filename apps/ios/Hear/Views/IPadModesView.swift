import SwiftUI

/// iPad 专属大屏场景模式
enum IPadSpecialMode: String, Identifiable {
    case faceToFace   // 面对面双人同屏（上半屏 180° 旋转面向对方，下半屏面向自己）
    case captionBoard // 大屏专注字幕板（支架/会议/看外语视频专用超大双语字幕）

    var id: String { rawValue }
}

// MARK: - 1. 面对面双人同屏模式（平放桌面，双人面对面实时交流）

struct IPadFaceToFaceView: View {
    @EnvironmentObject var session: LiveSession
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 上半屏：旋转 180° 面向坐在桌子对面的 B 方
            faceHalf(
                primaryLang: session.langB,
                secondaryLang: session.langA,
                isOpponent: true
            )
            .rotationEffect(.degrees(180))

            // 中央控制条：退出 / 互换语言 / 一键开始停止 / 自动朗读
            centerBar

            // 下半屏：正向面向自己（A 方）
            faceHalf(
                primaryLang: session.langA,
                secondaryLang: session.langB,
                isOpponent: false
            )
        }
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var centerBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Label("退出面对面", systemImage: "xmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            // 语言方向指示与快速互换
            Button {
                session.swapLanguages()
            } label: {
                HStack(spacing: 6) {
                    Text("\(session.langA.flag) \(session.langA.name)")
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption.weight(.bold))
                    Text("\(session.langB.flag) \(session.langB.name)")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)

            // 主收音开关（实时双语自动识别）
            Button {
                Task { await session.toggle() }
            } label: {
                Label(
                    session.isRunning ? "停止收音" : "开始对话",
                    systemImage: session.isRunning ? "stop.circle.fill" : "mic.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(session.isRunning ? Color.red : Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!session.isRunning && session.phase != .ready)

            Spacer()

            // 自动朗读开关
            Button {
                session.speakOutput.toggle()
            } label: {
                Label(
                    session.speakOutput ? "朗读开" : "朗读关",
                    systemImage: session.speakOutput ? "speaker.wave.2.fill" : "speaker.slash"
                )
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    session.speakOutput ? Color.green.opacity(0.18) : Color(.secondarySystemBackground),
                    in: Capsule()
                )
                .foregroundStyle(session.speakOutput ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
        .overlay(Divider(), alignment: .bottom)
    }

    private func faceHalf(primaryLang: Language, secondaryLang: Language, isOpponent: Bool) -> some View {
        let displayLang = session.chineseDisplayLanguage
        return VStack(spacing: 0) {
            // 这一侧的语种角标
            HStack {
                Label("\(primaryLang.flag) \(primaryLang.name)", systemImage: isOpponent ? "person.wave.2" : "person")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                Spacer()
                if session.isRunning {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text("正在聆听…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.items.isEmpty && session.partial.isEmpty {
                            Text(session.isRunning ? "请直接说话，系统会自动识别并翻译…" : "点击中间「开始对话」，平放 iPad 即可面对面交流")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 36)
                        }
                        ForEach(session.items.suffix(20)) { item in
                            faceMessageCard(item: item, primaryLang: primaryLang, displayLang: displayLang)
                                .id(item.id)
                        }
                        if !session.partial.isEmpty {
                            let showPartialPrimary = (session.partialSource == primaryLang)
                                ? session.partial
                                : (session.partialTranslation.isEmpty ? session.partial : session.partialTranslation)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(showPartialPrimary)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if session.partialSource != primaryLang && !session.partialTranslation.isEmpty {
                                    Text(session.partial)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                            .id("face-partial")
                        }
                        Color.clear.frame(height: 1).id("face-bottom")
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                }
                .onChange(of: session.items.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("face-bottom", anchor: .bottom) }
                }
                .onChange(of: session.items.last?.translated) { _, _ in
                    proxy.scrollTo("face-bottom", anchor: .bottom)
                }
                .onChange(of: session.partial) { _, _ in
                    proxy.scrollTo("face-bottom", anchor: .bottom)
                }
                .onChange(of: session.partialTranslation) { _, _ in
                    proxy.scrollTo("face-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 对当前这一侧用户，优先用大号字展示他们看得懂的语言（译文或原文），另一语言作为小字对照
    private func faceMessageCard(item: TranslationItem, primaryLang: Language, displayLang: ChineseDisplayLanguage) -> some View {
        let src = item.displayedSource(using: displayLang)
        let tr = item.displayedTranslation(using: displayLang)
        let isPrimarySource = (item.source == primaryLang)
        let mainText = isPrimarySource ? src : (tr.isEmpty ? src : tr)
        let subText = isPrimarySource ? tr : (tr.isEmpty ? "" : src)

        return VStack(alignment: .leading, spacing: 4) {
            Text(mainText)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if !subText.isEmpty && subText != mainText {
                Text(subText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            isPrimarySource ? Color(.secondarySystemGroupedBackground) : Color.accentColor.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .onTapGesture {
            if item.canReadAloud { session.tapRead(item) }
        }
    }
}

// MARK: - 2. 大屏专注字幕板（支架 / 会议 / 看外语视频专用超大字幕）

struct IPadCaptionBoardView: View {
    @EnvironmentObject var session: LiveSession
    var onClose: () -> Void

    @AppStorage("ipadCaptionFontSize") private var fontSize: Double = 36
    @AppStorage("ipadCaptionShowSource") private var showSource: Bool = true

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topControls
                Divider().overlay(Color.white.opacity(0.12))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if session.items.isEmpty && session.partial.isEmpty {
                                VStack(spacing: 14) {
                                    Image(systemName: "captions.bubble")
                                        .font(.system(size: 46))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Text(session.isRunning ? "正在实时收音，字幕将大字显示在这里…" : "点击右上角「开始收音」启动大屏双语字幕")
                                        .font(.title3)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 120)
                            }

                            ForEach(session.items.suffix(30)) { item in
                                captionBlock(
                                    source: item.displayedSource(using: session.chineseDisplayLanguage),
                                    translation: item.displayedTranslation(using: session.chineseDisplayLanguage),
                                    speaker: item.speakerLabel,
                                    isLive: false
                                )
                                .id(item.id)
                            }

                            if !session.partial.isEmpty {
                                captionBlock(
                                    source: session.partial,
                                    translation: session.partialTranslation,
                                    speaker: nil,
                                    isLive: true
                                )
                                .id("caption-partial")
                            }

                            Color.clear.frame(height: 24).id("caption-bottom")
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 28)
                    }
                    .onChange(of: session.items.last?.id) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("caption-bottom", anchor: .bottom) }
                    }
                    .onChange(of: session.items.last?.translated) { _, _ in
                        proxy.scrollTo("caption-bottom", anchor: .bottom)
                    }
                    .onChange(of: session.partial) { _, _ in
                        proxy.scrollTo("caption-bottom", anchor: .bottom)
                    }
                    .onChange(of: session.partialTranslation) { _, _ in
                        proxy.scrollTo("caption-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Label("退出字幕板", systemImage: "xmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)

            Text("\(session.langA.flag) \(session.langA.name) ⇄ \(session.langB.flag) \(session.langB.name)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))

            Spacer()

            // 原文显示开关
            Button {
                showSource.toggle()
            } label: {
                Text(showSource ? "双语字幕" : "仅看译文")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(showSource ? 0.2 : 0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            // 字号调节
            HStack(spacing: 6) {
                Button {
                    fontSize = max(22, fontSize - 4)
                } label: {
                    Text("A-")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 30)
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26)

                Button {
                    fontSize = min(60, fontSize + 4)
                } label: {
                    Text("A+")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 30)
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            // 收音控制
            Button {
                Task { await session.toggle() }
            } label: {
                Label(
                    session.isRunning ? "停止收音" : "开始收音",
                    systemImage: session.isRunning ? "stop.circle.fill" : "mic.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(session.isRunning ? Color.red : Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!session.isRunning && session.phase != .ready)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func captionBlock(source: String, translation: String, speaker: String?, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let speaker {
                Text(speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            if showSource && !source.isEmpty {
                Text(source)
                    .font(.system(size: max(16, fontSize * 0.56), weight: .regular))
                    .foregroundStyle(.white.opacity(isLive ? 0.72 : 0.55))
            }
            let mainLine = translation.isEmpty ? source : translation
            if !mainLine.isEmpty {
                Text(mainLine)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(isLive ? Color.yellow.opacity(0.95) : .white)
                    .lineSpacing(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
