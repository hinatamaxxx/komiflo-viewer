import Foundation

enum NativeReaderError: LocalizedError, Equatable {
    case unsupportedDocument, invalidDocument, notLoggedIn, notEntitled, network, offline, invalidImage
    case http(Int)
    case documentCheck(String)

    /// 通信失敗をログイン切れにせず、住所を含まない表示用の種類へ変える。
    static func communicationError(_ error: Error) -> Self {
        if let error = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(error.code) {
            return .offline
        }
        return .network
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedDocument: return "この作品のページ形式にはまだ対応できていません。"
        case .invalidDocument: return "作品のページ情報を読み取れませんでした。"
        case .documentCheck(let code): return "作品のページ情報を読み取れませんでした。（確認番号：\(code)）"
        case .notLoggedIn: return "Komifloにログインしていません。アプリのブラウザ画面でログインしてください。"
        case .notEntitled: return "この作品の閲覧権限を確認できませんでした。公式のアカウント画面で確認してください。"
        case .http(let status): return "Komifloから読み込めませんでした（\(status)）。"
        case .network: return "Komifloと通信できませんでした。"
        case .offline: return "インターネットに接続されていません。Wi-Fiやモバイル通信を確認してください。"
        case .invalidImage: return "ページの画像を読み取れませんでした。"
        }
    }
}

/// 応答の値・キー・住所を含めず、失敗した項目と種類だけを固定番号で伝える。
enum NativeReaderDiagnostic {
    static func decoding(_ error: Error, stage: String) -> String {
        let path: [CodingKey]
        let kind: String
        switch error {
        case DecodingError.typeMismatch(_, let context): path = context.codingPath; kind = "1"
        case DecodingError.valueNotFound(_, let context): path = context.codingPath; kind = "2"
        case DecodingError.keyNotFound(let key, let context): path = context.codingPath + [key]; kind = "3"
        case DecodingError.dataCorrupted(let context): path = context.codingPath; kind = "4"
        default: return stage + "-00-0"
        }
        let fields = ["success", "content", "id", "type", "keyData", "keyHash", "isProtected", "premium",
                      "items", "userOwnQty", "expiry", "cdnPublic", "imgs", "pageCount", "filename", "original",
                      "attributes", "label", "children", "slug", "pages", "others"]
        let field = path.reversed().compactMap { key -> Int? in
            guard key.intValue == nil, let index = fields.firstIndex(of: key.stringValue) else { return nil }
            return index + 1
        }.first ?? 0
        return stage + String(format: "-%02d-", field) + kind
    }
}

/// ビューアを開くたびに公式から確認する。メールアドレスもキーも端末に保存しない。
struct NativeReaderIdentity: Decodable {
    let id: Int
    let email: String?
    let canViewContents: Bool?
    let deleted: Bool?
    let freeze: Freeze?
    struct Freeze: Decodable { let status: Bool? }

    static func decode(_ data: Data) throws -> Self {
        struct Envelope: Decodable { let success: Bool?; let user: NativeReaderIdentity? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.success != false,
              let user = envelope.user, user.id > 0, user.deleted != true else { throw NativeReaderError.notLoggedIn }
        guard user.freeze?.status != true else { throw NativeReaderError.notEntitled }
        return user
    }
}

/// 公式APIが返したページだけを描く。通常画像への置き換えや非公開ページの推測はしない。
struct NativeReaderDocument: Equatable {
    struct Page: Equatable, Identifiable {
        let id: Int
        let url: URL
        let layout: NativePageLayout?
        let watermark: Watermark?
        var previewURL: URL? = nil
    }
    struct Watermark: Equatable {
        let text: String
        let position: String
        let opacity: Double
        let black: Bool
    }
    let comicID: Int
    let pages: [Page]
    let expiresAt: Date?
    /// 公式のlabel-rightstart。先頭から2ページずつ組む。
    var rightStart = false
    /// 公式のlabel-firstdoublepageで見開きの先頭に指定されたページ番号。
    var spreadStarts: Set<Int> = []

    static func decode(from data: Data, requestedID: Int, identity: NativeReaderIdentity) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: data) }
        catch { throw NativeReaderError.documentCheck(NativeReaderDiagnostic.decoding(error, stage: "D01")) }
        guard envelope.success != false, let content = envelope.content, content.id == requestedID, requestedID > 0 else {
            throw NativeReaderError.documentCheck("D02")
        }
        guard content.type == "chapter" || content.type == "sample" else { throw NativeReaderError.unsupportedDocument }
        if content.type == "chapter", identity.canViewContents != true { throw NativeReaderError.notEntitled }
        if content.premium == true, content.items?.contains(where: { ($0.userOwnQty ?? 0) > 0 }) != true {
            throw NativeReaderError.notEntitled
        }
        var expiresAt: Date?
        if let expiry = content.expiry {
            let fraction = ISO8601DateFormatter()
            fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = ISO8601DateFormatter().date(from: expiry) ?? fraction.date(from: expiry), date > Date() else {
                throw NativeReaderError.notEntitled
            }
            expiresAt = date
        }
        guard let base = content.cdnPublic, let baseURL = URL(string: base), allowedImageURL(baseURL),
              baseURL.path == "/resized", baseURL.query == nil else { throw NativeReaderError.documentCheck("D03") }
        guard let images = content.imgs, !images.isEmpty, images.count <= 2000 else { throw NativeReaderError.documentCheck("D04") }
        let protected = content.keyData != nil || content.keyHash != nil || content.isProtected == true
        let layouts: [String: NativePageLayout]
        if protected {
            guard let key = content.keyData, !key.isEmpty, let hash = content.keyHash, !hash.isEmpty else {
                throw NativeReaderError.documentCheck("D05")
            }
            guard let email = identity.email, !email.isEmpty, email.unicodeScalars.allSatisfy({ $0.value <= 255 }) else {
                throw NativeReaderError.documentCheck("D06")
            }
            guard let encrypted = Data(base64Encoded: key), encrypted.count <= 2 * 1024 * 1024,
                  hash.utf8.allSatisfy({ $0 < 128 }), hash.count <= 4096 else { throw NativeReaderError.documentCheck("D07") }
            let emailBytes = Data(email.unicodeScalars.map { UInt8($0.value) })
            let mask = Array((emailBytes.base64EncodedString() + hash + "76c065bbe09bdbf3663a28dd74a22bcb40dac7cc2386a2b7a4c69774ae1f461a").utf8)
            let plain = Data(encrypted.enumerated().map { $0.element ^ mask[$0.offset % mask.count] })
            guard let entries = try? JSONDecoder().decode([String: [Int64]].self, from: plain) else {
                throw NativeReaderError.documentCheck("D08")
            }
            guard Set(entries.keys) == Set(images.keys) else { throw NativeReaderError.documentCheck("D09") }
            do { layouts = try entries.mapValues { try NativePageLayout(encoded: $0) } }
            catch { throw NativeReaderError.documentCheck("D10") }
        } else { layouts = [:] }
        var pages: [Page] = []
        let labels = content.attributes?.label?.children ?? []
        let spreadOriginals = Set(labels.filter { $0.slug == "label-firstdoublepage" }.flatMap { $0.pages?.values ?? [] })
        var spreadStarts: Set<Int> = []
        for (index, image) in images {
            guard let number = Int(index), number >= 0, number < Int.max, index == String(number) else { throw NativeReaderError.documentCheck("D11") }
            guard number < images.count else { throw NativeReaderError.documentCheck("D14") }
            guard let filename = image.filename, !filename.contains("\\"), !filename.contains("#") else {
                throw NativeReaderError.documentCheck("D12")
            }
            // 公式の配信名には期限・署名が付く。パスだけを検査し、署名は変更しない。
            let parts = filename.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            let filePath = String(parts[0])
            let query = parts.count == 2 ? String(parts[1]) : nil
            guard !filePath.isEmpty, !filePath.hasPrefix("/"), !filePath.contains("%"),
                  !filePath.split(separator: "/").contains("..") else { throw NativeReaderError.documentCheck("D12") }
            let path: String
            if protected {
                // 公式と同じく拡張子を除いた配信名だけを使う。元画像の住所を探さない。
                let name = filePath.replacingOccurrences(of: "\\.(?:jpg|png)(?!.*\\.(?:jpg|png))", with: "", options: [.regularExpression, .caseInsensitive])
                path = "/scrambled/" + name
            } else { path = "/resized/564_mobile_large_3x/" + filePath }
            guard let url = URL(string: "https://image.komiflo-cdn.com" + path + (query.map { "?" + $0 } ?? "")), allowedImageURL(url),
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery == query else {
                throw NativeReaderError.documentCheck("D13")
            }
            var watermark: Watermark?
            if let label = labels.first(where: { $0.slug == "label-anti-piracy-id" && $0.pages?.values.contains(image.original?.value ?? "") == true }) {
                let specified = (label.others ?? "").split(separator: "_", omittingEmptySubsequences: false).map(String.init)
                let defaults = ["bl", "0.2", "black"]
                let parts = specified.count == 3 ? specified.enumerated().map { $0.element.isEmpty ? defaults[$0.offset] : $0.element } : defaults
                guard parts.count == 3, ["tl", "tr", "bl", "br"].contains(parts[0]),
                      let opacity = Double(parts[1]), opacity > 0, opacity <= 1,
                      ["black", "white"].contains(parts[2]) else { throw NativeReaderError.unsupportedDocument }
                watermark = Watermark(text: String(identity.id, radix: 36).uppercased(), position: parts[0], opacity: opacity, black: parts[2] == "black")
            }
            // 公式ビューアが先に出す縮小画像。同じ配信名・期限・署名だけを使う。
            guard let preview = URL(string: base + "/396_desktop_medium_2x/" + filename), allowedImageURL(preview),
                  URLComponents(url: preview, resolvingAgainstBaseURL: false)?.percentEncodedQuery == query else {
                throw NativeReaderError.documentCheck("D13")
            }
            pages.append(Page(id: number + 1, url: url, layout: layouts[index], watermark: watermark, previewURL: preview))
            if let original = image.original?.value, spreadOriginals.contains(original) { spreadStarts.insert(number + 1) }
        }
        pages.sort { $0.id < $1.id }
        guard pages.map(\.id) == Array(1...pages.count) else { throw NativeReaderError.documentCheck("D14") }
        guard content.pageCount == nil || content.pageCount == pages.count else { throw NativeReaderError.documentCheck("D15") }
        return Self(comicID: requestedID, pages: pages, expiresAt: expiresAt,
                    rightStart: labels.contains { $0.slug == "label-rightstart" }, spreadStarts: spreadStarts)
    }

    static func allowedImageURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "image.komiflo-cdn.com" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    private struct Envelope: Decodable { let success: Bool?; let content: Content? }
    private struct Content: Decodable {
        let id: Int
        let type: String?
        let keyData: String?
        let keyHash: String?
        let isProtected: Bool?
        let premium: Bool?
        let items: [Item]?
        let expiry: String?
        let cdnPublic: String?
        let imgs: [String: Image]?
        let pageCount: Int?
        let attributes: Attributes?
    }
    private struct Item: Decodable { let userOwnQty: Int? }
    private struct Image: Decodable { let filename: String?; let original: PageID? }
    private struct Attributes: Decodable { let label: Labels? }
    private struct Labels: Decodable { let children: [Label]? }
    private struct Label: Decodable { let slug: String?; let pages: PageIDs?; let others: String? }
    private struct PageID: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let field = try decoder.singleValueContainer()
            if let string = try? field.decode(String.self) { value = string }
            else { value = String(try field.decode(Int.self)) }
        }
    }
    private struct PageIDs: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let field = try decoder.singleValueContainer()
            if let ids = try? field.decode([PageID].self) { values = ids.map(\.value) }
            else { values = [try field.decode(PageID.self).value] }
        }
    }
}

/// 閉じたり作品を切り替えたりしたあとの古い通信結果は、次の画面へ渡さない。
struct NativeReaderGeneration: Equatable {
    private(set) var value = UUID()
    mutating func advance() { value = UUID() }
    func accepts(_ candidate: UUID) -> Bool { value == candidate }
}

enum NativeReaderCookiePolicy {
    static func permits(_ cookie: HTTPCookie, for url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host, cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
        let domain = cookie.domain.lowercased()
        let domainMatches: Bool
        if domain.hasPrefix(".") {
            let suffix = String(domain.dropFirst())
            domainMatches = host == suffix || host.hasSuffix("." + suffix)
        } else { domainMatches = host == domain }
        let path = cookie.path
        let pathMatches = url.path == path || (url.path.hasPrefix(path) && (path.hasSuffix("/") || url.path.dropFirst(path.count).hasPrefix("/")))
        return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https")
    }
}
