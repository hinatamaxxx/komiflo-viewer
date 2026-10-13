import UIKit

/// 配信された配置の画像を、UIKitのメモリ内だけで描く。書き出し口とキャッシュは持たない。
enum NativePageRenderer {
    static func render(_ source: UIImage, page: NativeReaderDocument.Page) throws -> UIImage {
        guard let original = source.cgImage else { throw NativeReaderError.invalidImage }
        // 不透明な配信画像は一度だけ展開し、タイルごとの画像生成・色変換・描画を省く。
        if page.layout != nil, [.none, .noneSkipFirst, .noneSkipLast].contains(original.alphaInfo) {
            return try renderPixels(source, page: page)
        }
        return try renderUsingImageTiles(source, page: page)
    }

    static func renderUsingImageTiles(_ source: UIImage, page: NativeReaderDocument.Page) throws -> UIImage {
        guard let original = source.cgImage, source.imageOrientation == .up else { throw NativeReaderError.invalidImage }
        let width = page.layout?.width ?? original.width
        let height = page.layout?.height ?? original.height
        if let layout = page.layout {
            guard original.width == layout.sourceWidth, original.height == layout.sourceHeight else { throw NativeReaderError.invalidImage }
        }
        if page.layout == nil, page.watermark == nil { return source }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        var missingTile = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            context.cgContext.interpolationQuality = .none
            if let layout = page.layout {
                for tile in layout.tiles() {
                    let size = NativePageLayout.tileSize
                    let rect = CGRect(x: tile.sourceX, y: tile.sourceY, width: size, height: size)
                    guard let cropped = original.cropping(to: rect) else { missingTile = true; continue }
                    UIImage(cgImage: cropped).draw(in: CGRect(x: tile.destinationX, y: tile.destinationY, width: size, height: size))
                }
            } else { source.draw(in: CGRect(x: 0, y: 0, width: width, height: height)) }
            if let watermark = page.watermark { draw(watermark, width: width, height: height) }
        }
        guard !missingTile else { throw NativeReaderError.invalidImage }
        return image
    }

    private static func renderPixels(_ source: UIImage, page: NativeReaderDocument.Page) throws -> UIImage {
        guard let original = source.cgImage, source.imageOrientation == .up, let layout = page.layout,
              original.width == layout.sourceWidth, original.height == layout.sourceHeight else {
            throw NativeReaderError.invalidImage
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let decoded = CGContext(data: nil, width: original.width, height: original.height,
                                      bitsPerComponent: 8, bytesPerRow: original.width * 4, space: space, bitmapInfo: info),
              let output = CGContext(data: nil, width: layout.width, height: layout.height,
                                     bitsPerComponent: 8, bytesPerRow: layout.width * 4, space: space, bitmapInfo: info),
              let inputBytes = decoded.data, let outputBytes = output.data else { throw NativeReaderError.invalidImage }
        decoded.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        for tile in layout.tiles() {
            try Task.checkCancellation()
            let left = max(0, tile.destinationX)
            let top = max(0, tile.destinationY)
            let right = min(layout.width, tile.destinationX + NativePageLayout.tileSize)
            let bottom = min(layout.height, tile.destinationY + NativePageLayout.tileSize)
            guard right > left, bottom > top else { continue }
            let sourceX = tile.sourceX + left - tile.destinationX
            let sourceY = tile.sourceY + top - tile.destinationY
            for row in 0..<(bottom - top) {
                memcpy(outputBytes.advanced(by: (top + row) * output.bytesPerRow + left * 4),
                       inputBytes.advanced(by: (sourceY + row) * decoded.bytesPerRow + sourceX * 4), (right - left) * 4)
            }
        }
        if let watermark = page.watermark {
            // UIKitの文字描画にだけ上向きの座標を渡す。指定の位置と濃さは従来どおり。
            output.saveGState()
            output.translateBy(x: 0, y: CGFloat(layout.height))
            output.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(output)
            draw(watermark, width: layout.width, height: layout.height)
            UIGraphicsPopContext()
            output.restoreGState()
        }
        guard let image = output.makeImage() else { throw NativeReaderError.invalidImage }
        return UIImage(cgImage: image)
    }

    private static func draw(_ watermark: NativeReaderDocument.Watermark, width: Int, height: Int) {
        // 公式と同じ識別子・色・濃さを維持し、画像の四隅の指定位置に描く。
        let scale = min(CGFloat(width) / 1360, CGFloat(height) / 1920)
        let font = UIFont.systemFont(ofSize: max(1, 10 * scale))
        let color = (watermark.black ? UIColor.black : UIColor.white).withAlphaComponent(watermark.opacity)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = watermark.text as NSString
        let size = text.size(withAttributes: attributes)
        let inset = max(1, 5 * scale)
        let right = watermark.position.hasSuffix("r")
        let top = watermark.position.hasPrefix("t")
        let point = CGPoint(x: right ? CGFloat(width) - inset - size.width : inset,
                            y: top ? inset : CGFloat(height) - inset - size.height)
        text.draw(at: point, withAttributes: attributes)
    }
}
