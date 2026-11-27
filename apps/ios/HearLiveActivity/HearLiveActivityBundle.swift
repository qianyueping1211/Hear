import SwiftUI
import WidgetKit

@main
struct HearLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        HearLiveActivityWidget()
    }
}

struct HearLiveActivityWidget: Widget {
    private let pausedLabel = "翻译暂停中"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HearLiveActivityAttributes.self) { context in
            lockScreen(context.state, paused: !context.state.isLive || context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let paused = !context.state.isLive || context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("听见", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.center) {
                    activityText(context.state, paused: paused, sourceLines: 2, translationLines: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text(paused ? pausedLabel : "实时翻译中")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } minimal: {
                Image(systemName: paused ? "pause.fill" : "waveform")
                    .foregroundStyle(.cyan)
                    .accessibilityLabel(paused ? pausedLabel : "实时翻译中")
            }
            .keylineTint(.cyan)
        }
    }

    private func lockScreen(_ state: HearLiveActivityAttributes.ContentState, paused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(paused ? "听见" : "听见 · 实时翻译", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                Spacer()
            }
            activityText(state, paused: paused, sourceLines: 3, translationLines: 4)
        }
        .padding(14)
    }

    private func activityText(_ state: HearLiveActivityAttributes.ContentState, paused: Bool,
                              sourceLines: Int, translationLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if paused {
                Text(pausedLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                if !state.translationOnly, !state.sourceText.isEmpty {
                    (speakerPrefix(state.speaker) + Text(state.sourceText))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(sourceLines)
                }
                translatedRow(state, lineLimit: translationLines)
            }
        }
    }

    private func speakerPrefix(_ speaker: String?) -> Text {
        guard let speaker, !speaker.isEmpty else { return Text("") }
        return Text("\(speaker)：").fontWeight(.semibold)
    }

    @ViewBuilder
    private func translatedRow(_ state: HearLiveActivityAttributes.ContentState,
                               lineLimit: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if state.translationOnly,
               let speaker = state.speaker,
               !speaker.isEmpty {
                Image(systemName: genderSymbol(state.speakerGender))
                    .foregroundStyle(genderColor(state.speakerGender))
                Text("\(speaker)：")
                    .fontWeight(.semibold)
            }
            translatedDisplayText(state)
                .font(.title2.weight(.semibold))
                .lineLimit(lineLimit)
        }
    }

    /// 译文修订对比高亮：使用与主界面完全一致的词级 LCS 差异算法（TranslationRevision），
    /// 仅高亮真正被修改的词，避免前后缀粗对比把整句都标成青色。
    private func translatedDisplayText(_ state: HearLiveActivityAttributes.ContentState) -> Text {
        let translated = state.translatedText
        guard !translated.isEmpty else { return Text("正在等待译文…") }
        guard let baseline = state.translationBaseline, !baseline.isEmpty, baseline != translated else {
            return Text(translated)
        }
        let updated = tokenize(translated)
        let inserted = Set(updated.difference(from: tokenize(baseline)).insertions.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })
        return updated.enumerated().reduce(Text("")) { rendered, pair in
            let (index, token) = pair
            let changed = inserted.contains(index) && !token.allSatisfy(\.isWhitespace)
            return rendered + (changed ? Text(token).bold().foregroundColor(.cyan) : Text(token))
        }
    }

    private func tokenize(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        for character in text {
            let scalar = character.unicodeScalars.first?.value ?? 0
            let canJoinWord = (character.isLetter || character.isNumber)
                && !(0x3000...0x9FFF).contains(scalar) && !(0x20000...0x323AF).contains(scalar)
            if canJoinWord {
                word.append(character)
            } else {
                if !word.isEmpty {
                    result.append(word)
                    word = ""
                }
                result.append(String(character))
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    private func genderSymbol(_ gender: String?) -> String {
        gender == "male" || gender == "female" ? "person.crop.circle.fill" : "person.crop.circle"
    }

    private func genderColor(_ gender: String?) -> Color {
        switch gender {
        case "male": return Color(red: 0.49, green: 0.74, blue: 0.98)
        case "female": return Color(red: 0.97, green: 0.57, blue: 0.62)
        default: return .secondary
        }
    }
}
