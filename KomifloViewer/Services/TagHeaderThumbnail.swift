import UIKit

/// Web一覧の先頭作品を使い、人物の上半身・顔から表示の中心を決める。
enum TagHeaderThumbnail {
    struct Selection {
        let url: URL
        let focus: CGRect?
        let protectedHead: CGRect?
    }

    private static let detector: AnimeFaceCascade? = {
        guard let url = AppResources.bundle.url(forResource: "AnimeFaceCascade", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AnimeFaceCascade.self, from: data)
    }()

    static let preparation = HeaderPreparationQueue { url in
        _ = try? await select(url: url, preparing: true)
    }

    static func select(url: URL?, preparing: Bool = false) async throws -> Selection? {
        guard let url, !Task.isCancelled else { return nil }
        if !preparing { await preparation.beginDisplay() }
        defer { if !preparing { Task { await preparation.endDisplay() } } }
        guard let thumbnail = await ImageCache.shared.thumbnail(for: url) else { return nil }
        let framing = try await HeaderFramingCache.shared.framing(fingerprint: thumbnail.fingerprint) {
            try await detect(in: thumbnail.image)
        }
        guard !Task.isCancelled else { return nil }
        return Selection(url: url, focus: framing.focus, protectedHead: framing.protectedHead)
    }

    private static func detect(in image: UIImage) async throws -> HeaderFramingCache.Framing {
        if let framing = try await ThumbnailPersonDetector.shared.framing(in: image) {
            try Task.checkCancellation()
            return .init(focus: framing.focus, protectedHead: framing.protectedHead)
        }
        // 上半身を確認できない画像だけ、既存の顔検出を使う。
        let selected = await Task.detached(priority: .userInitiated) { () -> HeaderFramingCache.Framing in
            let face = focusRegion(in: image)
            return .init(focus: face, protectedHead: face)
        }.value
        try Task.checkCancellation()
        return selected
    }

    private static func focusRegion(in image: UIImage) -> CGRect? {
        guard let bitmap = image.cgImage, let detector,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // 元のサムネイルを共用し、検出用の濃淡画像だけをメモリ内に作る。
        let scale = min(1, 512 / Double(max(bitmap.width, bitmap.height)))
        let width = max(1, Int((Double(bitmap.width) * scale).rounded()))
        let height = max(1, Int((Double(bitmap.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let pixels = AnimeFaceCascade.grayscale(rgba: rgba)
        // 大きさだけで選ばず、探索の支持数と、未検出時の傾きを考慮する。
        guard let face = detector.focus(gray: pixels, width: width, height: height) else { return nil }
        // モデルは左上原点。髪・輪郭の余裕を加え、同じ原点の切り抜き処理へ渡す。
        let box = CGRect(x: face.minX / CGFloat(width), y: face.minY / CGFloat(height),
                         width: face.width / CGFloat(width), height: face.height / CGFloat(height))
        return box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.25)
    }
}

/// 顔の位置を中心に、画像の外へ出ない範囲を切り抜く。座標は左上原点の0〜1。
enum HeaderThumbnailCrop {
    static func rect(image: CGSize, viewport: CGSize, focus: CGRect, protectedHead: CGRect? = nil) -> CGRect {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let scale = max(viewport.width / image.width, viewport.height / image.height)
        let width = min(1, viewport.width / (image.width * scale))
        let height = min(1, viewport.height / (image.height * scale))
        let region = focus.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let center = region.isNull ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: region.midX, y: region.midY)
        let protected = protectedHead?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        func origin(center: CGFloat, length: CGFloat, lower: CGFloat?, upper: CGFloat?, topFirst: Bool) -> CGFloat {
            var value = center - length / 2
            if let lower, let upper, lower.isFinite, upper.isFinite {
                if upper - lower <= length {
                    value = min(max(value, upper - length), lower)
                } else {
                    value = topFirst ? lower : (lower + upper - length) / 2
                }
            }
            return min(max(0, value), 1 - length)
        }
        let anchor = protected.flatMap { $0.isNull ? nil : $0 }
        return CGRect(x: origin(center: center.x, length: width, lower: anchor?.minX, upper: anchor?.maxX, topFirst: false),
                      y: origin(center: center.y, length: height, lower: anchor?.minY, upper: anchor?.maxY, topFirst: true),
                      width: width, height: height)
    }
}
