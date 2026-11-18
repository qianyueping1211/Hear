import Foundation
import llama

/// llama.cpp 的后端是全局的，整个 App 只有一个。
/// 翻译模型和声音克隆都共用它。
///
/// 注意：只能初始化，不能释放。llama_backend_free() 会把整个运行时关掉，
/// 而另一个模型可能还在用（App 运行期间一直需要）。
enum LlamaBackend {
    private static var ready = false

    /// 保证后端已初始化（可以重复调用）
    static func ensureReady() {
        guard !ready else { return }
        llama_backend_init()
        ready = true
    }
}
