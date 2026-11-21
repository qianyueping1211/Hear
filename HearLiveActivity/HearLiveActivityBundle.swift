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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isLive ? "实时翻译中" : "已完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    expandedText(context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Image(systemName: "character.book.closed")
                        Text("\(context.state.sourceLanguage) → \(context.state.targetLanguage)")
                        if let speaker = context.state.speaker, !speaker.isEmpty {
                            Text("·")
                            Image(systemName: "person.wave.2")
                            Text(speaker).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text(compact(context.state.translatedText))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 64)
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
                Spacer()
                Text("\(state.sourceLanguage) → \(state.targetLanguage)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !state.sourceText.isEmpty {
                Text(state.sourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(state.translatedText.isEmpty ? "正在等待译文…" : state.translatedText)
                .font(.headline)
                .lineLimit(3)
            if let speaker = state.speaker, !speaker.isEmpty {
                Label(speaker, systemImage: "person.wave.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func expandedText(_ state: HearLiveActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !state.sourceText.isEmpty {
                Text(state.sourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(state.translatedText.isEmpty ? "正在等待译文…" : state.translatedText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compact(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        return String(clean.prefix(18))
    }
}
