import Foundation

/// 高画質／低画質は公式と同じ配信画像を使い、自動は読み込み時間から選ぶ。
enum ReaderImageQuality: String, CaseIterable, Identifiable {
    case high, low, automatic

    static let key = "reader.native.imageQuality"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .high: return "高画質（高速ネットワーク時推奨）"
        case .low: return "低画質（低速ネットワーク時推奨）"
        case .automatic: return "自動（画像の読み込み時間で選択）"
        }
    }

    func source(for page: NativeReaderDocument.Page) throws -> NativeReaderDocument.Page {
        guard self != .automatic else { throw NativeReaderError.invalidImage }
        guard self == .low else { return page }
        guard let url = page.previewURL, NativeReaderDocument.allowedImageURL(url) else {
            throw NativeReaderError.invalidImage
        }
        return NativeReaderDocument.Page(id: page.id, url: url, layout: nil, watermark: page.watermark)
    }
}

/// 一度の速い応答だけでは高画質へ戻さない。古い通信の結果も判定から外す。
struct ReaderAutomaticQuality {
    static let highWaitSeconds = 2.0
    private(set) var quality = ReaderImageQuality.high
    private(set) var revision = 0
    private var fastLowLoads = 0

    mutating func highTimedOut() {
        guard quality != .low else { return }
        quality = .low
        revision += 1
        fastLowLoads = 0
    }

    mutating func receivedLow(seconds: Double, revision: Int) {
        guard quality == .low, revision == self.revision else { return }
        fastLowLoads = seconds <= 0.35 ? fastLowLoads + 1 : 0
        if fastLowLoads >= 3 {
            quality = .high
            self.revision += 1
            fastLowLoads = 0
        }
    }
}
