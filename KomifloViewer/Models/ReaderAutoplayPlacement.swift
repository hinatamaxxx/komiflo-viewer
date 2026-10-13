import Foundation
import CoreGraphics

/// 画像を動かさず、その下端から表示位置を決める。余白が足りない時だけ画面内へ収める。
enum ReaderAutoplayPlacement {
    static func frame(image: CGRect, available: CGRect, size: CGSize, aboveHeight: CGFloat = 0) -> CGRect {
        guard available.width > 0, available.height > 0, size.width > 0, size.height > 0 else { return .null }
        let width = min(size.width, available.width)
        let height = min(size.height, available.height)
        let lastTop = available.maxY - height
        let desiredTop = image.isNull || !image.maxY.isFinite ? lastTop : image.maxY + 8 - max(0, aboveHeight)
        return CGRect(x: available.midX - width / 2,
                      y: min(lastTop, max(available.minY, desiredTop)), width: width, height: height)
    }
}
