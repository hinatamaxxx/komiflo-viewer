import ImageIO
import UIKit

enum MagazineLogoRaster {
    static let url = URL(string: "https://komiflo.com/assets/img/magazines/magazine_logos@3x.png??v=u7f391f8d")!

    /// 公式ロゴ画像の取得時だけ実行し、切り出した結果を画像キャッシュで共用する。
    static func images(data: Data) -> [Int: UIImage] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [:] }
        let width = bitmap.width, height = bitmap.height
        let count = Int((Double(height) / Double(width) * 1125 / 384).rounded())
        guard count > 0 else { return [:] }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        return rgba.withUnsafeMutableBufferPointer { pixels in
            guard let context = CGContext(data: pixels.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return [:] }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let raster = context.makeImage() else { return [:] }
            let bounds = MagazineLogoBounds.rows(rgba: UnsafeBufferPointer(pixels), width: width,
                                                 height: height, count: count)
            return bounds.reduce(into: [:]) { result, entry in
                guard let crop = raster.cropping(to: entry.value) else { return }
                let image = UIImage(cgImage: crop)
                result[entry.key] = image.preparingForDisplay() ?? image
            }
        }
    }
}
