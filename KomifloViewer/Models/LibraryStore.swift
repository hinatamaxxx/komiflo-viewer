import Foundation

/// Komifloアカウントの閲覧履歴・ブックマーク・いいねを読み込んで保持する
@MainActor
final class LibraryStore: ObservableObject {
    struct Feed {
        var items: [ComicSummary] = []
        var isLoading = false
        var error: String?
        var hasMore = true
        var total: Int?
        var hasLoaded = false
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

    enum HistoryOrder: String, CaseIterable, Identifiable {
        case newest, oldest
        var id: String { rawValue }
        var label: String { self == .newest ? "新しい順" : "古い順" }

        func sourcePage(_ page: Int, totalPages: Int) -> Int {
            self == .newest ? page : max(0, totalPages - 1 - page)
        }
    }

    @Published private(set) var history = Feed()
    @Published private(set) var bookmarks = Feed()
    @Published private(set) var likes = Feed()

    @Published private(set) var bookmarkFilter: BookmarkFilter =
        BookmarkFilter(rawValue: UserDefaults.standard.string(forKey: "bookmarkFilter") ?? "") ?? .all
    @Published private(set) var historyOrder: HistoryOrder = .newest
    private var historyPageCount: Int?
    /// 同じ月の並び順ごとに、表示済みの一覧と次の取得位置を保持する。
    private struct HistorySnapshot {
        var feed: Feed
        let nextPage: Int
        let pageCount: Int?
    }
    private var historySnapshots: [HistoryOrder: HistorySnapshot] = [:]
    /// スワイプで離れた絞り込みも、一覧と続きの取得位置を保持する。
    private struct BookmarkSnapshot {
        var feed: Feed
        let nextPage: Int
        let preparedAt: Date?
    }
    private var bookmarkSnapshots: [BookmarkFilter: BookmarkSnapshot] = [:]
    /// 閲覧履歴の月別の絞り込み（nil なら全て）。月の1日で表す
    @Published private(set) var historyMonth: Date?
    /// 閲覧履歴がある月（新しい順）
    @Published private(set) var historyMonths: [Date] = []
    /// ★・♥の表示に使う
    @Published private(set) var bookmarkedIDs: Set<Int> = []
    @Published private(set) var likedIDs: Set<Int> = []

    let api: KomifloAPI

    private var user: KFUser?
    private var allLikedIDs: [Int] = []
    private var markRevision = 0
    private var summaryCache: [Int: ComicSummary] = [:]
    private var magazineCacheReads: Set<Int> = []
    private var magazineIdentities: [Int: MagazineIdentity] = [:]
    private var magazineTasks: [Int: Task<ComicSummary?, Never>] = [:]
    private let magazineRequests = MagazineMetadataRequests()
    private let pageSize = 20
    /// 次に読むページ番号。Komifloのページは0始まり（page=0 が最新の20件）
    private var nextPage: [Kind: Int] = [:]
    private var feedGeneration: [Kind: UUID] = [:]

    init(api: KomifloAPI) {
        self.api = api
    }

    func feed(_ kind: Kind) -> Feed {
        switch kind {
        case .history: return history
        case .bookmarks: return bookmarks
        case .likes: return likes
        }
    }

    /// 横スワイプの隣のページにも取得済みの一覧を渡す。表示だけでは通信しない。
    func historyFeed(for order: HistoryOrder) -> Feed {
        if order == historyOrder { return history }
        if history.hasLoaded, !history.hasMore, history.error == nil {
            var reversed = history
            reversed.items.reverse()
            reversed.isLoading = false
            return reversed
        }
        return historySnapshots[order]?.feed ?? Feed()
    }

    func bookmarkFeed(for filter: BookmarkFilter) -> Feed {
        if filter == bookmarkFilter { return bookmarks }
        return bookmarkSnapshots[filter]?.feed ?? Feed()
    }

    private func update(_ kind: Kind, _ change: (inout Feed) -> Void) {
        switch kind {
        case .history: change(&history)
        case .bookmarks: change(&bookmarks)
        case .likes: change(&likes)
        }
    }

    private var preparingFeeds: [Kind: Task<Void, Never>] = [:]
    private var lastPrepared: [Kind: Date] = [:]
    private var preparingFollows: Task<Void, Never>?

    /// 先読みと表示時の更新は同じ処理を待つ。タブ移動によるキャンセルでも先読みを中断しない。
    func prepareFeed(_ kind: Kind, refreshLoaded: Bool = true) async {
        if let running = preparingFeeds[kind] {
            await running.value
            return
        }
        guard refreshLoaded || !feed(kind).hasLoaded else { return }
        guard !feed(kind).isLoading else { return }
        if feed(kind).hasLoaded, let last = lastPrepared[kind],
           Date().timeIntervalSince(last) < 30 { return }
        let task = Task {
            defer { preparingFeeds[kind] = nil }
            if !feed(kind).hasLoaded { await restoreFromCache(kind) }
            await refreshTop(kind)
            if feed(kind).hasLoaded, feed(kind).error == nil {
                lastPrepared[kind] = Date()
            }
        }
        preparingFeeds[kind] = task
        await task.value
    }

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

    // MARK: - 読み込み

    /// 1ページ分読み込む（一覧の最後までスクロールしたとき）
    func loadMore(_ kind: Kind, reset: Bool = false) async {
        if reset {
            feedGeneration[kind] = UUID()
            update(kind) { $0 = Feed() }
            nextPage[kind] = 0
            if kind == .history {
                historyPageCount = nil
                historySnapshots.removeAll()
            }
            if kind == .bookmarks { bookmarkSnapshots.removeAll() }
            if kind == .likes { allLikedIDs = [] }
        }
        guard !feed(kind).isLoading, feed(kind).hasMore else { return }
        let ticket = feedGeneration[kind] ?? UUID()
        feedGeneration[kind] = ticket
        update(kind) {
            $0.isLoading = true
            $0.error = nil
        }
        defer {
            if feedGeneration[kind] == ticket {
                update(kind) { $0.isLoading = false }
            }
        }

        do {
            if kind == .likes {
                try await loadNextLikes(reset: reset, ticket: ticket)
            } else {
                try await loadNextReadingListPage(kind, reset: reset, ticket: ticket)
            }
        } catch {
            guard feedGeneration[kind] == ticket, !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            update(kind) {
                $0.error = error.localizedDescription
                $0.hasLoaded = true
            }
        }
    }

    /// 表示中の一覧は消さずに、最新の1ページ目だけ取り直して先頭に反映する
    /// （最近読んだ作品が上に来る。読み込み中も今の一覧を出したままにできる）
    func refreshTop(_ kind: Kind) async {
        if kind == .bookmarks {
            guard !bookmarks.isLoading else { return }
            bookmarkSnapshots.removeAll()
        }
        // 閲覧や手動更新で順番が変わり得るため、別の並び順も次回取り直す。
        if kind == .history {
            guard !history.isLoading else { return }
            historySnapshots.removeAll()
        }
        let ticket = feedGeneration[kind]
        guard feed(kind).hasLoaded else {
            await loadMore(kind)
            return
        }
        if kind == .history, historyOrder == .oldest {
            // 閲覧で既存の履歴も移動するため、逆順は境界を取り直して継ぎ足しの混在を防ぐ。
            await loadMore(.history, reset: true)
            return
        }
        if kind == .likes {
            await refreshLikesTop()
            return
        }
        guard !feed(kind).isLoading else { return }
        do {
            let user = try await currentUser(forceReload: false)
            guard let listID = user.readingLists?.first(where: { $0.listType == kind.listType })?.id else { return }
            let response = try await readingListPage(kind, listID: listID, page: 0)
            guard feedGeneration[kind] == ticket else { return }
            let fresh = (response.results?.contents ?? []).map(\.summary)
            fresh.forEach { summaryCache[$0.id] = $0 }
            let freshIDs = Set(fresh.map(\.id))
            update(kind) { feed in
                feed.items = fresh + feed.items.filter { !freshIDs.contains($0.id) }
                feed.total = response.total ?? feed.total
                feed.error = nil
            }
        } catch {
            // 取り直しに失敗しても、今の一覧はそのまま出しておく
        }
    }

    /// 保存してある前回の一覧をすぐ出す（通信しない）。まだ読み込んでいないときだけ。
    /// 保存が無かったときは何もしない（そのあとの通常の読み込みに任せる）
    func restoreFromCache(_ kind: Kind) async {
        guard !feed(kind).hasLoaded, !feed(kind).isLoading else { return }
        await APICache.fromCache { await loadMore(kind) }
        if feed(kind).error != nil || feed(kind).items.isEmpty {
            update(kind) { $0 = Feed() }
            nextPage[kind] = 0
            if kind == .history { historyPageCount = nil }
            if kind == .likes { allLikedIDs = [] }
        }
    }

    /// いいねの一覧を、今の表示のまま取り直す（いいねが変わっていなければ何もしない）
    private func refreshLikesTop() async {
        let revision = markRevision
        let ticket = feedGeneration[.likes]
        guard let user = try? await currentUser(forceReload: false),
              let ids = try? await api.likedIDs(userID: user.id), markRevision == revision,
              feedGeneration[.likes] == ticket else { return }
        likedIDs = Set(ids)
        guard ids != allLikedIDs else { return }
        allLikedIDs = ids
        let count = max(likes.items.count, pageSize)
        let fresh = await summaries(ids: Array(ids.prefix(count)))
        guard markRevision == revision, feedGeneration[.likes] == ticket else { return }
        likes.items = fresh
        likes.total = ids.count
        likes.hasMore = fresh.count < ids.count
    }

    private func loadNextReadingListPage(_ kind: Kind, reset: Bool, ticket: UUID) async throws {
        let revision = markRevision
        let user = try await currentUser(forceReload: reset)
        guard feedGeneration[kind] == ticket else { return }
        guard let listID = user.readingLists?.first(where: { $0.listType == kind.listType })?.id else {
            update(kind) {
                $0.hasMore = false
                $0.hasLoaded = true
            }
            return
        }
        let page = nextPage[kind] ?? 0
        let response = try await readingListPage(kind, listID: listID, page: page)
        guard feedGeneration[kind] == ticket else { return }
        let newItems = (response.results?.contents ?? []).map(\.summary)
        newItems.forEach { summaryCache[$0.id] = $0 }
        if kind == .bookmarks, revision == markRevision {
            bookmarkedIDs.formUnion(newItems.map(\.id))
        }
        update(kind) { feed in
            let known = Set(feed.items.map(\.id))
            feed.items += newItems.filter { !known.contains($0.id) }
            feed.total = response.total
            feed.hasMore = page + 1 < (response.totalPages ?? 0) && !newItems.isEmpty
            feed.hasLoaded = true
        }
        nextPage[kind] = page + 1
    }

    /// 公式サイトと同じ条件で1ページ読む
    private func readingListPage(_ kind: Kind, listID: Int, page: Int) async throws -> KFReadingListResponse {
        switch kind {
        case .bookmarks:
            return try await api.readingList(
                id: listID,
                page: page,
                filter: bookmarkFilter.apiValue
            )
        case .history:
            return try await historyPage(listID: listID, page: page)
        case .likes:
            throw KomifloAPIError.invalidResponse
        }
    }

    private func historyPage(listID: Int, page: Int) async throws -> KFReadingListResponse {
        let order = historyOrder
        let month = historyMonth
        let ticket = feedGeneration[.history]
        let end = month.map {
            Calendar(identifier: .gregorian).date(byAdding: DateComponents(month: 1, day: -1), to: $0) ?? $0
        }
        func fetch(_ index: Int) async throws -> KFReadingListResponse {
            try await api.readingList(id: listID, page: index, startDate: month, endDate: end)
        }
        guard order == .oldest else { return try await fetch(page) }

        // 全件を取得せず、先頭の件数情報から最後のページを求める。
        var first: KFReadingListResponse?
        if page == 0 || historyPageCount == nil {
            first = try await fetch(0)
            guard feedGeneration[.history] == ticket else { throw CancellationError() }
            historyPageCount = max(1, first?.totalPages ?? 1)
        }
        let count = historyPageCount ?? 1
        guard page < count else {
            return KFReadingListResponse(results: .init(contents: [], name: nil), total: history.total, totalPages: count)
        }
        let index = order.sourcePage(page, totalPages: count)
        let response: KFReadingListResponse
        if index == 0, let first { response = first } else { response = try await fetch(index) }
        guard feedGeneration[.history] == ticket else { throw CancellationError() }
        return KFReadingListResponse(
            results: .init(contents: Array((response.results?.contents ?? []).reversed()), name: response.results?.name),
            total: response.total, totalPages: count)
    }

    // MARK: - 絞り込み・並び順

    func setBookmarkFilter(_ filter: BookmarkFilter) async {
        guard filter != bookmarkFilter else { return }
        if bookmarks.hasLoaded, bookmarks.error == nil {
            var saved = bookmarks
            saved.isLoading = false
            bookmarkSnapshots[bookmarkFilter] = BookmarkSnapshot(
                feed: saved, nextPage: nextPage[.bookmarks] ?? 0, preparedAt: lastPrepared[.bookmarks])
        }
        feedGeneration[.bookmarks] = UUID()
        bookmarkFilter = filter
        UserDefaults.standard.set(filter.rawValue, forKey: "bookmarkFilter")
        if let saved = bookmarkSnapshots[filter] {
            bookmarks = saved.feed
            nextPage[.bookmarks] = saved.nextPage
            lastPrepared[.bookmarks] = saved.preparedAt
        } else {
            bookmarks = Feed()
            nextPage[.bookmarks] = 0
            lastPrepared[.bookmarks] = nil
            await loadMore(.bookmarks)
            if bookmarkFilter == filter, bookmarks.hasLoaded, bookmarks.error == nil {
                lastPrepared[.bookmarks] = Date()
            }
        }
    }

    func setHistoryOrder(_ order: HistoryOrder) async {
        guard order != historyOrder else { return }
        if history.hasLoaded, history.error == nil {
            var saved = history
            saved.isLoading = false
            historySnapshots[historyOrder] = HistorySnapshot(
                feed: saved, nextPage: nextPage[.history] ?? 0, pageCount: historyPageCount)
            // 全件が揃っていれば、逆順の先頭を取得する通信も不要。
            if !saved.hasMore {
                saved.items.reverse()
                historySnapshots[order] = HistorySnapshot(
                    feed: saved, nextPage: nextPage[.history] ?? 0, pageCount: historyPageCount)
            }
        }
        feedGeneration[.history] = UUID()
        historyOrder = order
        if let saved = historySnapshots[order] {
            history = saved.feed
            nextPage[.history] = saved.nextPage
            historyPageCount = saved.pageCount
        } else {
            history = Feed()
            nextPage[.history] = 0
            historyPageCount = nil
            await loadMore(.history)
        }
    }

    func setHistoryMonth(_ month: Date?) async {
        guard month != historyMonth else { return }
        historyMonth = month
        await loadMore(.history, reset: true)
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

    private func loadNextLikes(reset: Bool, ticket: UUID) async throws {
        let revision = markRevision
        if !likes.hasLoaded || reset {
            let user = try await currentUser(forceReload: reset)
            guard feedGeneration[.likes] == ticket else { return }
            let ids = try await api.likedIDs(userID: user.id)
            guard feedGeneration[.likes] == ticket else { return }
            allLikedIDs = ids
            if revision == markRevision { likedIDs = Set(ids) }
            likes.total = allLikedIDs.count
        }
        // いいねはIDしか返らないので、20件ずつ作品情報を取りに行く
        let start = likes.items.count
        let pageIDs = Array(allLikedIDs.dropFirst(start).prefix(pageSize))
        let summaries = await summaries(ids: pageIDs)
        guard feedGeneration[.likes] == ticket else { return }
        likes.items += summaries
        likes.hasMore = start + pageIDs.count < allLikedIDs.count
        likes.hasLoaded = true
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
            bookmarkSnapshots.removeAll()
            if newValue { await prepend(comicID, to: .bookmarks) }
            bookmarks.total = bookmarks.total.map { $0 + (newValue ? 1 : -1) }
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
    }

    /// 公式のビューアでリーディングリストの状態が変わったときに、アプリが覚えている「ブックマーク済み」を合わせる（通信はしない）
    func noteBookmarked(_ comicID: Int, _ bookmarked: Bool) {
        guard !pendingIDs.contains(comicID) else { return }
        guard bookmarkedIDs.contains(comicID) != bookmarked else { return }
        bookmarkSnapshots.removeAll()
        markRevision += 1
        if bookmarked { bookmarkedIDs.insert(comicID) } else { bookmarkedIDs.remove(comicID) }
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
            if newValue {
                allLikedIDs.removeAll { $0 == comicID }
                allLikedIDs.insert(comicID, at: 0)
                await prepend(comicID, to: .likes)
            }
            likes.total = likes.total.map { $0 + (newValue ? 1 : -1) }
        } catch {
            setMark(&likedIDs, comicID, !newValue)
            actionError = "いいねを変更できませんでした。\n\(error.localizedDescription)"
        }
    }

    private func setMark(_ set: inout Set<Int>, _ id: Int, _ on: Bool) {
        if on { set.insert(id) } else { set.remove(id) }
    }

    /// 追加した作品を一覧の先頭に出す（外した作品は★♥の表示だけ変えて一覧に残し、すぐ戻せるようにする）
    private func prepend(_ comicID: Int, to kind: Kind) async {
        guard feed(kind).hasLoaded,
              !feed(kind).items.contains(where: { $0.id == comicID }),
              let summary = await comic(id: comicID) else {
            return
        }
        update(kind) { $0.items.insert(summary, at: 0) }
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
