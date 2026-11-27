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

    /// 译文修订对比高亮：未改动部分保持原色，被修正的部分以青色加粗突出（与主界面一致）
    private func translatedDisplayText(_ state: HearLiveActivityAttributes.ContentState) -> Text {
        let translated = state.translatedText
        guard !translated.isEmpty else { return Text("正在等待译文…") }
        guard let baseline = state.translationBaseline, !baseline.isEmpty, baseline != translated else {
            return Text(translated)
        }
        let oldChars = Array(baseline)
        let newChars = Array(translated)
        var prefix = 0
        while prefix < oldChars.count && prefix < newChars.count && oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (oldChars.count - prefix) && suffix < (newChars.count - prefix)
                && oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        let changedStart = prefix
        let changedEnd = newChars.count - suffix
        guard changedStart < changedEnd else { return Text(translated) }
        var out = Text("")
        if changedStart > 0 {
            out = out + Text(String(newChars[0..<changedStart]))
        }
        out = out + Text(String(newChars[changedStart..<changedEnd])).bold().foregroundColor(.cyan)
        if changedEnd < newChars.count {
            out = out + Text(String(newChars[changedEnd..<newChars.count]))
        }
        return out
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
