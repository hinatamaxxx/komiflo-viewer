import SwiftUI

/// 下のタブの「マガジン」：雑誌一覧（雑誌の表紙の本棚）と、公式のマガジンラック（新作 / 26.9 / 26.8 …）。
/// 切り替えの並びと同じ順番で、左右スワイプでも1ページずつ切り替えられる
struct MagazineTabView: View {
    /// 雑誌一覧（ロゴ） / 雑誌一覧（表紙） / 新作 / 26.9 / …
    /// 雑誌一覧の2つの表示も同じ並びのページにして、ページの中と外で横スワイプがぶつからないようにする
    enum Page: Hashable {
        case logos, covers, latest, month(Date)
    }

    let library: LibraryStore

    /// 表示中のページ（横スクロールの位置と結び付ける）
    @State private var tabProgress = PagerProgress()
    @State private var page: Page? = .latest
    @State private var months: [Date] = []
    @State private var didLoadMonths = false
    /// 読み込んだ号の一覧（スワイプで戻ったときに読み直さない）
    @State private var cache = IssueListCache()
    /// 切り替えを画面の下に出す（アプリ設定で共通。既定は上）
    @AppStorage(ControlsPosition.key) private var controlsAtBottom = false

    private var pages: [Page] {
        [.logos, .covers, .latest] + months.filter { !Calendar.current.isDate($0, equalTo: Date(), toGranularity: .month) }.map { .month($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !controlsAtBottom {
                chips.padding(.vertical, 8)
            }
            pager
        }
        .safeAreaInset(edge: .bottom) {
            if controlsAtBottom {
                BottomControlBar { chips }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            guard months.isEmpty else { return }
            // 前回保存した月の一覧ですぐ表示し、裏で公式から取り直して、変わっていれば差し替える
            let saved = await APICache.fromCache { await Self.loadMonths(library: library) }
            if !saved.isEmpty {
                months = saved
                didLoadMonths = true
            }
            let fresh = await Self.loadMonths(library: library)
            if !fresh.isEmpty, fresh != months { months = fresh }
            didLoadMonths = true
        }
    }

    /// ページ送り（左右スワイプ）。表示中にページ数が変わると表示が半分ずれることがあるので、
    /// 月の一覧が届いてから（届かなかったときはそのまま）一度だけ作り、あとからページを増やさない
    @ViewBuilder
    private var pager: some View {
        if didLoadMonths {
            PagedView(items: pages, selection: Binding(get: { page ?? .latest }, set: { page = $0 }),
                      commitsSelectionOnIdle: true, progress: tabProgress) { item in
                pageContent(item)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func pageContent(_ item: Page) -> some View {
        switch item {
        case .logos:
            MagazineShelfView(library: library, style: .logo)
        case .covers:
            MagazineShelfView(library: library, style: .cover)
        case .latest:
            IssueMonthPage(month: nil, library: library, cache: cache)
        case .month(let month):
            IssueMonthPage(month: month, library: library, cache: cache)
        }
    }

    /// 雑誌一覧 / 新作 / 26.9 / 26.8 …（選んでいるものが見えるように自動で横にずらす）
    private var chips: some View {
        PagerTabs(items: pages, selection: Binding(get: { page ?? .latest }, set: { page = $0 }),
                  progress: tabProgress, scrolls: true, font: .footnote.weight(.semibold), title: Self.title)
    }

    private static func title(_ page: Page) -> String {
        switch page {
        case .logos: return "ロゴ"
        case .covers: return "表紙"
        case .latest: return "新作"
        case .month(let month):
            let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: month)
            return "\((parts.year ?? 0) % 100).\(parts.month ?? 0)"
        }
    }

    private static func loadMonths(library: LibraryStore) async -> [Date] {
        guard let range = try? await library.api.magazinesRange(),
              let newest = range.toDate, let oldest = range.fromDate else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        // 号が出た日の一覧が届いていれば、号が出た月だけにする（何も配信されていない月は出さない）
        if let list = range.list, !list.isEmpty {
            let formatter = ISO8601DateFormatter()
            let months = Set(list.compactMap { formatter.date(from: $0) }.compactMap {
                calendar.date(from: calendar.dateComponents([.year, .month], from: $0))
            })
            if !months.isEmpty {
                return Array(months.sorted(by: >).prefix(120))
            }
        }
        guard var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: newest)) else { return [] }
        let oldestMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: oldest)) ?? oldest
        var result: [Date] = []
        while cursor >= oldestMonth, result.count < 120 {
            result.append(cursor)
            guard let previous = calendar.date(byAdding: .month, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return result
    }
}

/// 月ごとの号の一覧の置き場所（キー nil は「新作」）
final class IssueListCache {
    var issues: [Date?: [KFContent]] = [:]
}

/// マガジンラックの1ページ（公式の /magazines と同じ作り）：号ごとに見出しと、その号の作品の表紙を横スクロールで
struct IssueMonthPage: View {
    /// nil は「新作」（公式と同じく直近3か月の号）
    let month: Date?
    let library: LibraryStore
    var cache = IssueListCache()

    @State private var issues: [KFContent]

    init(month: Date?, library: LibraryStore, cache: IssueListCache) {
        self.month = month
        self.library = library
        self.cache = cache
        // 一度読んだ月は、ページを作った瞬間から出す（スワイプで戻ったときに読み込み中の表示を出さない）
        _issues = State(initialValue: cache.issues[month] ?? [])
    }
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if issues.isEmpty, let error {
                    EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
                        .frame(height: 240)
                } else if issues.isEmpty, isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                } else if issues.isEmpty {
                    EmptyState(title: "この月の号はありません", systemImage: "books.vertical", message: "左右にスワイプして別の月を選んでください。")
                        .frame(height: 240)
                }

                ForEach(issues, id: \.id) { issue in
                    IssueShelf(issue: issue, library: library)
                }
            }
            .padding(.vertical, 12)
        }
        .task {
            if let cached = cache.issues[month] {
                issues = cached
                return
            }
            // 前回保存した号の一覧ですぐ表示し、裏で公式から取り直す
            if issues.isEmpty, let saved = try? await APICache.fromCache({ try await fetchIssues() }), !saved.isEmpty {
                issues = saved
            }
            await load()
        }
    }

    /// 公式から取り直す。表示中の一覧は消さず、号が変わったときだけ差し替える
    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let fresh = try await fetchIssues()
            if fresh.map(\.id) != issues.map(\.id) { issues = fresh }
            cache.issues[month] = fresh
        } catch {
            // 前回の一覧が出ていれば、取り直しに失敗してもそのまま
            if issues.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func fetchIssues() async throws -> [KFContent] {
        let calendar = Calendar(identifier: .gregorian)
        let loaded: [KFContent]
        if let month {
            let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: month) ?? month
            loaded = try await library.api.publishedIssues(from: month, to: end)
        } else {
            // 公式の「新作」と同じく、3か月前の月初めから
            let now = calendar.dateComponents([.year, .month], from: Date())
            let thisMonth = calendar.date(from: now) ?? Date()
            let since = calendar.date(byAdding: .month, value: -3, to: thisMonth) ?? thisMonth
            loaded = try await library.api.latestIssues(since: since)
        }
        return MagazineLineup.ordered(loaded.filter { $0.type == nil || $0.type == "volume" },
                                      slug: { $0.magazineSlug })
    }
}

/// 号1冊ぶん：見出し（タップで号のページ）と、収録作品の表紙の横スクロール
struct IssueShelf: View {
    let issue: KFContent
    let library: LibraryStore
    let magazine: MagazineIdentity?

    @State private var comics: [ComicSummary]

    init(issue: KFContent, library: LibraryStore, magazine: MagazineIdentity? = nil) {
        self.issue = issue
        self.library = library
        self.magazine = magazine ?? MagazineIdentity.resolve(slug: issue.magazineSlug, issue: issue.title)
        // 一度取った号の中身（端末内に保存してある分も）は、画面を作った瞬間から出す（読み込み中の表示を出さない）
        _comics = State(initialValue: library.cachedIssueComics(issueID: issue.id) ?? [])
    }

    var body: some View {
        Group {
            if comics.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(issue.title ?? "")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.sectionTitle)
                        .padding(.horizontal, 15)
                    Theme.bar
                        .frame(height: OfficialMetrics.cardWidth / coverAspect + 30)
                        .overlay(ProgressView())
                }
            } else {
                CoverShelf(
                    title: issue.title ?? "",
                    comics: comics,
                    library: library, showsMagazineLogo: true, magazine: magazine, magazineLogoAtBottom: true
                )
            }
        }
        .task {
            // 保存してあった分を出したまま、画像の期限が切れていれば取り直す（変わったときだけ差し替える）
            guard let fresh = await library.issueComics(issueID: issue.id) else { return }
            if fresh.map(\.id) != comics.map(\.id) || comics.contains(where: \.isCoverExpired) {
                comics = fresh
            }
        }
    }
}
