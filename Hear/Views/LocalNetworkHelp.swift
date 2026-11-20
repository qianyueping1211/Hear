import SwiftUI
import UIKit

/// 「本地网络权限」的提示弹窗。
///
/// 系统的授权框只问一次：用户选了「不允许」以后，App 再也弹不出来，
/// 只能自己去 设置 → 隐私与安全性 → 本地网络 → 听见 里打开。
/// 大部分人不知道这个开关在哪儿，所以这里把步骤写清楚，还能一键跳到设置。
struct LocalNetworkHelpModifier: ViewModifier {
    @Binding var shown: Bool

    func body(content: Content) -> some View {
        content.alert("需要「本地网络」权限", isPresented: $shown) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text("""
            要用电脑上的云端模型，手机得允许访问本地网络。

            打开方法：设置 → 隐私与安全性 → 本地网络 → 听见 → 打开

            系统的授权框只问一次，选了「不允许」就只能自己去设置里打开。
            """)
        }
    }
}

extension View {
    /// 本地网络权限没开时弹的提示
    func localNetworkHelp(_ shown: Binding<Bool>) -> some View {
        modifier(LocalNetworkHelpModifier(shown: shown))
    }
}
