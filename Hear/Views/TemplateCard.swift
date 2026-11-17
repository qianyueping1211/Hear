import SwiftUI

/// 总结模板卡片
struct TemplateCard: View {
    let template: SummaryTemplate
    var inUse: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: template.icon)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.primary)
                Spacer()
                if inUse {
                    Text("使用中")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.primary, in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Text(template.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            Text(LocalizedStringKey(template.description))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ForEach(template.tags, id: \.self) { tag in
                    Text(tag.text)
                        .font(.footnote)
                        .foregroundStyle(tag.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(inUse ? Color.primary : Color(.separator), lineWidth: inUse ? 1.5 : 0.5)
        )
    }
}

/// 选择模板
struct TemplatePicker: View {
    let current: String
    var onPick: (SummaryTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(SummaryTemplate.all) { t in
                        Button {
                            onPick(t)
                            dismiss()
                        } label: {
                            TemplateCard(template: t, inUse: t.id == current)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("切换模板不会删除其他模板已生成或修改过的总结。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle("选择总结模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }
}
