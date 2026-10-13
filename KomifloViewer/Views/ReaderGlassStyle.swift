import SwiftUI

/// 実験用の見た目をここへ閉じ込め、無効時は従来の背景を使う。
struct ReaderGlassStyle: ViewModifier {
    static let key = "reader.experimentalGlassButtons"
    let enabled: Bool
    var originalFill: Color? = nil
    var adaptiveControl = false
    var adaptiveTint: Color? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), enabled, !reduceTransparency {
            if adaptiveControl {
                content.foregroundStyle(adaptiveTint ?? .primary)
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                content.glassEffect(.regular, in: Capsule())
            }
        } else {
            content.background(Capsule().fill(originalFill ?? (enabled ? Color.black : Color.clear)))
        }
    }
}

/// 画像の位置がナビの背後を通った時だけ色を変え、漫画側の表示状態は更新しない。
final class ReaderHeaderAppearance: ObservableObject {
    @Published private(set) var isOverComic = false
    private var requestedCoverage = false

    func update(isOverComic: Bool) {
        guard requestedCoverage != isOverComic else { return }
        requestedCoverage = isOverComic
        // UIKitの配置中にSwiftUIへ変更を通知せず、最後の判定だけを反映する。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedCoverage == isOverComic, self.isOverComic != isOverComic else { return }
            self.isOverComic = isOverComic
        }
    }
}
