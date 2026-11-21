import SwiftUI
import WidgetKit

@main
struct HearLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        HearLiveActivityWidget()
    }
}

struct HearLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HearLiveActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("听见", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.center) {
                    expandedText(context.state)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text(context.state.isLive ? "实时翻译中" : "已完成")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }

    private func lockScreen(_ state: HearLiveActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("听见 · 实时翻译", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                Spacer()
            }
            if !state.translationOnly, !state.sourceText.isEmpty {
                (speakerPrefix(state.speaker) + Text(state.sourceText))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            translatedRow(state, lineLimit: 4, size: .title2)
        }
        .padding(14)
    }

    private func expandedText(_ state: HearLiveActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !state.translationOnly, !state.sourceText.isEmpty {
                (speakerPrefix(state.speaker) + Text(state.sourceText))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            translatedRow(state, lineLimit: 3, size: .title2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speakerPrefix(_ speaker: String?) -> Text {
        guard let speaker, !speaker.isEmpty else { return Text("") }
        return Text("\(speaker)：").fontWeight(.semibold)
    }

    @ViewBuilder
    private func translatedRow(_ state: HearLiveActivityAttributes.ContentState,
                               lineLimit: Int, size: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if state.translationOnly,
               let speaker = state.speaker,
               !speaker.isEmpty {
                Image(systemName: genderSymbol(state.speakerGender))
                    .foregroundStyle(genderColor(state.speakerGender))
                Text("\(speaker)：")
                    .fontWeight(.semibold)
            }
            Text(state.translatedText.isEmpty ? "正在等待译文…" : state.translatedText)
                .font(size.weight(.semibold))
                .lineLimit(lineLimit)
        }
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
