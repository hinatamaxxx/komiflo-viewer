import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// 表紙・バナーのサムネイルを保存して使い回す。
/// Komifloの画像URLは期限付きの署名（?exp=…&sig=…）が付いて毎回変わるので、
/// 署名を除いた「画像の場所」を目印にする。一度表示した画像は、次から読み込み表示なしで出る。
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    final class Thumbnail: NSObject, @unchecked Sendable {
        let image: UIImage
        let magazineLogos: [Int: UIImage]

        init(image: UIImage, data: Data, isMagazineLogo: Bool) {
            self.image = image
            magazineLogos = isMagazineLogo ? MagazineLogoRaster.images(data: data) : [:]
        }
    }

    private let memory = NSCache<NSString, Thumbnail>()
    private let disk: ImageDiskStore
    private let lock = NSLock()
    private var inFlight: [String: Task<Thumbnail?, Never>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        disk = ImageDiskStore(directory: caches.appendingPathComponent("Thumbnails", isDirectory: true), byteLimit: {
            Int64(Self.defaultDiskMB) * 1024 * 1024
        })
        memory.totalCostLimit = Self.defaultMemoryMB * 1024 * 1024
        memory.countLimit = 0
        // 端末内の保存分が上限を超えていたら、古いものから消す（起動を遅くしないよう裏で）
        Task.detached(priority: .background) { [self] in self.trimDisk() }
    }

    // MARK: - 上限（標準値で固定）

    /// メモリに置いておく画像の上限（MB）。一度出した表紙を、画面を行き来しても読み込み表示なしで出すため
    static let memoryLimitKey = "cache.memoryMB"
    /// 端末内に保存する画像の上限（MB）
    static let diskLimitKey = "cache.diskMB"
    static let defaultMemoryMB = 256
    static let defaultDiskMB = 512

    /// 端末内の保存分（バイト）
    func diskUsage() -> Int64 {
        disk.usage()
    }

    /// 端末内の保存分が上限を超えていたら、古く保存したものから消す
    func trimDisk() {
        disk.trim()
    }

    /// 保存した画像をすべて消す（メモリと端末内）
    func clearAll() {
        memory.removeAllObjects()
        disk.clear()
    }

    /// 署名などのクエリを除いた目印
    static func key(for url: URL) -> String {
        (url.host ?? "") + url.path
    }

    /// メモリにあればすぐ返す（画面を作るときに同期で使う）
    func memoryImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: Self.key(for: url) as NSString)?.image
    }

    /// メモリ → 端末内 → ダウンロード の順に探す
    func image(for url: URL) async -> UIImage? {
        await thumbnail(for: url)?.image
    }

    func memoryMagazineLogo(row: Int) -> UIImage? {
        memory.object(forKey: Self.key(for: MagazineLogoRaster.url) as NSString)?.magazineLogos[row]
    }

    func magazineLogo(row: Int) async -> UIImage? {
        await thumbnail(for: MagazineLogoRaster.url)?.magazineLogos[row]
    }

    /// 同じ取得で内容の目印も渡し、ヘッダーの判定結果を画像の更新に合わせる。
    func thumbnail(for url: URL) async -> Thumbnail? {
        let key = Self.key(for: url)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let task: Task<Thumbnail?, Never> = lock.withLock {
            if let running = inFlight[key] { return running }
            let name = Self.fileName(for: key)
            let fileURL = disk.fileURL(named: name)
            let isMagazineLogo = key == Self.key(for: MagazineLogoRaster.url)
            let newTask = Task.detached(priority: .userInitiated) { () -> Thumbnail? in
                if let data = try? Data(contentsOf: fileURL), let image = Self.decode(data) {
                    return Thumbnail(image: image, data: data, isMagazineLogo: isMagazineLogo)
                }
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = Self.decode(data) else {
                    return nil
                }
                self.disk.store(data, named: name)
                return Thumbnail(image: image, data: data, isMagazineLogo: isMagazineLogo)
            }
            inFlight[key] = newTask
            return newTask
        }

        let thumbnail = await task.value
        lock.withLock { inFlight[key] = nil }
        if let thumbnail {
            let cost = Self.cost(of: thumbnail.image) + thumbnail.magazineLogos.values.reduce(0) { $0 + Self.cost(of: $1) }
            memory.setObject(thumbnail, forKey: key as NSString, cost: cost)
        }
        return thumbnail
    }

    /// 展開した画像の大きさを、行ごとの実際のバイト数で数える。
    private static func cost(of image: UIImage) -> Int {
        if let bitmap = image.cgImage { return bitmap.bytesPerRow * bitmap.height }
        let scale = image.scale
        return Int(image.size.width * scale * image.size.height * scale * 4)
    }

    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 表示用に、画面に要る大きさまで縮めてから先にデコードしておく。
    /// 元の大きさのままだと、スクロール中に表示するたびに大きな画像を扱って引っかかる
    private static func decode(_ data: Data) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // 表紙・バナーは最大でも画面幅（3倍の解像度で約1200px）あれば足りる
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ] as CFDictionary
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) {
            return UIImage(cgImage: cgImage)
        }
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

/// 保存した画像を使う表示部品。メモリにある画像は、画面を作った瞬間から表示される
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var fitsHeight = false
    /// 縦に並んだ画像の指定した段だけを、表示枠の高さで切り出す。
    var spriteRow: Int?
    /// 画像を取れなかったとき（代わりの画像に切り替えたいときに使う）
    var onFailure: (() -> Void)? = nil
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadedKey: String?

    init(url: URL?, fitsHeight: Bool = false, spriteRow: Int? = nil, onFailure: (() -> Void)? = nil, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.fitsHeight = fitsHeight
        self.spriteRow = spriteRow
        self.onFailure = onFailure
        self.placeholder = placeholder
        let cached = ImageCache.shared.memoryImage(for: url)
        _image = State(initialValue: cached)
        _loadedKey = State(initialValue: cached == nil ? nil : url.map(ImageCache.key(for:)))
    }

    private var key: String? { url.map(ImageCache.key(for:)) }

    var body: some View {
        Group {
            // 部品の差し替えでも、準備済みの画像は取得タスクを待たずに表示する。
            if let image = loadedKey == key ? image : ImageCache.shared.memoryImage(for: url) {
                if let spriteRow {
                    GeometryReader { geometry in
                        // 全体の高さは画像から求める。段が増えても中央で切れないようにする。
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: geometry.size.width,
                                   height: geometry.size.width * image.size.height / max(1, image.size.width))
                            .offset(y: -CGFloat(spriteRow) * geometry.size.height)
                    }
                    .clipped()
                } else if fitsHeight {
                    GeometryReader { geometry in
                        // 高さだけを基準に拡大縮小し、中央を残して左右を切り取る。
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: geometry.size.height * image.size.width / max(1, image.size.height),
                                   height: geometry.size.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                    .clipped()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                placeholder()
            }
        }
        // 住所（期限の部分も含む）が変わったら読み直す。同じ画像がもう出ていれば読み直さない
        .task(id: url?.absoluteString) {
            guard let url, let key else {
                image = nil
                loadedKey = nil
                return
            }
            if loadedKey == key, image != nil { return }
            // 同じ部品が別の作品に使い回されたとき、メモリにあれば待たずに差し替える
            if let cached = ImageCache.shared.memoryImage(for: url) {
                image = cached
                loadedKey = key
                return
            }
            let loaded = await ImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            // アニメーションを付けると、スクロール中に読み込みが終わるたびに画面全体の動きが入ってかくつくので付けない
            image = loaded
            loadedKey = key
            if loaded == nil { onFailure?() }
        }
    }
}
