import SwiftUI

/// 標準スライドを使わず、中央から開き、逆の動きで閉じる。
struct ReaderEntrance<Content: View>: View {
    let enabled: Bool
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var closing = false

    var body: some View {
        content()
            .environment(\.closeReader) { completion in close(completion: completion) }
            .allowsHitTesting(!closing)
            .scaleEffect(appeared || !enabled || reduceMotion ? 1 : 0.94)
            .opacity(appeared || !enabled || reduceMotion ? 1 : 0)
            .onAppear {
                withAnimation(enabled && !reduceMotion ? .easeOut(duration: 0.22) : nil) { appeared = true }
            }
    }

    private func close(completion: @escaping () -> Void) {
        guard !closing else { return }
        closing = true
        let finish = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                completion()
                onClose()
            }
        }
        guard enabled, !reduceMotion else { finish(); return }
        withAnimation(.easeOut(duration: 0.14), completionCriteria: .logicallyComplete) {
            appeared = false
        } completion: {
            finish()
        }
    }
}

private struct CloseReaderKey: EnvironmentKey {
    static let defaultValue: (@escaping () -> Void) -> Void = { $0() }
}

extension EnvironmentValues {
    /// 終了演出が終わってから画像の破棄と全画面表示の解除を行う。
    var closeReader: (@escaping () -> Void) -> Void {
        get { self[CloseReaderKey.self] }
        set { self[CloseReaderKey.self] = newValue }
    }
}
