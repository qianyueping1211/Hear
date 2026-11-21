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
            Text(state.translatedText.isEmpty ? "正在等待译文…" : state.translatedText)
                .font(.title2.weight(.semibold))
                .lineLimit(4)
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
            Text(state.translatedText.isEmpty ? "正在等待译文…" : state.translatedText)
                .font(.title2.weight(.semibold))
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speakerPrefix(_ speaker: String?) -> Text {
        guard let speaker, !speaker.isEmpty else { return Text("") }
        return Text("\(speaker)：").fontWeight(.semibold)
    }
}
