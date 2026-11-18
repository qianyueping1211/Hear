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
