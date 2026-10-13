import UIKit
import CoreML
import CryptoKit

/// 2つの小型モデルを一度だけ読み込み、サムネイル変更時に裏で人物と姿勢を調べる。
actor ThumbnailPersonDetector {
    static let shared = ThumbnailPersonDetector()
    private var preparation: Task<(person: MLModel, pose: MLModel), Error>?

    /// 未判定のヘッダーが必要になったとき、表示用の優先度で一度だけ準備する。
    func prepare() {
        guard preparation == nil else { return }
        preparation = Task.detached(priority: .userInitiated) { try Self.loadModels() }
    }

    func framing(in image: UIImage) async throws -> ThumbnailPersonComposition.Framing? {
        try Task.checkCancellation()
        guard let bitmap = image.cgImage else { return nil }
        prepare()
        guard let raster = Raster(bitmap) else { return nil }
        // モデルの読み込みを待つ間に、最初の入力を用意する。
        let input = try raster.personInput()
        guard let preparation else { return nil }
        let models = try await preparation.value
        try Task.checkCancellation()
        return try framing(in: raster, input: input, models: models)
    }

    // モデル待ちだけを非同期にし、従来の推論はこのactor内で順番に処理する。
    private func framing(in raster: Raster, input: MLMultiArray, models: (person: MLModel, pose: MLModel)) throws -> ThumbnailPersonComposition.Framing? {
        let output = try models.person.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
        guard let boxes = output.featureValue(for: "boxes")?.multiArrayValue,
              let scores = output.featureValue(for: "scores")?.multiArrayValue,
              boxes.shape.map(\.intValue) == [1, 3549, 4],
              scores.shape.map(\.intValue) == [1, 3549, 80] else { throw ModelError.output }
        let ratio = min(416 / CGFloat(raster.width), 416 / CGFloat(raster.height))
        let boxValues = Output(boxes), scoreValues = Output(scores)
        var candidates: [(CGRect, Double)] = []
        for i in 0..<3549 {
            let score = scoreValues.value(row: i, column: 0) // COCOのクラス0だけが人物。
            guard score >= 0.3 else { continue }
            let x = CGFloat(boxValues.value(row: i, column: 0)) / ratio
            let y = CGFloat(boxValues.value(row: i, column: 1)) / ratio
            let right = CGFloat(boxValues.value(row: i, column: 2)) / ratio
            let bottom = CGFloat(boxValues.value(row: i, column: 3)) / ratio
            guard x.isFinite, y.isFinite, right.isFinite, bottom.isFinite, right > x, bottom > y else { continue }
            candidates.append((CGRect(x: x, y: y, width: right - x, height: bottom - y), score))
        }
        let people = Self.suppress(candidates).map { ($0.0, $0.1) }
        var detected: [ThumbnailPersonComposition.Person] = []
        for (box, score) in people {
            try Task.checkCancellation()
            let crop = Self.poseCrop(box)
            let input = try raster.poseInput(crop)
            let prediction = try models.pose.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
            guard let xs = prediction.featureValue(for: "simcc_x")?.multiArrayValue,
                  let ys = prediction.featureValue(for: "simcc_y")?.multiArrayValue,
                  xs.shape.map(\.intValue) == [1, 17, 384], ys.shape.map(\.intValue) == [1, 17, 512] else {
                throw ModelError.output
            }
            let xValues = Output(xs), yValues = Output(ys)
            let joints = (0..<17).map { joint -> ThumbnailPersonComposition.Joint in
                let x = xValues.maximum(row: joint, length: 384)
                let y = yValues.maximum(row: joint, length: 512)
                return .init(point: CGPoint(x: crop.minX + CGFloat(x.0) / 384 * crop.width,
                                            y: crop.minY + CGFloat(y.0) / 512 * crop.height),
                             score: (x.1 + y.1) / 2)
            }
            detected.append(.init(bounds: box, score: score, joints: joints))
        }
        return ThumbnailPersonComposition.select(detected, image: CGSize(width: raster.width, height: raster.height))
    }

    private static func loadModels() throws -> (person: MLModel, pose: MLModel) {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThumbnailCompiledModels-v1", isDirectory: true)
        let cache = ThumbnailModelCache(directory: directory)
        func load(_ name: String) throws -> MLModel {
            guard let source = AppResources.bundle.url(forResource: name, withExtension: "mlmodel",
                                                      subdirectory: "ThumbnailModels") else {
                throw ModelError.missing
            }
            // モデルの内容とOSが変わった場合は、別の変換結果として扱う。
            var signature = Data(ProcessInfo.processInfo.operatingSystemVersionString.utf8)
            signature.append(try Data(contentsOf: source))
            let version = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
            return try cache.load(name: name, version: version,
                                  compile: { try MLModel.compileModel(at: source) },
                                  open: { try MLModel(contentsOf: $0) })
        }
        return (person: try load("ThumbnailPersonNano"), pose: try load("ThumbnailPoseTiny"))
    }

    // 出力の型と間隔は一度だけ読み、各数値で配列やNSNumberを作り直さない。
    private struct Output {
        let array: MLMultiArray
        let rowStride: Int
        let columnStride: Int
        let floats: UnsafePointer<Float>?
        let halves: UnsafePointer<Float16>?

        init(_ array: MLMultiArray) {
            self.array = array
            rowStride = array.strides[1].intValue
            columnStride = array.strides[2].intValue
            floats = array.dataType == .float32 ? UnsafePointer(array.dataPointer.assumingMemoryBound(to: Float.self)) : nil
            halves = array.dataType == .float16 ? UnsafePointer(array.dataPointer.assumingMemoryBound(to: Float16.self)) : nil
        }

        func value(row: Int, column: Int) -> Double {
            withExtendedLifetime(array) {
                let offset = row * rowStride + column * columnStride
                if let floats { return Double(floats[offset]) }
                if let halves { return Double(halves[offset]) }
                return array[[0, NSNumber(value: row), NSNumber(value: column)]].doubleValue
            }
        }

        func maximum(row: Int, length: Int) -> (Int, Double) {
            var result = (0, -Double.infinity)
            for i in 0..<length {
                let score = value(row: row, column: i)
                if score > result.1 { result = (i, score) }
            }
            return result
        }
    }

    private static func suppress(_ candidates: [(CGRect, Double)]) -> [(CGRect, Double)] {
        var kept: [(CGRect, Double)] = []
        for candidate in candidates.sorted(by: { $0.1 > $1.1 }) {
            let duplicate = kept.contains { other in
                let intersection = candidate.0.intersection(other.0)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                let union = candidate.0.width * candidate.0.height + other.0.width * other.0.height - area
                return union > 0 && area / union > 0.65
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }

    private static func poseCrop(_ box: CGRect) -> CGRect {
        let width = max(box.width * 1.25, box.height * 1.25 * 192 / 256)
        let height = width * 256 / 192
        return CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    private enum ModelError: LocalizedError {
        case missing, output
        var errorDescription: String? { "ヘッダー用の人物モデルを読み込めませんでした。" }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        init?(_ bitmap: CGImage) {
            let width = bitmap.width
            let height = bitmap.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                                | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            rgba = pixels
        }

        func personInput() throws -> MLMultiArray {
            let result = try MLMultiArray(shape: [1, 3, 416, 416], dataType: .float32)
            let data = result.dataPointer.assumingMemoryBound(to: Float.self)
            data.initialize(repeating: 114, count: 3 * 416 * 416)
            let ratio = min(416 / Double(width), 416 / Double(height))
            let w = max(1, Int(Double(width) * ratio)), h = max(1, Int(Double(height) * ratio))
            for y in 0..<h {
                let sy = max(0, min(Double(height - 1), (Double(y) + 0.5) * Double(height) / Double(h) - 0.5))
                for x in 0..<w {
                    let sx = max(0, min(Double(width - 1), (Double(x) + 0.5) * Double(width) / Double(w) - 0.5))
                    let rgb = sample(sx, sy), offset = y * 416 + x
                    data[offset] = rgb.2.rounded()
                    data[416 * 416 + offset] = rgb.1.rounded()
                    data[2 * 416 * 416 + offset] = rgb.0.rounded()
                }
            }
            return result
        }

        func poseInput(_ crop: CGRect) throws -> MLMultiArray {
            let result = try MLMultiArray(shape: [1, 3, 256, 192], dataType: .float32)
            let data = result.dataPointer.assumingMemoryBound(to: Float.self)
            for y in 0..<256 {
                let sy = Double(crop.minY) + Double(y) / 256 * Double(crop.height)
                for x in 0..<192 {
                    let sx = Double(crop.minX) + Double(x) / 192 * Double(crop.width)
                    let rgb = sample(sx, sy), offset = y * 192 + x
                    data[offset] = (rgb.0.rounded() - 123.675) / 58.395
                    data[256 * 192 + offset] = (rgb.1.rounded() - 116.28) / 57.12
                    data[2 * 256 * 192 + offset] = (rgb.2.rounded() - 103.53) / 57.375
                }
            }
            return result
        }

        private func sample(_ x: Double, _ y: Double) -> (Float, Float, Float) {
            let left = Int(floor(x)), top = Int(floor(y)), dx = Float(x - floor(x)), dy = Float(y - floor(y))
            func offset(_ x: Int, _ y: Int) -> Int {
                guard x >= 0, y >= 0, x < width, y < height else { return -1 }
                return (y * width + x) * 4
            }
            let a = offset(left, top), b = offset(left + 1, top)
            let c = offset(left, top + 1), d = offset(left + 1, top + 1)
            func channel(_ channel: Int) -> Float {
                let p = a < 0 ? 0 : Float(rgba[a + channel])
                let q = b < 0 ? 0 : Float(rgba[b + channel])
                let r = c < 0 ? 0 : Float(rgba[c + channel])
                let s = d < 0 ? 0 : Float(rgba[d + channel])
                return (p * (1 - dx) + q * dx) * (1 - dy) + (r * (1 - dx) + s * dx) * dy
            }
            return (channel(0), channel(1), channel(2))
        }
    }
}
