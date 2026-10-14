import SwiftUI

/// 公式のタグリンクに付く一覧の指定。指定のない画面はAPIの順序を使う。
struct TagListingOptions: Hashable {
    var fromTop = false
    var filter: String? = nil
    var initialPage = 0
    var sort: String? = nil

    func contentPath(attributeIDs: [Int], page: Int) -> String {
        let path = attributeIDs.count == 1
            ? "/attribute/id/\(attributeIDs[0])"
            : "/attribute/ids/" + attributeIDs.map(String.init).joined(separator: "&")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&#?=")
        let suffix = filter.flatMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        return "\(path)/content?page=\(page)&filter=chapter" + (suffix.map { "+\($0)" } ?? "")
            + (sort.flatMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }.map { "&sort=\($0)" } ?? "")
    }
}

/// ホームの特別な棚。取得条件と日替わりの順序を一覧でも共用する。
enum HomeShelfKind: String, Hashable {
    case topical = "topical_including_free"
    case recent = "most-popular-recent"
    case longHits = "most-popular-longhits"

    func contentPath(attributeID: Int, page: Int, date: Date = Date(),
                     calendar: Calendar = .current, recentDays: Int = 28) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        func day(_ offset: Int) -> String {
            formatter.string(from: calendar.date(byAdding: .day, value: offset, to: date) ?? date)
        }
        let path: String
        switch self {
        case .topical:
            path = "/attribute/id/\(attributeID)/content?page_size=100&filter=chapter+-plus"
        case .recent:
            path = "/content/published?page_size=20&type=chapter&start_date=\(day(-recentDays))"
                + "&sort=-views_count&filter=chapter+-plus"
        case .longHits:
            path = "/content/published?page_size=80&type=chapter&start_date=\(day(-300))&end_date=\(day(-120))"
                + "&sort=-views_count_3month&filter=chapter+-plus&attribute_id=-241"
        }
        return path + "&page=\(page)"
    }

    func ordered<T>(_ contents: [T], attributeID: Int, date: Date = Date()) -> [T] {
        guard self != .recent else { return contents }
        var generator = DailyShuffle(seed: attributeID, date: date)
        return generator.shuffle(contents)
    }
}

/// アプリ内の画面遷移先
enum Route: Hashable {
    case comic(id: Int)
    case homeShelf(id: Int, kind: HomeShelfKind, name: String, homeComics: [ComicSummary])
    case artist(slug: String, name: String)
    case tag(id: Int, name: String, options: TagListingOptions = .init(), homeComics: [ComicSummary] = [])
    case magazine(MagazineTitle)
    case issue(id: Int, title: String)
    /// 公式の特集コレクション（/collection/<ID>）
    case collection(id: Int, title: String)
    /// ホームで表示した画像を、そのまま特集の帯にも使う。
    indirect case banner(destination: Route, imageURL: URL)
    /// slug で指定されたタグ（/category/<slug>）
    case tagSlug(slug: String, name: String, options: TagListingOptions = .init())
    /// お知らせ（/notifications）
    case notifications
    /// フォローリスト
    case follows
    /// 公式メニューのページ（右上の☰。今いる画面の上に重ねて開く）
    case officialMenu
    /// 検索のページ（左上の🔍。公式のタグ検索と同じ位置）：タグの絞り込みと作品のキーワード検索
    case search
    /// 公式メニューから開く画面（メニューの上に重ねるので、戻るでメニューに戻れる）
    case artistGallery
    case magazineRack
    case appSettings
    case bookmarks
    case history
    /// 雑誌の配信カレンダー（公式の /articles と /articles/magazine-schedule-YYMM）。slugは最初に開く月
    case deliveryCalendar(slug: String?)

    /// 下から全画面で開き、下へ引っ張って閉じる画面（縮むヘッダーの一覧と、配信カレンダー）
    var opensFullScreen: Bool {
        if case .deliveryCalendar = self { return true }
        return hasImageHeader
    }

    var hasImageHeader: Bool {
        switch self {
        case .artist, .magazine, .collection, .banner, .tag, .tagSlug, .homeShelf: return true
        default: return false
        }
    }

    /// 公式サイトのリンク先（バナーの href など）をアプリの画面に対応づける。
    /// 対応する画面が無いものは nil（ブラウザ表示で開く）
    init?(sitePath href: String, title: String = "") {
        var path = href
        if let url = URL(string: href), let host = url.host {
            guard host == "komiflo.com" || host.hasSuffix(".komiflo.com") else { return nil }
            path = url.fragment.map { $0.hasPrefix("!") ? String($0.dropFirst()) : $0 }
                ?? (url.path + (url.query.map { "?" + $0 } ?? ""))
        }
        if path.hasPrefix("#!") { path.removeFirst(2) }
        let queryItems = URLComponents(string: "https://komiflo.com" + (path.hasPrefix("/") ? path : "/" + path))?.queryItems ?? []
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let first = parts.first else { return nil }

        switch first {
        case "comics" where parts.count >= 2:
            guard let id = Int(parts[1]) else { return nil }
            self = .comic(id: id)
        case "artists" where parts.count >= 2:
            self = .artist(slug: parts[1], name: title)
        case "category" where parts.count >= 2:
            let options = TagListingOptions(
                fromTop: queryItems.first { $0.name == "fromtop" }?.value == "true",
                filter: queryItems.first { $0.name == "filter" }?.value,
                initialPage: max(0, queryItems.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 0))
            self = .tagSlug(slug: parts[1], name: title, options: options)
        case "collection" where parts.count >= 2:
            guard let id = Int(parts[1]) else { return nil }
            self = .collection(id: id, title: title)
        case "articles" where parts.count == 1:
            // 公式ホームの「配信カレンダー」バナーは記事一覧へ向いている。アプリでは配信カレンダーを開く
            self = .deliveryCalendar(slug: nil)
        case "articles" where parts[1].hasPrefix(DeliverySchedule.slugPrefix):
            self = .deliveryCalendar(slug: parts[1])
        case "magazines" where parts.count >= 2:
            // /magazines/titles/<slug> と /magazines/<slug> の両方がある
            let slug = parts[1] == "titles" && parts.count >= 3 ? parts[2] : parts[1]
            self = .magazine(MagazineTitle(
                slug: slug,
                name: title.replacingOccurrences(of: "バナー", with: ""),
                coverURL: URL(string: "https://cache.api.komiflo.com/lander/\(slug)-268.jpg"),
                latestIssueID: nil,
                latestPublished: nil
            ))
        default:
            return nil
        }
    }
}

/// 漫画を開くときの指定（ページ操作は公式ビューアに任せる）
struct ReaderRequest: Identifiable, Equatable {
    let id = UUID()
    let comicID: Int
    var title: String = ""
    /// 開いた一覧の順序。単独で開いた作品には前後の作品を補わない。
    var collection: [ComicSummary] = []
}

private struct OpenRouteKey: EnvironmentKey {
    static let defaultValue: (Route) -> Void = { _ in }
}

private struct OpenReaderKey: EnvironmentKey {
    static let defaultValue: (ReaderRequest) -> Void = { _ in }
}

private struct OpenOfficialPageKey: EnvironmentKey {
    static let defaultValue: (URL) -> Void = { _ in }
}

private struct LogoutKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// 今いるタブの画面に遷移する
    var openRoute: (Route) -> Void {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }

    /// 漫画を全画面で読む
    var openReader: (ReaderRequest) -> Void {
        get { self[OpenReaderKey.self] }
        set { self[OpenReaderKey.self] = newValue }
    }

    /// 公式のページ（ストア・アカウント設定など）をブラウザ表示で開く
    var openOfficialPage: (URL) -> Void {
        get { self[OpenOfficialPageKey.self] }
        set { self[OpenOfficialPageKey.self] = newValue }
    }

    /// ログアウトする
    var logout: () -> Void {
        get { self[LogoutKey.self] }
        set { self[LogoutKey.self] = newValue }
    }
}
