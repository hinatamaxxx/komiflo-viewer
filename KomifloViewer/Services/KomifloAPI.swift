import CryptoKit
import Combine
import Foundation

/// 公式APIの応答を端末内に保存しておき、アプリを起動したときに前回の内容をすぐ出すための仕組み。
/// 画面は「保存してある内容ですぐ表示 → 裏で公式から取り直し → 変わっていれば差し替え」の順に動く
enum APICache {
    private static let lock = NSLock()
    private static var epoch = UUID()
    static var generation: UUID { lock.withLock { epoch } }
    /// true の間（fromCache の中）は通信せず、保存してある応答だけを使う
    @TaskLocal static var cacheOnly = false

    /// 保存してある前回の応答だけで処理する（通信しないので待たない）。保存が無いものは失敗になる
    static func fromCache<R>(_ operation: () async throws -> R) async rethrows -> R {
        try await $cacheOnly.withValue(true, operation: operation)
    }

    private static let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("API", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func fileURL(for url: String) -> URL {
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    static func read(_ url: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let file = fileURL(for: url)
        guard let body = try? Data(contentsOf: file), let safe = NativeReaderPrivacy.metadataOnly(body) else { return nil }
        if safe != body { try? safe.write(to: file, options: .atomic) }
        return safe
    }

    /// 書き込みは裏で行う（画面の動きを止めない）
    @discardableResult
    static func write(_ body: Data, for url: String, generation: UUID? = nil) -> Task<Void, Never> {
        let ticket = generation ?? Self.generation
        let file = fileURL(for: url)
        return Task.detached(priority: .utility) {
            guard let safe = NativeReaderPrivacy.metadataOnly(body) else { return }
            lock.withLock {
                guard epoch == ticket else { return }
                try? safe.write(to: file, options: .atomic)
            }
        }
    }

    /// 保存した応答をすべて消す（ログアウトしたときなど）
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        epoch = UUID()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

enum KomifloAPIError: LocalizedError {
    case notLoggedIn
    /// ログイン中のまま公式に断られた（401・403）。ログイン切れとは分ける
    case notPermitted
    case offline, network
    case http(Int)
    case invalidResponse
    /// 保存してある応答が無い（APICache.fromCache の中だけで起きる）
    case notCached

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Komifloにログインしていません。ブラウザ画面でログインしてから開き直してください。"
        case .notPermitted:
            return "この内容を表示する権限がありません。公式のアカウント画面で確認してください。"
        case .offline:
            return NativeReaderError.offline.errorDescription
        case .network:
            return "Komifloに接続できませんでした。通信状態を確認して、もう一度お試しください。"
        case .http(let status):
            return "Komifloから読み込めませんでした（\(status)）。"
        case .invalidResponse:
            return "Komifloの応答を読み取れませんでした。"
        case .notCached:
            return "保存してある内容がありません。"
        }
    }
}

/// ログインCookieを引き継ぎ、公式APIへネイティブの通信でアクセスする。
@MainActor
final class KomifloAPI: NSObject, ObservableObject {
    @Published private(set) var requiresLogin = false
    private var isInvalidated = false
    private var loginCheck: Task<KFUser, Error>?
    private lazy var nativeTransport = NativeReaderService()

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - Endpoints

    func currentUser() async throws -> KFUser {
        let response = try await get("/session/user", as: KFSessionResponse.self)
        guard let user = response.loggedInUser else {
            requireLogin()
            throw KomifloAPIError.notLoggedIn
        }
        requiresLogin = false
        return user
    }

    /// 同時に断られた通信の確認を1回のsession/userにまとめる。
    private func confirmedUser() async throws -> KFUser {
        if let loginCheck { return try await loginCheck.value }
        let check = Task { try await currentUser() }
        loginCheck = check
        defer { loginCheck = nil }
        return try await check.value
    }

    /// 一覧・ビューアで判明したログイン切れを、アプリの入口へ伝える。
    func requireLogin() {
        guard !isInvalidated else { return }
        requiresLogin = true
    }

    /// ブックマーク・閲覧履歴の一覧。サイトと同じ組み立て方：
    /// 閲覧履歴の月別は start_date/end_date、ブックマークの既読・未読は filter=read|unread、
    /// 並び順はサイトの既定の順（閲覧履歴なら最近読んだ順）を使う
    func readingList(
        id: Int,
        page: Int,
        filter: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> KFReadingListResponse {
        var query: [String] = []
        if let startDate, let endDate {
            query.append("start_date=\(Self.dayFormat.string(from: startDate))")
            query.append("end_date=\(Self.dayFormat.string(from: endDate))")
        }
        if let filter { query.append("filter=\(filter)") }
        query.append("page=\(page)")
        return try await get("/reading_list/id/\(id)?" + query.joined(separator: "&"), as: KFReadingListResponse.self)
    }

    /// 閲覧履歴がある期間（月別の絞り込みに使う）
    func historyRange() async throws -> KFDateRange {
        try await get("/content/type/history/range", as: KFDateRange.self)
    }

    /// 人気急上昇（公式ホームと同じ：直近28日の閲覧数順）
    func popularChapters(days: Int = 28) async throws -> [KFContent] {
        try await get(HomeShelfKind.recent.contentPath(attributeID: 0, page: 0, recentDays: days),
                      as: KFContentListResponse.self).results ?? []
    }

    func likedIDs(userID: Int) async throws -> [Int] {
        try await get("/user/id/\(userID)/bookmarks", as: KFLikesResponse.self).bookmarks ?? []
    }

    func content(id: Int) async throws -> KFContent {
        guard let content = try await get("/content/id/\(id)", as: KFContentResponse.self).content else {
            throw KomifloAPIError.invalidResponse
        }
        return content
    }

    /// 作品の各ページの縮小画像の住所（公式のインデックスが使うものと同じ。並べ替えの保護がかかっていない、公式が配る縮小画像）。
    /// ページの画像に関わるので、応答は端末に保存しない
    func pageThumbnails(contentID: Int) async throws -> [URL] {
        let response = try await get("/content/id/\(contentID)", as: KFPageImagesResponse.self, saves: false)
        guard let content = response.content, let imgs = content.imgs else { return [] }
        let base = content.cdnPublic?.isEmpty == false ? content.cdnPublic! : "https://image.komiflo-cdn.com/resized"
        return imgs
            .compactMap { key, img -> (Int, String)? in
                guard let index = Int(key), let filename = img.filename else { return nil }
                return (index, filename)
            }
            .sorted { $0.0 < $1.0 }
            .compactMap { URL(string: "\(base)/396_desktop_medium_2x/\($0.1)") }
    }

    /// 雑誌の一覧（attribute "magazine" の子）
    func magazines() async throws -> [KFAttribute] {
        try await get("/attribute/slug/magazine?content_limit=0", as: KFAttributeResponse.self)
            .attribute?.children ?? []
    }

    /// サイトのマガジンラックと同じ雑誌一覧（最新号の表紙・発売日つき、新しい順）
    func magazineRack() async throws -> [MagazineTitle] {
        try await get(
            "https://cache.api.komiflo.com/lander/lander.json",
            // 配列に null が混ざることがあるので、読めない要素は飛ばす
            as: [KFLanderItem?].self,
            withCredentials: false,
            convertSnakeCase: false
        ).compactMap { $0?.magazineTitle }
    }

    /// 雑誌の号（volume）。サイトと同じく「新しい日付→古い日付」の期間で取る。
    /// 複数の分類をまとめる雑誌（特別号）は attribute/ids/<a,b,…> で取る
    func magazineIssues(attributeIDs: [Int], from newest: Date, to oldest: Date) async throws -> [KFContent] {
        let ids = attributeIDs.map(String.init).joined(separator: ",")
        let base = attributeIDs.count == 1 ? "/attribute/id/\(ids)" : "/attribute/ids/\(ids)"
        let path = base + "/content?page_size=200"
            + "&start_date=\(Self.dayFormat.string(from: newest))&end_date=\(Self.dayFormat.string(from: oldest))"
        return try await get(path, as: KFContentListResponse.self).results ?? []
    }

    /// タグの一覧。sort は公式と同じ name_asc / name_desc / popular_desc。
    /// キャッシュ用のAPIはCookie付きの読み込みを受け付けない
    func tags(sort: String = "name_asc") async throws -> [KFAttribute] {
        try await get(
            "https://cache.api.komiflo.com/t/\(sort).json",
            as: KFAttributeResponse.self,
            withCredentials: false
        ).attribute?.children ?? []
    }

    /// タグ・作者などが付いた作品（話単位）。page は0始まり
    func attributeContents(attributeID: Int, page: Int) async throws -> KFContentListResponse {
        try await attributeContents(attributeIDs: [attributeID], page: page)
    }

    /// 複数のタグを掛け合わせた作品（公式と同じく ID を & でつなぐ＝すべてに当てはまる作品）
    func attributeContents(attributeIDs: [Int], page: Int, options: TagListingOptions = .init()) async throws -> KFContentListResponse {
        try await get(options.contentPath(attributeIDs: attributeIDs, page: page), as: KFContentListResponse.self)
    }

    /// 作家ギャラリー（公式と同じ読み仮名順、20人ずつ。page は0始まり）。
    /// kana に「か」などを渡すと、その行の作家だけになる
    func artists(kana: String?, page: Int) async throws -> (artists: [KFAttribute], totalPages: Int) {
        let filter = kana.map { "\(Self.escape($0))+canview" } ?? "canview"
        let gallery = try await get(
            "/attribute/slug/artists?page_size=20&content_limit=0&page=\(page)&filter=\(filter)",
            as: KFAttributeResponse.self
        ).attribute
        return (gallery?.children ?? [], gallery?.childrenTotalPages ?? 0)
    }

    /// 作者の単行本（公式の作者ページと同じ取り方。type = volume_affiliate のもの、新しい順）
    func artistTankoubons(slug: String) async throws -> [KFContent] {
        let escaped = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let artist = try await get(
            "/attribute/slug/\(escaped)?order=published&content_limit=100",
            as: KFAttributeResponse.self
        ).attribute
        return (artist?.content ?? [])
            .filter { $0.type == "volume_affiliate" }
            .sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
    }

    /// 作者（/artists/<slug>）
    func attribute(slug: String) async throws -> KFAttribute {
        let escaped = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let attribute = try await get(
            "/attribute/slug/\(escaped)?content_limit=0",
            as: KFAttributeResponse.self
        ).attribute else {
            throw KomifloAPIError.invalidResponse
        }
        return attribute
    }

    /// 最近出た号（中身の作品つき）。ホームで使う
    func latestIssues(since: Date) async throws -> [KFContent] {
        try await get("/content/latest?from=\(Self.dayFormat.string(from: since))", as: KFContentListResponse.self)
            .results ?? []
    }

    /// 作品のコメント（20件ずつ、page は0始まり）
    func comments(contentID: Int, page: Int) async throws -> KFCommentsResponse {
        try await get("/content/id/\(contentID)/comments?page=\(page)", as: KFCommentsResponse.self)
    }

    /// 読み終わりのページの「こちらもおすすめ」。公式ビューアと同じく、作品のタグの1つから13話を取る
    func endPageRecommendations(tagID: Int) async throws -> [KFContent] {
        try await get(
            "/attribute/id/\(tagID)/content?page_size=13&filter=chapter+-plus",
            as: KFContentListResponse.self
        ).results ?? []
    }

    /// その作品を読んだ人へのおすすめ
    func recommends(contentID: Int) async throws -> [KFContent] {
        try await get("/content/id/\(contentID)/recommends", as: KFRecommendsResponse.self).contents ?? []
    }

    // MARK: - お知らせ・マガジンラック

    /// お知らせ（公式の /notifications と同じ：フォロー中の作家・タグの新着。page は0始まり）
    func feeds(page: Int) async throws -> KFContentListResponse {
        try await get("/feeds?page=\(page)", as: KFContentListResponse.self)
    }

    /// その期間に出た号（公式のマガジンラックの月の切り替えと同じ取り方）
    func publishedIssues(from start: Date, to end: Date) async throws -> [KFContent] {
        try await get(
            "/content/published?type=volume&child_limit=0"
                + "&start_date=\(Self.dayFormat.string(from: start))&end_date=\(Self.dayFormat.string(from: end))",
            as: KFContentListResponse.self
        ).results ?? []
    }

    /// 雑誌の号が出ている期間（マガジンラックの月の一覧に使う）
    func magazinesRange() async throws -> KFDateRange {
        try await get("/content/type/magazines/range", as: KFDateRange.self)
    }

    // MARK: - 公式ホーム

    /// 公式ホームのセクション（トップカルーセル・特集・作家バナー・タグなど）
    func homepageSections() async throws -> [KFAttribute] {
        try await get("/attribute/slug/homepage?content_limit=0", as: KFAttributeResponse.self)
            .attribute?.children ?? []
    }

    /// 公式と同じくキャッシュから分類を読む（セクションの中身・特集の棚の作品）
    func cachedAttribute(id: Int) async throws -> KFAttribute {
        guard let attribute = try await get(
            "https://cache.api.komiflo.com/a/\(id).json",
            as: KFAttributeResponse.self,
            withCredentials: false
        ).attribute else {
            throw KomifloAPIError.invalidResponse
        }
        return attribute
    }

    /// 分類の詳細（バナー画像などが入る）
    func attributeInfo(id: Int) async throws -> KFAttribute {
        guard let attribute = try await get(
            "/attribute/id/\(id)?content_limit=0",
            as: KFAttributeResponse.self
        ).attribute else {
            throw KomifloAPIError.invalidResponse
        }
        return attribute
    }

    /// 公式ホームの「新着・話題の作品」と同じ取り方
    func topicalChapters(attributeID: Int) async throws -> [KFContent] {
        try await homeShelfContents(kind: .topical, attributeID: attributeID, page: 0).results ?? []
    }

    /// 公式ホームの「ロングヒット作品」と同じ取り方
    /// （120〜300日前に出て、直近3か月の閲覧数が多い作品。241 は本番環境の「イラスト」）
    func longHitChapters() async throws -> [KFContent] {
        try await homeShelfContents(kind: .longHits, attributeID: 0, page: 0).results ?? []
    }

    /// ホームの棚と「もっと見る」で、条件・取得数・順序を共用する。
    func homeShelfContents(kind: HomeShelfKind, attributeID: Int, page: Int,
                           date: Date = Date()) async throws -> KFContentListResponse {
        try await get(kind.contentPath(attributeID: attributeID, page: page, date: date),
                      as: KFContentListResponse.self)
    }

    /// 作品をキーワードで検索（page は0始まり）
    func searchContents(query: String, page: Int) async throws -> KFContentListResponse {
        try await get("/content/search/\(Self.escape(query))?page=\(page)", as: KFContentListResponse.self)
    }

    /// タグ・作者・雑誌をキーワードで検索
    func searchAttributes(query: String) async throws -> [KFSearchAttribute] {
        try await get("/search/\(Self.escape(query))?page=0", as: KFSearchAttributeResponse.self).results ?? []
    }

    private static func escape(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    // MARK: - 書き込み（サイトの★・♥ボタンと同じリクエスト）

    func setLiked(_ liked: Bool, contentID: Int, userID: Int) async throws {
        let response: KFSuccessResponse
        if liked {
            response = try await request(
                "POST",
                "/user/id/\(userID)/contents/likes",
                body: ["content": contentID],
                as: KFSuccessResponse.self
            )
        } else {
            response = try await request(
                "DELETE",
                "/user/id/\(userID)/contents/likes/\(contentID)",
                as: KFSuccessResponse.self
            )
        }
        guard response.success != false else { throw KomifloAPIError.invalidResponse }
    }

    /// ログアウト（公式のメニューの「ログアウト」と同じリクエスト）
    func logout() async throws {
        let result = try await request("POST", "/session/logout", body: [:], as: KFSuccessResponse.self)
        guard result.success != false else { throw KomifloAPIError.invalidResponse }
    }

    /// 旧アカウントの通信結果を、新しいログイン後の画面やキャッシュへ戻さない。
    func invalidate() {
        isInvalidated = true
        nativeTransport.close()
    }

    /// フォローしている作家・タグなど（公式と同じく全件を一度に取る）
    func follows(userID: Int) async throws -> [KFAttribute] {
        try await get("/user/id/\(userID)/follows?page_size=9999", as: KFFollowsResponse.self).results ?? []
    }

    /// 作家・タグをフォロー / フォロー解除（公式のフォローボタンと同じリクエスト）
    func setFollowing(_ following: Bool, attributeID: Int, userID: Int) async throws {
        let response: KFSuccessResponse
        if following {
            response = try await request(
                "POST",
                "/user/id/\(userID)/follows",
                body: ["attribute": attributeID],
                as: KFSuccessResponse.self
            )
        } else {
            response = try await request(
                "DELETE",
                "/user/id/\(userID)/follows/\(attributeID)",
                as: KFSuccessResponse.self
            )
        }
        guard response.success != false else { throw KomifloAPIError.invalidResponse }
    }

    func setBookmarked(_ bookmarked: Bool, contentID: Int, readingListID: Int) async throws {
        let response = try await request(
            bookmarked ? "POST" : "DELETE",
            "/reading_list/id/\(readingListID)/contents",
            body: ["content_id": contentID],
            as: KFSuccessResponse.self
        )
        guard response.success != false else { throw KomifloAPIError.invalidResponse }
    }

    // MARK: - Transport

    private func get<T: Decodable>(
        _ path: String,
        as type: T.Type,
        withCredentials: Bool = true,
        convertSnakeCase: Bool = true,
        saves: Bool = true
    ) async throws -> T {
        try await request(
            "GET",
            path,
            as: type,
            withCredentials: withCredentials,
            convertSnakeCase: convertSnakeCase,
            saves: saves
        )
    }

    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        as type: T.Type,
        withCredentials: Bool = true,
        convertSnakeCase: Bool = true,
        saves: Bool = true
    ) async throws -> T {
        guard !isInvalidated else { throw CancellationError() }
        let cacheGeneration = APICache.generation
        let url = path.hasPrefix("https://") ? path : "https://api.komiflo.com" + path
        // 辞書のキー（雑誌のslugなど）まで変換されては困るJSONは、変換せずに読む
        func decode(_ body: Data) throws -> T {
            do {
                return try (convertSnakeCase ? decoder : JSONDecoder()).decode(T.self, from: body)
            } catch {
                throw KomifloAPIError.invalidResponse
            }
        }
        // 保存してある前回の応答で表示するとき：通信せずに読む
        if method == "GET", saves, APICache.cacheOnly {
            guard let saved = APICache.read(url) else { throw KomifloAPIError.notCached }
            return try decode(saved)
        }
        guard let nativeURL = URL(string: url) else { throw KomifloAPIError.invalidResponse }
        let response: Data
        do {
            response = try await nativeTransport.apiData(url: nativeURL, method: method, withCredentials: withCredentials, body: body)
        } catch NativeReaderError.notLoggedIn {
            guard !isInvalidated else { throw CancellationError() }
            guard nativeURL.path != "/session/user" else {
                requireLogin()
                throw KomifloAPIError.notLoggedIn
            }
            // 公式と同じく、ログイン状態はsession/userだけで決める。他のAPIの401・403は権限不足のこともある。
            // ログイン切れならcurrentUserが入口へ伝え、notLoggedInを投げる。
            _ = try await confirmedUser()
            throw KomifloAPIError.notPermitted
        } catch NativeReaderError.http(let status) {
            throw KomifloAPIError.http(status)
        } catch NativeReaderError.offline {
            throw KomifloAPIError.offline
        } catch NativeReaderError.network {
            throw KomifloAPIError.network
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KomifloAPIError.invalidResponse
        }
        guard !isInvalidated else { throw CancellationError() }
        let value = try decode(response)
        if method == "GET", saves { APICache.write(response, for: url, generation: cacheGeneration) }
        return value
    }
}

// MARK: - Response models（api.komiflo.com のJSON）

/// 作品の各ページの画像のファイル名（content/id の imgs。キーはページの順番の数字）
struct KFPageImagesResponse: Decodable {
    let content: Content?

    struct Content: Decodable {
        let cdnPublic: String?
        let imgs: [String: Img]?
    }

    struct Img: Decodable {
        let filename: String?
    }
}

struct KFReadingListResponse: Decodable {
    let results: Results?
    let total: Int?
    let totalPages: Int?

    struct Results: Decodable {
        let contents: [KFContent]?
        /// コレクションの名前（公式は "タイトル|サブタイトル|…" の形）
        let name: String?
    }
}

struct KFDateRange: Decodable {
    let from: String?
    let to: String?
    let list: [String]?

    var fromDate: Date? { from.flatMap { ISO8601DateFormatter().date(from: $0) } }
    var toDate: Date? { to.flatMap { ISO8601DateFormatter().date(from: $0) } }
}

struct KFCommentsResponse: Decodable {
    let results: [KFComment]?
    let total: Int?
    let totalPages: Int?
}

struct KFComment: Decodable, Identifiable, Hashable {
    let id: Int
    let author: String?
    let body: String?
    let created: String?

    var createdDate: Date? {
        guard let created else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: created) ?? withFraction.date(from: created)
    }
}

struct KFFollowsResponse: Decodable {
    let results: [KFAttribute]?
}

struct KFSuccessResponse: Decodable {
    let success: Bool?
}

struct KFLikesResponse: Decodable {
    let bookmarks: [Int]?
}

struct KFContentResponse: Decodable {
    let content: KFContent?
}

struct KFContent: Decodable {
    let id: Int
    let title: String?
    let artists: [KFAttributeRef]
    let tags: [KFAttributeRef]
    let isKomifloOriginal: Bool?
    let coverFilename: String?
    let cdnThumbs: String?
    let liked: Bool?
    let likesCount: Int?
    let commentsCount: Int?
    let magazine: String?
    /// 月ごとのマガジンラックを同じ雑誌順で並べるための識別名。
    let magazineSlug: String?
    /// 収録されている号のID（次の話を探すのに使う）
    let parentID: Int?
    /// "chapter"（1話）/ "volume"（雑誌の号）など
    let type: String?
    let published: Date?
    let pageCount: Int?
    /// 号の中の作品（content/id/<号> や content/latest のときだけ入る）
    let children: [KFContent]
    /// 単行本（type = volume_affiliate）の発売日と購入先
    let releaseDate: String?
    let purchaseLinks: [PurchaseLink]

    struct PurchaseLink: Hashable {
        let store: String
        let url: URL
    }

    private enum CodingKeys: String, CodingKey {
        case id, data, attributes, namedImgs, cdnThumbs, liked, likesCount, parents, type, published, children, pageCount
        case commentsCount
    }

    private struct TitleData: Decodable {
        let title: String?
        let releaseDate: String?
        let linkDlsite: String?
        let linkDmm: String?
        let linkWani: String?
        let linkStore: String?
    }
    private struct Attributes: Decodable {
        let artists: Group?
        let tags: Group?
        let magazine: Group?
    }
    private struct Group: Decodable { let children: [KFAttributeRef]? }
    private struct NamedImages: Decodable { let cover: Image? }
    private struct Image: Decodable { let filename: String? }
    private struct Parent: Decodable {
        let id: Int?
        let data: TitleData?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        // 作品ごとに欠けている項目があっても一覧全体が壊れないよう、詳細はすべて任意で読む
        let data = try? container.decodeIfPresent(TitleData.self, forKey: .data)
        title = data?.title
        releaseDate = data?.releaseDate
        // 公式の単行本ページと同じ購入先（あるものだけ）
        purchaseLinks = [
            ("DLsite", data?.linkDlsite),
            ("FANZA", data?.linkDmm),
            ("ワニマガジン", data?.linkWani),
            ("Komifloストア", data?.linkStore),
        ].compactMap { store, link in
            guard let link, !link.isEmpty, let url = URL(string: link),
                  url.scheme == "https" || url.scheme == "http" else { return nil }
            return PurchaseLink(store: store, url: url)
        }
        let attributes = try? container.decodeIfPresent(Attributes.self, forKey: .attributes)
        artists = attributes?.artists?.children ?? []
        tags = attributes?.tags?.children ?? []
        isKomifloOriginal = (attributes?.tags?.children).map {
            $0.contains { $0.slug == "original" || $0.name == "オリジナル" }
        }
        magazineSlug = attributes?.magazine?.children?.first?.slug
        coverFilename = (try? container.decodeIfPresent(NamedImages.self, forKey: .namedImgs))?.cover?.filename
        cdnThumbs = try? container.decodeIfPresent(String.self, forKey: .cdnThumbs)
        liked = try? container.decodeIfPresent(Bool.self, forKey: .liked)
        likesCount = try? container.decodeIfPresent(Int.self, forKey: .likesCount)
        commentsCount = try? container.decodeIfPresent(Int.self, forKey: .commentsCount)
        let parent = (try? container.decodeIfPresent([Parent].self, forKey: .parents))?.first
        magazine = parent?.data?.title
        parentID = parent?.id
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        published = (try? container.decodeIfPresent(String.self, forKey: .published))
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        pageCount = try? container.decodeIfPresent(Int.self, forKey: .pageCount)
        children = (try? container.decodeIfPresent([KFContent].self, forKey: .children)) ?? []
    }
}

struct KFContentListResponse: Decodable {
    let page: Int?
    let results: [KFContent]?
    let total: Int?
    let totalPages: Int?
    let pageSize: Int?
}

struct KFRecommendsResponse: Decodable {
    let contents: [KFContent]?
}

struct KFAttributeResponse: Decodable {
    let attribute: KFAttribute?
}

/// 雑誌・タグ・作者などの分類
struct KFAttribute: Codable, Identifiable, Hashable {
    let id: Int
    let slug: String?
    let name: String
    let searchTerms: String?
    let contentCount: Int
    /// 読み仮名（作家ギャラリーの並び・表示に使う）
    let nameRead: String?
    /// 新しく追加された作品の数（公式の「新着」）
    let newContentCount: Int
    let children: [KFAttribute]
    /// children の総ページ数（0始まりのページ）
    let childrenTotalPages: Int?
    /// 親の分類（公式の topLevelAttributes：1 = タグ、2 = 作家）
    let parentID: Int?
    /// ログイン中のユーザーがフォローしているか（attribute/slug/<作家> のときに入る）
    let following: Bool?
    /// content_limit を付けて取ったときの作品（作者ページの単行本など）
    let content: [KFContent]
    /// 公式ホームの各セクションの中身（バナー・棚・作家・タグ）
    let siblings: [KFAttribute]
    /// バナーのリンク先（公式サイト内のパス、または外部URL）
    let href: String?
    /// 公式の作家情報に登録された外部プロフィール
    let twitter: String?
    let pixiv: String?
    /// バナー画像（named_imgs.banner）
    let bannerFilename: String?
    let cdnPublic: String?

    /// 公式のスマホ表示と同じサイズのバナー画像
    var bannerURL: URL? {
        guard let bannerFilename else { return nil }
        let base = (cdnPublic?.isEmpty == false ? cdnPublic! : "https://image.komiflo-cdn.com/resized")
        return URL(string: "\(base)/750_mobile_medium_2x/\(bannerFilename)")
    }

    static let tagsParentID = 1
    static let artistsParentID = 2

    private enum CodingKeys: String, CodingKey {
        case id, slug, data, contentCount, children, nameRead, newContentCount, childrenPagination
        case parentID = "parentId"
        case following
        case content
        case siblings
        case namedImgs
        case cdnPublic
    }

    private struct NamedImages: Codable {
        let banner: Image?
        struct Image: Codable { let filename: String? }
    }

    private struct Pagination: Decodable {
        let totalPages: Int?
    }

    private struct AttributeData: Codable {
        let name: String?
        let searchTerms: String?
        let href: String?
        let twitter: String?
        let pixiv: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        slug = try? container.decodeIfPresent(String.self, forKey: .slug)
        let data = try? container.decodeIfPresent(AttributeData.self, forKey: .data)
        name = data?.name ?? slug ?? ""
        searchTerms = data?.searchTerms
        contentCount = (try? container.decodeIfPresent(Int.self, forKey: .contentCount)) ?? 0
        nameRead = try? container.decodeIfPresent(String.self, forKey: .nameRead)
        newContentCount = (try? container.decodeIfPresent(Int.self, forKey: .newContentCount)) ?? 0
        children = (try? container.decodeIfPresent([KFAttribute].self, forKey: .children)) ?? []
        childrenTotalPages = (try? container.decodeIfPresent(Pagination.self, forKey: .childrenPagination))?.totalPages
        parentID = try? container.decodeIfPresent(Int.self, forKey: .parentID)
        following = try? container.decodeIfPresent(Bool.self, forKey: .following)
        content = (try? container.decodeIfPresent([KFContent].self, forKey: .content)) ?? []
        siblings = (try? container.decodeIfPresent([KFAttribute].self, forKey: .siblings)) ?? []
        href = data?.href
        twitter = data?.twitter
        pixiv = data?.pixiv
        bannerFilename = (try? container.decodeIfPresent(NamedImages.self, forKey: .namedImgs))?.banner?.filename
        cdnPublic = try? container.decodeIfPresent(String.self, forKey: .cdnPublic)
    }

    /// 端末内に保存するとき用（一覧の表示に使う項目だけ。読み込みと同じ形で書くので、そのまま読み戻せる）
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(slug, forKey: .slug)
        try container.encode(AttributeData(name: name, searchTerms: searchTerms, href: href, twitter: twitter, pixiv: pixiv), forKey: .data)
        try container.encode(contentCount, forKey: .contentCount)
        try container.encodeIfPresent(nameRead, forKey: .nameRead)
        try container.encode(newContentCount, forKey: .newContentCount)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(following, forKey: .following)
        if let bannerFilename {
            try container.encode(NamedImages(banner: .init(filename: bannerFilename)), forKey: .namedImgs)
        }
        try container.encodeIfPresent(cdnPublic, forKey: .cdnPublic)
    }

    static func == (lhs: KFAttribute, rhs: KFAttribute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 作品に付いている作者・タグ
struct KFAttributeRef: Decodable, Hashable {
    let id: Int?
    let slug: String?
    let data: Name?

    struct Name: Decodable, Hashable { let name: String? }

    var name: String { data?.name ?? slug ?? "" }
}

/// /search/<キーワード> の結果（タグ・作者・雑誌）
struct KFSearchAttribute: Decodable, Identifiable, Hashable {
    let id: Int
    let slug: String?
    let type: String?
    let data: KFAttributeRef.Name?

    var name: String { data?.name ?? slug ?? "" }
}

struct KFSearchAttributeResponse: Decodable {
    let results: [KFSearchAttribute]?
}

/// マガジンラックの雑誌（cache.api.komiflo.com/lander/lander.json）
struct MagazineTitle: Identifiable, Hashable {
    let slug: String
    let name: String
    let coverURL: URL?
    let latestIssueID: Int?
    let latestPublished: Date?

    var id: String { slug }
    /// 特別号は複数の分類（特別号・アンソロジーなど）をまとめた棚
    var isSpecial: Bool { slug == "special_contents" }
}

struct KFLanderItem: Decodable {
    let id: Int?
    let data: Title?
    let src: String?
    let published: String?
    /// { "<雑誌のslug>": {} } の形
    let attributes: [String: IgnoredJSON]?

    struct Title: Decodable { let title: String? }

    var magazineTitle: MagazineTitle? {
        guard let slug = attributes?.keys.first else { return nil }
        return MagazineTitle(
            slug: slug,
            name: data?.title ?? slug,
            coverURL: src.flatMap(URL.init(string:)),
            latestIssueID: id,
            latestPublished: published.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }
}

/// 中身を使わないJSONの値
struct IgnoredJSON: Decodable {
    init(from decoder: Decoder) throws {}
}

// MARK: - アプリ内で使う作品情報

struct ComicSummary: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    let author: String?
    let authorSlug: String?
    let magazine: String?
    let coverURL: URL?
    let likesCount: Int?
    var magazineSlug: String? = nil
    var isKomifloOriginal: Bool? = nil

    /// 表紙画像のURLは署名付きで期限（exp）があるので、切れたら取り直す
    var isCoverExpired: Bool {
        guard let coverURL,
              let exp = URLComponents(url: coverURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "exp" })?.value
                .flatMap(TimeInterval.init) else {
            return false
        }
        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(10 * 60)
    }
}

extension KFContent {
    var coverURL: URL? {
        coverFilename.flatMap { filename -> URL? in
            let base = (cdnThumbs?.isEmpty == false ? cdnThumbs! : "https://t.komiflo.com")
            return URL(string: "\(base)/376_mobile_large_2x/\(filename)")
        }
    }

    var summary: ComicSummary {
        let authorNames = artists.map(\.name).filter { !$0.isEmpty }
        return ComicSummary(
            id: id,
            title: title ?? "",
            author: authorNames.isEmpty ? nil : authorNames.joined(separator: "、"),
            authorSlug: artists.first?.slug,
            magazine: magazine,
            coverURL: coverURL,
            likesCount: likesCount,
            magazineSlug: magazineSlug,
            isKomifloOriginal: isKomifloOriginal
        )
    }

    /// 号の中の作品から「表紙」を除いたもの
    var chapters: [KFContent] {
        children.filter { !($0.title ?? "").contains("表紙") }
    }

    /// 号の表紙（号そのものには表紙画像が無いので、収録作品の「表紙」を使う）
    var issueCoverURL: URL? {
        (children.first { ($0.title ?? "").contains("表紙") && $0.coverFilename != nil }
            ?? children.first { $0.coverFilename != nil })?.coverURL
    }
}
