import Foundation

/// nagadomiのLBPモデルを端末内で評価する。OpenCVの分類・矩形統合をSwiftへ移植。
/// 利用条件はResourcesのAnimeFaceLicense・OpenCVLicenseに収録する。
struct AnimeFaceCascade: Decodable {
    struct Weak: Decodable {
        let feature: Int
        let subset: [UInt32]
        let leaves: [Float]
    }
    struct Stage: Decodable {
        let threshold: Float
        let weak: [Weak]
    }
    let window: Int
    let features: [[Int]]
    let stages: [Stage]

    struct Detection {
        let rect: CGRect
        let neighbors: Int
    }

    /// 入力は左上原点の濃淡画像。大きな画像は呼び出し元で縮小しておく。
    func detect(gray: [UInt8], width: Int, height: Int, scaleFactor: Double = 1.1) -> [CGRect] {
        detections(gray: gray, width: width, height: height, scaleFactor: scaleFactor)
            .map(\.rect).sorted { $0.width * $0.height > $1.width * $1.height }
    }

    func detections(gray: [UInt8], width: Int, height: Int, scaleFactor: Double = 1.1) -> [Detection] {
        guard width >= window, height >= window, gray.count == width * height,
              scaleFactor.isFinite, scaleFactor > 1 else { return [] }
        let equalized = Self.equalize(gray)
        var candidates: [CGRect] = []
        var scale = 1.0
        while Int((Double(window) * scale).rounded(.toNearestOrEven)) <= min(width, height) {
            if Task.isCancelled { return [] }
            // OpenCVは探索倍率をFloatで保持する。同じ倍率と丸めで評価する。
            let evaluatedScale = Double(Float(scale))
            let scaledWidth = Int((Double(width) / evaluatedScale).rounded(.toNearestOrEven))
            let scaledHeight = Int((Double(height) / evaluatedScale).rounded(.toNearestOrEven))
            let pixels = Self.resize(equalized, width: width, height: height,
                                     toWidth: scaledWidth, toHeight: scaledHeight)
            let stride = scaledWidth + 1
            let integral = Self.integral(pixels, width: scaledWidth, height: scaledHeight)
            // 各特徴の16個の隅を、画像の縮小段階ごとに準備する。
            let offsets = features.map { feature in
                (0..<4).flatMap { row in
                    (0..<4).map { col in
                        (feature[1] + row * feature[3]) * stride + feature[0] + col * feature[2]
                    }
                }
            }
            let step = evaluatedScale >= 2 ? 1 : 2
            let size = Int((Double(window) * evaluatedScale).rounded(.toNearestOrEven))
            for y in Swift.stride(from: 0, through: scaledHeight - window, by: step) {
                var x = 0
                while x <= scaledWidth - window {
                    let result = classify(integral: integral, offset: y * stride + x, features: offsets)
                    if result == stages.count {
                        candidates.append(CGRect(x: (Double(x) * evaluatedScale).rounded(.toNearestOrEven),
                                                 y: (Double(y) * evaluatedScale).rounded(.toNearestOrEven),
                                                 width: Double(size), height: Double(size)))
                    }
                    x += result == 0 ? step * 2 : step
                }
            }
            scale *= scaleFactor
        }
        return Self.groupedDetections(candidates)
    }

    /// 同じ位置を支持した探索の数で選ぶ。未検出の場合だけ、小さな傾きも調べる。
    func focus(gray: [UInt8], width: Int, height: Int) -> CGRect? {
        if let first = detections(gray: gray, width: width, height: height, scaleFactor: 1.05).first {
            return first.rect
        }
        var best: Detection?
        for angle in [-15.0, -5.0, 5.0, 15.0] {
            guard !Task.isCancelled else { return nil }
            let rotated = Self.rotated(gray, width: width, height: height, degrees: angle)
            for face in detections(gray: rotated, width: width, height: height, scaleFactor: 1.05) {
                if best.map({ face.neighbors > $0.neighbors }) ?? true {
                    best = Detection(rect: Self.originalRect(face.rect, width: width, height: height, degrees: angle),
                                     neighbors: face.neighbors)
                }
            }
        }
        return best?.rect
    }

    /// 白い余白で回転し、検出後の座標は元のサムネイルへ戻す。
    static func rotated(_ gray: [UInt8], width: Int, height: Int, degrees: Double) -> [UInt8] {
        guard width > 0, height > 0, gray.count == width * height else { return [] }
        let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
        let cx = Double(width) / 2, cy = Double(height) / 2
        func pixel(_ x: Int, _ y: Int) -> Double {
            x >= 0 && x < width && y >= 0 && y < height ? Double(gray[y * width + x]) : 255
        }
        return (0..<height).flatMap { y in
            (0..<width).map { x in
                let sx = c * (Double(x) - cx) - s * (Double(y) - cy) + cx
                let sy = s * (Double(x) - cx) + c * (Double(y) - cy) + cy
                let x0 = Int(floor(sx)), y0 = Int(floor(sy)), fx = sx - floor(sx), fy = sy - floor(sy)
                let a = pixel(x0, y0) * (1 - fx) + pixel(x0 + 1, y0) * fx
                let b = pixel(x0, y0 + 1) * (1 - fx) + pixel(x0 + 1, y0 + 1) * fx
                return UInt8(min(255, max(0, (a * (1 - fy) + b * fy).rounded())))
            }
        }
    }

    static func originalRect(_ rect: CGRect, width: Int, height: Int, degrees: Double) -> CGRect {
        let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
        let cx = Double(width) / 2, cy = Double(height) / 2
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map { point in
            CGPoint(x: c * (point.x - cx) - s * (point.y - cy) + cx,
                    y: s * (point.x - cx) + c * (point.y - cy) + cy)
        }
        let x = points.map(\.x), y = points.map(\.y)
        return CGRect(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
    }

    /// 全段階を通ったときだけ顔とする。最初の段階で落ちた場所は探索を一つ飛ばす。
    func classify(integral: [Int], offset: Int, features: [[Int]]) -> Int {
        for (index, stage) in stages.enumerated() {
            var sum = 0.0
            for weak in stage.weak {
                let code = Self.code(integral: integral, offset: offset, corners: features[weak.feature])
                let left = weak.subset[code >> 5] & (UInt32(1) << (code & 31)) != 0
                sum += Double(weak.leaves[left ? 0 : 1])
            }
            if sum < Double(stage.threshold - 0.00001) { return index }
        }
        return stages.count
    }

    static func code(integral: [Int], offset: Int, corners: [Int]) -> Int {
        func cell(_ i: Int) -> Int {
            integral[offset + corners[i]] - integral[offset + corners[i + 1]]
                - integral[offset + corners[i + 4]] + integral[offset + corners[i + 5]]
        }
        let center = cell(5)
        var code = 0
        for (bit, corner) in [0, 1, 2, 6, 10, 9, 8, 4].enumerated() {
            if cell(corner) >= center { code |= 128 >> bit }
        }
        return code
    }

    static func integral(_ pixels: [UInt8], width: Int, height: Int) -> [Int] {
        let stride = width + 1
        var output = [Int](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row = 0
            for x in 0..<width {
                row += Int(pixels[y * width + x])
                output[(y + 1) * stride + x + 1] = output[y * stride + x + 1] + row
            }
        }
        return output
    }

    /// モデルの公開例と同じRGB→濃淡変換。入力は白背景に描いたRGBA。
    static func grayscale(rgba: [UInt8]) -> [UInt8] {
        guard rgba.count.isMultiple(of: 4) else { return [] }
        return Swift.stride(from: 0, to: rgba.count, by: 4).map { i in
            UInt8((Int(rgba[i]) * 9798 + Int(rgba[i + 1]) * 19235
                + Int(rgba[i + 2]) * 3735 + 16384) >> 15)
        }
    }

    static func equalize(_ pixels: [UInt8]) -> [UInt8] {
        guard !pixels.isEmpty else { return [] }
        var histogram = [Int](repeating: 0, count: 256)
        for pixel in pixels { histogram[Int(pixel)] += 1 }
        let first = histogram.firstIndex { $0 > 0 }!
        guard histogram[first] != pixels.count else { return pixels }
        let scale = Float(255) / Float(pixels.count - histogram[first])
        var accumulated = 0
        var table = [UInt8](repeating: 0, count: 256)
        for value in (first + 1)..<256 {
            accumulated += histogram[value]
            table[value] = UInt8(min(255, (Float(accumulated) * scale).rounded(.toNearestOrEven)))
        }
        return pixels.map { table[Int($0)] }
    }

    static func resize(_ pixels: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        if width == toWidth && height == toHeight { return pixels }
        var output = [UInt8](repeating: 0, count: toWidth * toHeight)
        for y in 0..<toHeight {
            let sourceY = max(0, min(Double(height - 1), (Double(y) + 0.5) * Double(height) / Double(toHeight) - 0.5))
            let y0 = Int(sourceY), y1 = min(height - 1, y0 + 1)
            // INTER_LINEAR_EXACTと同じ8ビット固定小数で補間する。
            let fy = Int(((sourceY - Double(y0)) * 256).rounded(.toNearestOrEven))
            for x in 0..<toWidth {
                let sourceX = max(0, min(Double(width - 1), (Double(x) + 0.5) * Double(width) / Double(toWidth) - 0.5))
                let x0 = Int(sourceX), x1 = min(width - 1, x0 + 1)
                let fx = Int(((sourceX - Double(x0)) * 256).rounded(.toNearestOrEven))
                let top = Int(pixels[y0 * width + x0]) * (256 - fx) + Int(pixels[y0 * width + x1]) * fx
                let bottom = Int(pixels[y1 * width + x0]) * (256 - fx) + Int(pixels[y1 * width + x1]) * fx
                output[y * toWidth + x] = UInt8(((256 - fy) * top + fy * bottom + 32768) >> 16)
            }
        }
        return output
    }

    /// 近い位置・大きさの検出を統合し、孤立した誤検出を外す。
    static func group(_ rectangles: [CGRect], minimumNeighbors: Int = 5) -> [CGRect] {
        groupedDetections(rectangles, minimumNeighbors: minimumNeighbors)
            .map(\.rect).sorted { $0.width * $0.height > $1.width * $1.height }
    }

    static func groupedDetections(_ rectangles: [CGRect], minimumNeighbors: Int = 5) -> [Detection] {
        guard !rectangles.isEmpty else { return [] }
        var roots = Array(rectangles.indices)
        func root(_ i: Int) -> Int {
            var j = i
            while roots[j] != j { j = roots[j] }
            return j
        }
        for i in rectangles.indices {
            for j in rectangles.indices where j < i {
                let a = rectangles[i], b = rectangles[j]
                let delta = 0.2 * (min(a.width, b.width) + min(a.height, b.height)) * 0.5
                if abs(a.minX - b.minX) <= delta && abs(a.minY - b.minY) <= delta
                    && abs(a.maxX - b.maxX) <= delta && abs(a.maxY - b.maxY) <= delta {
                    roots[root(i)] = root(j)
                }
            }
        }
        var groups: [Int: [CGRect]] = [:]
        for i in rectangles.indices { groups[root(i), default: []].append(rectangles[i]) }
        let averaged = groups.values.map { items -> (CGRect, Int) in
            let count = CGFloat(items.count)
            return (CGRect(x: (items.reduce(0) { $0 + $1.minX } / count).rounded(.toNearestOrEven),
                           y: (items.reduce(0) { $0 + $1.minY } / count).rounded(.toNearestOrEven),
                           width: (items.reduce(0) { $0 + $1.width } / count).rounded(.toNearestOrEven),
                           height: (items.reduce(0) { $0 + $1.height } / count).rounded(.toNearestOrEven)), items.count)
        }.filter { $0.1 > minimumNeighbors }
        return averaged.filter { a in
            !averaged.contains { b in
                a.0 != b.0 && b.1 > max(3, a.1)
                    && b.0.insetBy(dx: -(b.0.width * 0.2).rounded(.toNearestOrEven),
                                  dy: -(b.0.height * 0.2).rounded(.toNearestOrEven)).contains(a.0)
            }
        }.map { Detection(rect: $0.0, neighbors: $0.1) }.sorted {
            if $0.neighbors != $1.neighbors { return $0.neighbors > $1.neighbors }
            if $0.rect.width != $1.rect.width { return $0.rect.width > $1.rect.width }
            if $0.rect.minY != $1.rect.minY { return $0.rect.minY < $1.rect.minY }
            return $0.rect.minX < $1.rect.minX
        }
    }
}
