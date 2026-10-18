import Foundation

/// Komifloアカウントの閲覧履歴・ブックマーク・いいねを読み込んで保持する
@MainActor
final class LibraryStore: ObservableObject {
    /// 番号で切り替える一覧（タグのページと同じく、1ページずつ取得してページごとに保持する）
    struct PagedFeed {
        var pages: [Int: [ComicSummary]] = [:]
        var pageCount: Int?
        var total: Int?
        /// 最後に見たページ（0始まり。上の切り替えで戻ってきたときにこのページを出す）
        var page = 0
        var loading: Set<Int> = []
        var errors: [Int: String] = [:]

        var current: [ComicSummary]? { pages[page] }
        var error: String? { errors[page] }
    }

    enum Kind {
        case history, bookmarks, likes

        /// session/user の reading_lists の list_type
        var listType: String? {
            switch self {
            case .history: return "history"
            case .bookmarks: return "reading"
            case .likes: return nil
            }
        }
    }

    /// ブックマークの「全て / 既読 / 未読」（公式の filter=read|unread）
    enum BookmarkFilter: String, CaseIterable, Identifiable {
        case all, read, unread
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "全て"
            case .read: return "既読"
            case .unread: return "未読"
            }
        }
        var apiValue: String? { self == .all ? nil : rawValue }
    }

    /// 新しい順・古い順（閲覧履歴・ブックマーク・いいねで共通）
    enum ListOrder: String, CaseIterable, Identifiable {
        case newest, oldest
        var id: String { rawValue }
        var label: String { self == .newest ? "新しい順" : "古い順" }
    }

    /// 一覧を区別する条件。並び順・絞り込み・月ごとに、取得したページを別々に保つ
    struct ListKey: Hashable {
        let kind: Kind
        let order: ListOrder
        var filter: BookmarkFilter?
        var month: Date?
    }

    @Published private(set) var lists: [ListKey: PagedFeed] = [:]
    @Published private(set) var bookmarkFilter: BookmarkFilter =
        BookmarkFilter(rawValue: UserDefaults.standard.string(forKey: "bookmarkFilter") ?? "") ?? .all
    /// 各一覧で最後に選んだ並び順（上の切り替えで戻ってきたときに使う）
    @Published private(set) var orders: [Kind: ListOrder] = [:]
    /// 閲覧履歴の月別の絞り込み（nil なら全て）。月の1日で表す
    @Published private(set) var historyMonth: Date?
    /// 閲覧履歴がある月（新しい順）
    @Published private(set) var historyMonths: [Date] = []
    /// ★・♥の表示に使う
    @Published private(set) var bookmarkedIDs: Set<Int> = []
    @Published private(set) var likedIDs: Set<Int> = []

    let api: KomifloAPI

    private var user: KFUser?
    /// いいねした作品のID（公式はIDだけを新しい順に返す）
    private var allLikedIDs: [Int]?
    private var markRevision = 0
    private var summaryCache: [Int: ComicSummary] = [:]
    private var magazineCacheReads: Set<Int> = []
    private var magazineIdentities: [Int: MagazineIdentity] = [:]
    private var magazineTasks: [Int: Task<ComicSummary?, Never>] = [:]
    private let magazineRequests = MagazineMetadataRequests()
    /// 公式の1ページの件数
    static let pageSize = 20
    private var pageSize: Int { Self.pageSize }
    private var listGeneration: [ListKey: UUID] = [:]
    private var lastPrepared: [ListKey: Date] = [:]
    private var preparing: [PreparingPage: Task<Void, Never>] = [:]

    init(api: KomifloAPI) {
        self.api = api
    }

    // MARK: - 一覧（ページ切り替え）

    /// 今の絞り込み・月で、その並び順の一覧を指す
    func key(_ kind: Kind, order: ListOrder? = nil) -> ListKey {
        let order = order ?? self.order(kind)
        switch kind {
        case .history: return ListKey(kind: kind, order: order, month: historyMonth)
        case .bookmarks: return ListKey(kind: kind, order: order, filter: bookmarkFilter)
        case .likes: return ListKey(kind: kind, order: order)
        }
    }

    func list(_ key: ListKey) -> PagedFeed { lists[key] ?? PagedFeed() }

    /// そのページの最後の作品が、一覧の何作品目か（ページの下の「20/100作品」に使う）
    func shownCount(_ key: ListKey, page: Int) -> Int? {
        let feed = list(key)
        guard let total = feed.total, let items = feed.pages[page] else { return nil }
        // 閲覧履歴・ブックマークの古い順は公式の最後のページ（件数が少ない）から始まるので、後ろから数える
        if key.order == .oldest, key.kind != .likes, let count = feed.pageCount {
            return max(0, min(total, total - (count - 1 - page) * pageSize))
        }
        return min(total, page * pageSize + items.count)
    }

    func order(_ kind: Kind) -> ListOrder { orders[kind] ?? .newest }

    /// 並び順を変えたときは、同じページ番号を見せる（新しい順と古い順は同じ一覧なので、ページ数も引き継ぐ）
    func setOrder(_ order: ListOrder, for kind: Kind) {
        guard orders[kind] != order else { return }
        let previous = list(key(kind))
        orders[kind] = order
        update(key(kind)) { feed in
            if feed.pageCount == nil { feed.pageCount = previous.pageCount }
            feed.page = min(previous.page, max(0, (feed.pageCount ?? previous.page + 1) - 1))
        }
    }

    private func update(_ key: ListKey, _ change: (inout PagedFeed) -> Void) {
        var feed = lists[key] ?? PagedFeed()
        change(&feed)
        lists[key] = feed
    }

    private struct PreparingPage: Hashable {
        let key: ListKey
        let page: Int
    }

    /// ページを用意する（省略時は最後に見たページ）。まだ無ければ保存分をすぐ出してから公式から取り直す。
    /// 取得済みなら、refreshLoaded のときだけ取り直す（throttled なら一覧ごとに30秒に1回まで）。
    /// 先読みと表示時の更新は同じ処理を待ち、タブ移動によるキャンセルでも中断しない
    func prepare(_ key: ListKey, page: Int? = nil, refreshLoaded: Bool = true, throttled: Bool = true) async {
        let page = page ?? list(key).page
        let preparingPage = PreparingPage(key: key, page: page)
        if let running = preparing[preparingPage] {
            await running.value
            return
        }
        let loaded = list(key).pages[page] != nil
        guard !loaded || refreshLoaded else { return }
        if loaded, throttled, let last = lastPrepared[key], Date().timeIntervalSince(last) < 30 { return }
        let task = Task {
            defer { preparing[preparingPage] = nil }
            await loadPage(key, page: page, force: loaded)
            if list(key).errors[page] == nil { lastPrepared[key] = Date() }
        }
        preparing[preparingPage] = task
        await task.value
    }

    private var preparingFollows: Task<Void, Never>?

    func prepareFollows() async {
        if let running = preparingFollows {
            await running.value
            return
        }
        guard !hasLoadedFollows else { return }
        let task = Task {
            defer { preparingFollows = nil }
            await restoreFollowsFromCache()
            await loadFollows()
        }
        preparingFollows = task
        await task.value
    }

    /// 表示するページを変えたとき（スワイプ・ページ番号）。最後に見たページとして覚え、未取得なら取得する
    func selectPage(_ page: Int, for key: ListKey) async {
        guard page >= 0, page != list(key).page else { return }
        update(key) { $0.page = page }
        await loadPage(key, page: page, force: false)
    }

    /// 取得済みのページと件数を捨てて、表示中のページから取り直す（読み込めなかったときの再読み込み）
    func reload(_ key: ListKey) async {
        listGeneration[key] = UUID()
        let page = list(key).page
        lists[key] = PagedFeed(page: page)
        await loadPage(key, page: page, force: true)
    }

    private struct PageResult {
        let items: [ComicSummary]
        let pageCount: Int
        let total: Int?
    }

    private func loadPage(_ key: ListKey, page: Int, force: Bool) async {
        let known = list(key)
        guard !known.loading.contains(page), force || known.pages[page] == nil else { return }
        let ticket = listGeneration[key] ?? UUID()
        listGeneration[key] = ticket
        let revision = markRevision
        update(key) {
            $0.loading.insert(page)
            $0.errors[page] = nil
        }
        defer {
            if listGeneration[key] == ticket { update(key) { $0.loading.remove(page) } }
        }
        // 保存してある前回の応答で先に出す（いいねは作品ごとの取得になるので対象外）
        if known.pages[page] == nil, key.kind != .likes,
           let cached = try? await APICache.fromCache({
               try await fetchPage(key, page: page, pageCount: known.pageCount)
           }) {
            guard listGeneration[key] == ticket else { return }
            apply(cached, to: key, page: page, revision: revision)
        }
        do {
            // 取り直すときは件数も数え直す（古い順のページの位置が変わるため）
            let fresh = try await fetchPage(key, page: page, pageCount: force ? nil : list(key).pageCount)
            guard listGeneration[key] == ticket else { return }
            apply(fresh, to: key, page: page, revision: revision)
        } catch {
            guard listGeneration[key] == ticket, !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            // 前回の内容が出ていれば、取り直しに失敗してもそのまま
            update(key) { if $0.pages[page] == nil { $0.errors[page] = error.localizedDescription } }
        }
    }

    private func apply(_ result: PageResult, to key: ListKey, page: Int, revision: Int) {
        result.items.forEach { summaryCache[$0.id] = $0 }
        if key.kind == .bookmarks, revision == markRevision {
            bookmarkedIDs.formUnion(result.items.map(\.id))
        }
        update(key) { feed in
            if feed.pageCount != result.pageCount {
                // ページ数が変わったら、ほかのページの取得済みの内容は位置がずれるので捨てる
                feed.pages = feed.pages.filter { $0.key == page }
            }
            feed.pages[page] = result.items
            feed.pageCount = result.pageCount
            feed.total = result.total ?? feed.total
            feed.errors[page] = nil
            if feed.page >= result.pageCount { feed.page = max(0, result.pageCount - 1) }
        }
    }

    /// 公式サイトと同じ条件で1ページ読む。古い順は、先頭ページの件数情報から最後のページを求めて逆向きに読む（全件は取らない）
    private func fetchPage(_ key: ListKey, page: Int, pageCount: Int?) async throws -> PageResult {
        if key.kind == .likes { return try await likesPage(key, page: page, refreshIDs: pageCount == nil) }
        let user = try await currentUser(forceReload: false)
        guard let listID = user.readingLists?.first(where: { $0.listType == key.kind.listType })?.id else {
            return PageResult(items: [], pageCount: 1, total: 0)
        }
        func fetch(_ index: Int) async throws -> KFReadingListResponse {
            if key.kind == .bookmarks {
                return try await api.readingList(id: listID, page: index, filter: key.filter?.apiValue)
            }
            let end = key.month.map {
                Calendar(identifier: .gregorian).date(byAdding: DateComponents(month: 1, day: -1), to: $0) ?? $0
            }
            return try await api.readingList(id: listID, page: index, startDate: key.month, endDate: end)
        }
        func items(_ response: KFReadingListResponse) -> [ComicSummary] {
            (response.results?.contents ?? []).map(\.summary)
        }
        guard key.order == .oldest else {
            let response = try await fetch(page)
            return PageResult(items: items(response), pageCount: max(1, response.totalPages ?? 1), total: response.total)
        }
        var first: KFReadingListResponse?
        var count = pageCount
        if count == nil {
            first = try await fetch(0)
            count = max(1, first?.totalPages ?? 1)
        }
        let total = count ?? 1
        guard page < total else { return PageResult(items: [], pageCount: total, total: first?.total) }
        let index = total - 1 - page
        let response: KFReadingListResponse
        if index == 0, let first { response = first } else { response = try await fetch(index) }
        return PageResult(items: items(response).reversed(), pageCount: total, total: response.total ?? first?.total)
    }

    /// いいねはIDしか返らないので、ページの分だけ作品情報を取りに行く
    private func likesPage(_ key: ListKey, page: Int, refreshIDs: Bool) async throws -> PageResult {
        let ids: [Int]
        if !refreshIDs, page != 0, let known = allLikedIDs {
            ids = known
        } else {
            let revision = markRevision
            let user = try await currentUser(forceReload: false)
            ids = try await api.likedIDs(userID: user.id)
            allLikedIDs = ids
            if revision == markRevision { likedIDs = Set(ids) }
        }
        let ordered = key.order == .newest ? ids : Array(ids.reversed())
        let pageCount = max(1, (ordered.count + pageSize - 1) / pageSize)
        let pageIDs = Array(ordered.dropFirst(page * pageSize).prefix(pageSize))
        return PageResult(items: await summaries(ids: pageIDs), pageCount: pageCount, total: ids.count)
    }

    /// ★・♥を変えたとき。表示中の一覧はそのまま（外した作品もすぐ戻せる）にして、次に表示したときに取り直す
    private func listsChanged(_ kind: Kind) {
        for key in lists.keys where key.kind == kind { lastPrepared[key] = nil }
        if kind == .likes { allLikedIDs = nil }
    }

    // MARK: - 絞り込み・月

    func setBookmarkFilter(_ filter: BookmarkFilter) {
        guard filter != bookmarkFilter else { return }
        bookmarkFilter = filter
        UserDefaults.standard.set(filter.rawValue, forKey: "bookmarkFilter")
    }

    func setHistoryMonth(_ month: Date?) {
        guard month != historyMonth else { return }
        historyMonth = month
    }

    /// 閲覧履歴がある月の一覧（公式と同じく、最新の月から最古の月まで1か月ずつ）
    func loadHistoryMonths() async {
        guard let range = try? await api.historyRange(),
              let newest = range.toDate,
              let oldest = range.fromDate else {
            return
        }
        let calendar = Calendar(identifier: .gregorian)
        guard var month = calendar.date(from: calendar.dateComponents([.year, .month], from: newest)) else { return }
        let oldestMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: oldest)) ?? oldest
        var months: [Date] = []
        while month >= oldestMonth, months.count < 120 {
            months.append(month)
            guard let previous = calendar.date(byAdding: .month, value: -1, to: month) else { break }
            month = previous
        }
        historyMonths = months
    }

    /// ★・♥の表示用に、いいね済みIDとブックマーク全件を読み込む
    func refreshMarks() async {
        await refreshLikedIDs()
        await refreshBookmarkedIDs()
    }

    /// いいねの表示だけを更新する画面では、ブックマーク全件の取得を伴わせない。
    func refreshLikedIDs() async {
        let revision = markRevision
        if let user = try? await currentUser(forceReload: false),
           let ids = try? await api.likedIDs(userID: user.id), revision == markRevision {
            likedIDs = Set(ids)
        }
    }

    /// ★の表示用に、ブックマークの全件のIDを取る（一覧の絞り込み・並び順とは関係なく）
    private var isRefreshingBookmarkIDs = false

    private func refreshBookmarkedIDs() async {
        let revision = markRevision
        guard !isRefreshingBookmarkIDs,
              let user = try? await currentUser(forceReload: false),
              let listID = user.readingLists?.first(where: { $0.listType == "reading" })?.id else {
            return
        }
        isRefreshingBookmarkIDs = true
        defer { isRefreshingBookmarkIDs = false }
        var ids: Set<Int> = []
        var page = 0
        while page < 200 {
            guard let response = try? await api.readingList(id: listID, page: page) else { return }
            let contents = response.results?.contents ?? []
            contents.forEach { summaryCache[$0.id] = $0.summary }
            ids.formUnion(contents.map(\.id))
            page += 1
            if contents.isEmpty || page >= (response.totalPages ?? 0) { break }
        }
        if revision == markRevision { bookmarkedIDs = ids }
    }

    // MARK: - ★・♥の切り替え

    /// 失敗したときに画面に出すメッセージ
    @Published var actionError: String?
    @Published private(set) var pendingIDs: Set<Int> = []

    func toggleBookmark(_ comicID: Int) async {
        guard !pendingIDs.contains(comicID) else { return }
        markRevision += 1
        let newValue = !bookmarkedIDs.contains(comicID)
        // 先に表示を切り替え、失敗したら戻す
        setMark(&bookmarkedIDs, comicID, newValue)
        pendingIDs.insert(comicID)
        defer { pendingIDs.remove(comicID) }
        do {
            let user = try await currentUser(forceReload: false)
            guard let listID = user.readingLists?.first(where: { $0.listType == "reading" })?.id else {
                throw KomifloAPIError.invalidResponse
            }
            try await api.setBookmarked(newValue, contentID: comicID, readingListID: listID)
            listsChanged(.bookmarks)
        } catch {
            setMark(&bookmarkedIDs, comicID, !newValue)
            actionError = "ブックマークを変更できませんでした。\n\(error.localizedDescription)"
        }
    }

    /// 公式のビューアでいいねの状態が変わったときに、アプリが覚えている「いいね済み」を合わせる（通信はしない）
    func noteLiked(_ comicID: Int, _ liked: Bool) {
        guard !pendingIDs.contains(comicID) else { return }
        guard likedIDs.contains(comicID) != liked else { return }
        markRevision += 1
        if liked { likedIDs.insert(comicID) } else { likedIDs.remove(comicID) }
        listsChanged(.likes)
    }

    /// 公式のビューアでリーディングリストの状態が変わったときに、アプリが覚えている「ブックマーク済み」を合わせる（通信はしない）
    func noteBookmarked(_ comicID: Int, _ bookmarked: Bool) {
        guard !pendingIDs.contains(comicID) else { return }
        guard bookmarkedIDs.contains(comicID) != bookmarked else { return }
        markRevision += 1
        if bookmarked { bookmarkedIDs.insert(comicID) } else { bookmarkedIDs.remove(comicID) }
        listsChanged(.bookmarks)
    }

    func toggleLike(_ comicID: Int) async {
        guard !pendingIDs.contains(comicID) else { return }
        markRevision += 1
        let newValue = !likedIDs.contains(comicID)
        setMark(&likedIDs, comicID, newValue)
        pendingIDs.insert(comicID)
        defer { pendingIDs.remove(comicID) }
        do {
            let user = try await currentUser(forceReload: false)
            try await api.setLiked(newValue, contentID: comicID, userID: user.id)
            listsChanged(.likes)
        } catch {
            setMark(&likedIDs, comicID, !newValue)
            actionError = "いいねを変更できませんでした。\n\(error.localizedDescription)"
        }
    }

    private func setMark(_ set: inout Set<Int>, _ id: Int, _ on: Bool) {
        if on { set.insert(id) } else { set.remove(id) }
    }

    // MARK: - フォロー（作家・タグ）

    /// フォローしている作家（新着のある作家が先、あとは読み仮名順）
    @Published private(set) var followedArtists: [KFAttribute] = []
    /// フォローしているタグ
    @Published private(set) var followedTags: [KFAttribute] = []
    /// フォロー中の作家・タグのID（フォローボタンの表示用）
    @Published private(set) var followedIDs: Set<Int> = []
    @Published private(set) var hasLoadedFollows = false
    @Published private(set) var followsError: String?

    /// 保存してある前回のフォロー一覧をすぐ出す（通信しない。保存が無ければ何もしない）
    func restoreFollowsFromCache() async {
        guard !hasLoadedFollows,
              let user = try? await APICache.fromCache({ try await currentUser(forceReload: false) }),
              let follows = try? await APICache.fromCache({ try await api.follows(userID: user.id) }) else { return }
        applyFollows(follows)
        hasLoadedFollows = true
    }

    private func applyFollows(_ follows: [KFAttribute]) {
        let artists = follows
            .filter { $0.parentID == KFAttribute.artistsParentID }
            .sorted {
                if ($0.newContentCount > 0) != ($1.newContentCount > 0) { return $0.newContentCount > 0 }
                return ($0.nameRead ?? $0.name) < ($1.nameRead ?? $1.name)
            }
        let tags = follows.filter { $0.parentID == KFAttribute.tagsParentID }
        let ids = Set(follows.map(\.id))
        // 変わっていなければ差し替えない（画面を作り直さない）
        if artists.map(\.id) != followedArtists.map(\.id)
            || artists.map(\.newContentCount) != followedArtists.map(\.newContentCount) {
            followedArtists = artists
        }
        if tags.map(\.id) != followedTags.map(\.id) { followedTags = tags }
        if ids != followedIDs { followedIDs = ids }
    }

    func loadFollows() async {
        do {
            let user = try await currentUser(forceReload: false)
            let follows = try await api.follows(userID: user.id)
            applyFollows(follows)
            if followsError != nil { followsError = nil }
        } catch {
            // 前回の一覧が出ていれば、取り直しに失敗してもそのまま
            if followedArtists.isEmpty, followedTags.isEmpty {
                followsError = error.localizedDescription
            }
        }
        hasLoadedFollows = true
    }

    func toggleFollow(attributeID: Int) async {
        guard !pendingIDs.contains(-attributeID) else { return }
        let newValue = !followedIDs.contains(attributeID)
        setMark(&followedIDs, attributeID, newValue)
        // 作品IDと重ならないよう、フォローの処理中は負の値で管理する
        pendingIDs.insert(-attributeID)
        defer { pendingIDs.remove(-attributeID) }
        do {
            let user = try await currentUser(forceReload: false)
            try await api.setFollowing(newValue, attributeID: attributeID, userID: user.id)
            await loadFollows()
        } catch {
            setMark(&followedIDs, attributeID, !newValue)
            actionError = "フォローを変更できませんでした。\n\(error.localizedDescription)"
        }
    }

    /// 特集のいいね。成功したらtrue、失敗したら知らせてfalse（表示を戻すのは呼び出し側）
    func setReadingListLiked(_ liked: Bool, readingListID: Int) async -> Bool {
        do {
            let user = try await currentUser(forceReload: false)
            try await api.setReadingListLiked(liked, readingListID: readingListID, userID: user.id)
            return true
        } catch {
            actionError = "いいねを変更できませんでした。\n\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 作家画像

    /// 作家の帯の画像（フォロー一覧のデータには画像が入っていないので、作家ごとに取って覚えておく）
    /// 作家の帯の画像。画面全体を作り直さないよう、変わっても知らせない（各行が自分で受け取る）
    private(set) var artistBanners: [Int: URL] = [:]
    private var artistBannerLoads: [Int: Task<URL?, Never>] = [:]

    /// 作家の帯の画像を取る（同じ作家は1回だけ問い合わせる）
    func artistBanner(id: Int) async -> URL? {
        if let cached = artistBanners[id] { return cached }
        let task = artistBannerLoads[id] ?? Task { [api] in try? await api.attributeInfo(id: id).bannerURL }
        artistBannerLoads[id] = task
        let url = await task.value
        if let url { artistBanners[id] = url }
        return url
    }

    // MARK: - マガジン

    /// 号に収録された作品。端末内にも保存して、アプリを起動し直してもマガジンラックの表紙がすぐ出るようにする
    private lazy var issueComicsCache: [Int: [ComicSummary]] = Self.loadIssueComics()
    private var issueLoads: [Int: Task<[ComicSummary]?, Never>] = [:]
    private var issueSaveTask: Task<Void, Never>?

    private static var issueComicsFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("IssueComics.json")
    }

    private static func loadIssueComics() -> [Int: [ComicSummary]] {
        guard let data = try? Data(contentsOf: issueComicsFile),
              let saved = try? JSONDecoder().decode([Int: [ComicSummary]].self, from: data) else { return [:] }
        return saved
    }

    /// 書き込みは少しまとめてから裏で行う（スクロール中に止まらないように）
    private func saveIssueComics() {
        issueSaveTask?.cancel()
        let snapshot = issueComicsCache
        let url = Self.issueComicsFile
        issueSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 一度取った号の中身（期限切れでもそのまま返す。画面を作るときに待たずに表紙を出すのに使う）
    func cachedIssueComics(issueID: Int) -> [ComicSummary]? {
        issueComicsCache[issueID]
    }

    /// 号に収録された作品（号の表紙と中身の一覧で共用するのでキャッシュする）
    func issueComics(issueID: Int) async -> [ComicSummary]? {
        if let cached = issueComicsCache[issueID],
           !cached.contains(where: \.isCoverExpired) {
            return cached
        }
        if let running = issueLoads[issueID] { return await running.value }
        let task = Task { @MainActor [api] () -> [ComicSummary]? in
            guard let detail = try? await api.content(id: issueID) else { return nil }
            return detail.children.map(\.summary)
        }
        issueLoads[issueID] = task
        let comics = await task.value
        issueLoads[issueID] = nil
        if let comics {
            issueComicsCache[issueID] = comics
            saveIssueComics()
        }
        return comics
    }

    /// 号の表紙。号そのものには表紙画像が無いので、収録作品の「表紙」を使う
    func issueCover(issueID: Int) async -> URL? {
        guard let comics = await issueComics(issueID: issueID) else { return nil }
        return Self.cover(of: comics)
    }

    /// 一度調べた号の表紙（画面を作るときに待たずに使う）
    func cachedIssueCover(issueID: Int) -> URL? {
        issueComicsCache[issueID].flatMap(Self.cover(of:))
    }

    private static func cover(of comics: [ComicSummary]) -> URL? {
        (comics.first { $0.title.contains("表紙") && $0.coverURL != nil }
            ?? comics.first { $0.coverURL != nil })?.coverURL
    }

    // MARK: - 作品情報

    /// 一度取ったことのある作品の情報（待たずにすぐ返す）。表紙の住所の期限が切れているときは nil
    func cachedComic(id: Int) -> ComicSummary? {
        guard let cached = summaryCache[id], !cached.isCoverExpired else { return nil }
        return cached
    }

    func comic(id: Int) async -> ComicSummary? {
        if let cached = summaryCache[id], !cached.isCoverExpired {
            return cached
        }
        guard let summary = try? await api.content(id: id).summary else { return nil }
        summaryCache[id] = summary
        return summary
    }

    /// 表示を作る時点で識別結果を渡し、通信を待たずにロゴを出す。
    func cachedComicMagazine(id: Int) -> MagazineIdentity? {
        if summaryCache[id]?.isKomifloOriginal == true { return .original }
        if let identity = magazineIdentities[id] { return identity }
        guard magazineCacheReads.insert(id).inserted,
              let identity = MagazineIdentityCache.read(id: id) else { return nil }
        magazineIdentities[id] = identity
        return identity
    }

    private func rememberMagazine(_ identity: MagazineIdentity, id: Int) async {
        guard magazineIdentities[id] != identity else { return }
        magazineIdentities[id] = identity
        magazineCacheReads.insert(id)
        await MagazineIdentityCache.store(identity, id: id)
    }

    /// 簡略一覧には収録号がない。表示対象だけ調べ、重複要求と同時通信を抑える。
    func comicMagazine(id: Int) async -> MagazineIdentity? {
        if summaryCache[id]?.isKomifloOriginal == true {
            await rememberMagazine(.original, id: id)
            return .original
        }
        if let cached = summaryCache[id], cached.isKomifloOriginal != nil,
           let identity = MagazineIdentity.display(comic: cached) {
            await rememberMagazine(identity, id: id)
            return identity
        }
        if let identity = cachedComicMagazine(id: id) { return identity }
        let task: Task<ComicSummary?, Never>
        if let running = magazineTasks[id] {
            task = running
        } else {
            task = Task { [api, magazineRequests] in
                guard !Task.isCancelled else { return nil }
                if let cached = try? await APICache.fromCache({ try await api.content(id: id) }) {
                    return cached.summary
                }
                await magazineRequests.acquire()
                let summary = try? await api.content(id: id).summary
                await magazineRequests.release()
                return summary
            }
            magazineTasks[id] = task
        }
        let summary = await task.value
        magazineTasks[id] = nil
        guard let summary else { return nil }
        summaryCache[id] = summary
        let identity = MagazineIdentity.display(comic: summary) ?? .unavailable
        await rememberMagazine(identity, id: id)
        return identity
    }

    func summaries(ids: [Int]) async -> [ComicSummary] {
        var results: [Int: ComicSummary] = [:]
        await withTaskGroup(of: ComicSummary?.self) { group in
            for id in ids {
                group.addTask { await self.comic(id: id) }
            }
            for await summary in group {
                if let summary { results[summary.id] = summary }
            }
        }
        // 取得できなかった作品も、IDだけの行として残す
        return ids.map { results[$0] ?? ComicSummary.placeholder(id: $0) }
    }

    private func currentUser(forceReload: Bool) async throws -> KFUser {
        if let user, !forceReload { return user }
        let user = try await api.currentUser()
        self.user = user
        return user
    }
}

extension ComicSummary {
    static func placeholder(id: Int) -> ComicSummary {
        ComicSummary(
            id: id,
            title: "",
            author: nil,
            authorSlug: nil,
            magazine: nil,
            coverURL: nil,
            likesCount: nil
        )
    }


}
