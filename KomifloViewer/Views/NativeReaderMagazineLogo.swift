import SwiftUI

/// 漫画の見えている左上へ、既存のロゴ表示を重ねる。画像の配置は変更しない。
struct NativeReaderMagazineLogo: View {
    @ObservedObject var imageGeometry: ReaderImageGeometry
    let identity: MagazineIdentity
    let available: CGRect
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = imageGeometry.frame.intersection(available)
        Group {
            if !frame.isNull, !frame.isEmpty {
                MagazineThumbnailLogo(identity: identity)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? nil : .linear(duration: 0.15), value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(!visible)
    }
}
