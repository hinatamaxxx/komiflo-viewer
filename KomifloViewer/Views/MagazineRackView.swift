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
    /// nil は「新作」（今月の号。前の月のページと重ならないよう、配信カレンダーと同じく月の区切りで分ける）
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
                if month == nil {
                    UpcomingDeliveries(library: library)
                }
                if issues.isEmpty, let error {
                    EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
                        .frame(height: 240)
                } else if issues.isEmpty, isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                } else if issues.isEmpty, month == nil {
                    EmptyState(title: "今月の号はまだありません", systemImage: "books.vertical", message: "左右にスワイプすると、前の月の号を見られます。")
                        .frame(height: 240)
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
        // 新作は今月の1日から。月のページと同じ取り方で、前の月の号を含めない
        let start = month ?? calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
        let loaded = try await library.api.publishedIssues(from: start, to: end)
        let lineup = MagazineLineup.ordered(loaded.filter { $0.type == nil || $0.type == "volume" },
                                            slug: { $0.magazineSlug })
        guard month == nil else { return lineup }
        // 新作は配信の新しい順（上が新しい号）。同じ日に出た号は雑誌の並び順のまま
        return lineup.enumerated().sorted { a, b in
            let left = a.element.published ?? .distantPast, right = b.element.published ?? .distantPast
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element)
    }
}

/// 新作のページの先頭に出す、配信カレンダーの今月これからの配信（今日を含む）。押すと雑誌のページへ
private struct UpcomingDeliveries: View {
    let library: LibraryStore
    @Environment(\.openRoute) private var openRoute
    @State private var schedule: DeliverySchedule?

    private struct Day: Identifiable {
        let day: Int
        let label: String
        let entries: [DeliverySchedule.Entry]
        var id: Int { day }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }()

    /// 日本時間の今日から月末までで、配信がある日
    private var days: [Day] {
        guard let schedule else { return [] }
        let today = Self.calendar.component(.day, from: Date())
        let weekdays = ["日", "月", "火", "水", "木", "金", "土"]
        return (today...31).compactMap { day in
            guard let date = Self.calendar.date(from: DateComponents(year: schedule.year, month: schedule.month, day: day)),
                  Self.calendar.component(.month, from: date) == schedule.month else { return nil }
            let weekday = Self.calendar.component(.weekday, from: date)
            let entries = schedule.entries(day: day, weekday: weekday)
            guard !entries.isEmpty else { return nil }
            let label = day == today ? "今日" : "\(schedule.month)/\(day)（\(weekdays[weekday - 1])）"
            return Day(day: day, label: label, entries: entries)
        }
    }

    var body: some View {
        Group {
            if let schedule, !days.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("今月これからの配信")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.sectionTitle)
                        Spacer()
                        Button {
                            openRoute(.deliveryCalendar(slug: schedule.slug))
                        } label: {
                            HStack(spacing: 2) {
                                Text("配信カレンダー")
                                Image(systemName: "chevron.right")
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(days) { day in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(day.label)
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(day.label == "今日" ? Theme.accent : .secondary)
                                .frame(width: 72, alignment: .leading)
                            FlowLayout(spacing: 6) {
                                ForEach(day.entries, id: \.self) { entry in
                                    Button {
                                        if let route = Route(sitePath: "/magazines/\(entry.slug)", title: entry.name) {
                                            openRoute(route)
                                        }
                                    } label: {
                                        Text(entry.name)
                                            .font(.footnote)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Theme.bar, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(Theme.bar.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 15)
            }
        }
        // 配信カレンダーと同じ記事を、保存分→公式の最新の順に読む
        .task {
            let api = library.api
            if let saved = try? await APICache.fromCache({ try await api.specialContents() }) { apply(saved) }
            if let fresh = try? await api.specialContents() { apply(fresh) }
        }
    }

    private func apply(_ articles: [KFArticle]) {
        let now = Self.calendar.dateComponents([.year, .month], from: Date())
        let current = articles.lazy.compactMap { article -> DeliverySchedule? in
            guard let slug = article.slug, slug.hasPrefix(DeliverySchedule.slugPrefix), let body = article.body else { return nil }
            return DeliverySchedule.parse(slug: slug, title: article.data?.title, body: body)
        }.first { $0.year == now.year && $0.month == now.month }
        if current != schedule { schedule = current }
    }
}

/// 号1冊ぶん：見出し（タップで号のページ）と、収録作品の表紙の横スクロール
struct IssueShelf: View {
    let issue: KFContent
    let library: LibraryStore
    let magazine: MagazineIdentity?
    /// 見出し（無ければ公式の号の名前）と、横に添える文字
    var title: String?
    var detail: String?

    @State private var comics: [ComicSummary]

    init(issue: KFContent, library: LibraryStore, magazine: MagazineIdentity? = nil,
         title: String? = nil, detail: String? = nil) {
        self.issue = issue
        self.library = library
        self.title = title
        self.detail = detail
        self.magazine = magazine ?? MagazineIdentity.resolve(slug: issue.magazineSlug, issue: issue.title)
        // 一度取った号の中身（端末内に保存してある分も）は、画面を作った瞬間から出す（読み込み中の表示を出さない）
        _comics = State(initialValue: library.cachedIssueComics(issueID: issue.id) ?? [])
    }

    var body: some View {
        Group {
            if comics.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title ?? issue.title ?? "")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.sectionTitle)
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 15)
                    Theme.bar
                        .frame(height: OfficialMetrics.cardWidth / coverAspect + 30)
                        .overlay(ProgressView())
                }
            } else {
                CoverShelf(
                    title: title ?? issue.title ?? "",
                    comics: comics,
                    library: library, detail: detail, showsMagazineLogo: true, magazine: magazine,
                    magazineLogoAtBottom: true
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

/// 雑誌のページで、号の書き方と配信日をそろえて出す。
/// 公式の号の名前は雑誌ごとに「快楽天 2026.11」「異世快楽天 Vol.62」「ゼロス #140」「WEEKLY快楽天 2026 No.38」と違うので、
/// 号の部分だけを読み「2026年11月号」「第62号」「2026年 第38号」にする。読めない名前は公式のまま
enum IssueLabel {
    static func title(_ name: String?) -> String? {
        guard let name else { return nil }
        if let match = groups(#"(\d{4})\s*No\.?\s*(\d+)\s*$"#, in: name) {
            return "\(match[0])年 第\(match[1])号"
        }
        if let match = groups(#"(\d{4})\.(\d{1,2})\s*$"#, in: name), let month = Int(match[1]) {
            return "\(match[0])年\(month)月号"
        }
        if let match = groups(#"(?:vol\.?|#)\s*(\d+)\s*$"#, in: name), let number = Int(match[0]) {
            return "第\(number)号"
        }
        return name
    }

    /// 配信日（日本時間）。例：2026/9/28 配信
    static func release(_ date: Date?) -> String? {
        date.map { format("yyyy/M/d", $0) + " 配信" }
    }

    /// 例：2026年9月
    static func month(_ date: Date?) -> String? {
        date.map { format("yyyy年M月", $0) }
    }

    private static func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
