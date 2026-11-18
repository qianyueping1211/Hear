import SwiftUI

/// 屏幕正中的确认框：宽度为页面的 70%，大圆角卡片，背后的内容虚化变暗，下方「取消」「确认」两个按钮。
/// 点卡片以外的地方等于取消。
struct CenterDialog: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    var confirmTitle = "确认"
    var destructive = false
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content
            .blur(radius: isPresented ? 14 : 0)
            .allowsHitTesting(!isPresented)
            .overlay {
                if isPresented {
                    GeometryReader { geo in
                        ZStack {
                            Color.black.opacity(0.35)
                                .contentShape(Rectangle())
                                .onTapGesture { isPresented = false }
                            card
                                .frame(width: geo.size.width * 0.7)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.3), value: isPresented)
    }

    private var card: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    isPresented = false
                } label: {
                    Text("取消")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                }
                Button {
                    onConfirm()
                    isPresented = false
                } label: {
                    Text(confirmTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(destructive ? Color.red : Color.accentColor, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }
}

extension View {
    /// 屏幕正中的确认框（取消 / 确认）
    func centerDialog(isPresented: Binding<Bool>, title: String, message: String,
                      confirmTitle: String = "确认", destructive: Bool = false,
                      onConfirm: @escaping () -> Void) -> some View {
        modifier(CenterDialog(isPresented: isPresented, title: title, message: message,
                              confirmTitle: confirmTitle, destructive: destructive, onConfirm: onConfirm))
    }
}

/// 屏幕正中的选项列表：背后整页虚化变暗，聚焦在选项上；选项一行显示不换行。点卡片以外的地方关闭。
struct CenterChoice: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let options: [(tag: String, title: String, detail: String)]
    let selected: String
    let onSelect: (String) -> Void

    func body(content: Content) -> some View {
        content
            .blur(radius: isPresented ? 14 : 0)
            .allowsHitTesting(!isPresented)
            .overlay {
                if isPresented {
                    GeometryReader { geo in
                        ZStack {
                            Color.black.opacity(0.35)
                                .contentShape(Rectangle())
                                .onTapGesture { isPresented = false }
                            card
                                .frame(width: min(geo.size.width * 0.88, 440))
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.3), value: isPresented)
    }

    private var card: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 6)
            ForEach(options, id: \.tag) { o in
                Button {
                    onSelect(o.tag)
                    isPresented = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .opacity(o.tag == selected ? 1 : 0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.title)
                                .font(.body.weight(o.tag == selected ? .semibold : .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if !o.detail.isEmpty {
                                Text(o.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(o.tag == selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }
}

extension View {
    /// 屏幕正中的选项列表（单选）
    func centerChoice(isPresented: Binding<Bool>, title: String,
                      options: [(tag: String, title: String, detail: String)],
                      selected: String, onSelect: @escaping (String) -> Void) -> some View {
        modifier(CenterChoice(isPresented: isPresented, title: title, options: options,
                              selected: selected, onSelect: onSelect))
    }
}
