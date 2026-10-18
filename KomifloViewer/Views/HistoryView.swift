import SwiftUI

/// 閲覧履歴・ブックマーク・いいねをまとめた画面（すべてKomifloアカウントの内容）
struct LibraryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case history = "閲覧履歴"
        case bookmarks = "ブックマーク"
        case likes = "いいね"
        case follows = "フォロー"
        var id: String { rawValue }

        var kind: LibraryStore.Kind? {
            switch self {
            case .history: return .history
            case .bookmarks: return .bookmarks
            case .likes: return .likes
            case .follows: return nil
            }
        }

        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    enum Page: Hashable {
        case list(LibraryStore.Kind, Int), follows

        var tab: Tab {
            switch self {
            case .list(.history, _): return .history
            case .list(.bookmarks, _): return .bookmarks
            case .list(.likes, _): return .likes
            case .follows: return .follows
            }
        }

        var number: Int {
            if case .list(_, let index) = self { return index }
            return 0
        }

        /// 左から右への並び（タブの順、同じタブならページの順）
        static func isForward(_ from: Page, _ to: Page) -> Bool {
            (from.tab.index, from.number) < (to.tab.index, to.number)
        }
    }

    /// 隣のページの決まり方を左右する値（変わったらページめくりの部品に隣を作り直させる）
    private struct Neighbors: Hashable {
        let keys: [LibraryStore.ListKey]
        let counts: [Int]
        let lastPages: [Int]
    }

    @ObservedObject var library: LibraryStore

    /// 表示するページ。タブ・ページ番号を押すと変わり、めくり終わって止まったページでも変わる
    @State private var page: Page = .list(.history, 0)
    @State private var motion = LibraryMotion<Page>(page: .list(.history, 0))
    /// 一覧の切り替えを画面の下に出す（アプリ設定で共通。既定は上）
    @AppStorage(ControlsPosition.key) private var controlsAtBottom = false
    @State private var tabProgress = PagerProgress()

    private static let kinds: [LibraryStore.Kind] = [.history, .bookmarks, .likes]

    private func pageCount(_ kind: LibraryStore.Kind) -> Int {
        max(1, library.list(library.key(kind)).pageCount ?? 1)
    }

    /// そのタブで最後に見たページ
    private func currentPage(of tab: Tab) -> Page {
        guard let kind = tab.kind else { return .follows }
        return .list(kind, min(library.list(library.key(kind)).page, pageCount(kind) - 1))
    }

    /// タブを1つのまとまりとして、隣のページを決める。タブの中は次・前のページ、
    /// タブの最初・最後のページの外は、隣のタブで最後に見たページ
    private func neighbor(of page: Page, forward: Bool) -> Page? {
        if case .list(let kind, let index) = page {
            if forward, index + 1 < pageCount(kind) { return .list(kind, index + 1) }
            if !forward, index > 0 { return .list(kind, index - 1) }
        }
        let tabs = Tab.allCases
        let next = page.tab.index + (forward ? 1 : -1)
        return tabs.indices.contains(next) ? currentPage(of: tabs[next]) : nil
    }

    private var neighbors: Neighbors {
        Neighbors(keys: Self.kinds.map { library.key($0) },
                  counts: Self.kinds.map(pageCount),
                  lastPages: Self.kinds.map { library.list(library.key($0)).page })
    }

    /// めくりの途中の位置を、上の4つの切り替えの位置に直す
    private static func tabPosition(_ motion: LibraryPagerMotion<Page>) -> CGFloat {
        let from = CGFloat(motion.from.tab.index)
        guard let to = motion.to else { return from }
        return from + (CGFloat(to.tab.index) - from) * motion.fraction
    }

    private var switcher: some View {
        PagerTabs(items: Tab.allCases, selection: Binding(
            get: { page.tab },
            set: { page = currentPage(of: $0) }
        ), progress: tabProgress, title: { $0.rawValue })
    }

    @ViewBuilder
    private func content(_ item: Page) -> some View {
        switch item {
        case .list(let kind, let index):
            RemoteComicFeed(key: library.key(kind), page: index, library: library, isActive: page == item)
                .padding(.top, LibraryListControls.height)
        case .follows:
            FollowList(library: library)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !controlsAtBottom {
                switcher
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            LibraryPager(page: page, neighbor: { neighbor(of: $0, forward: $1) }, isForward: Page.isForward,
                         neighborsVersion: AnyHashable(neighbors),
                         content: { AnyView(content($0)) },
                         onSettle: { settled in
                             if page != settled { page = settled }
                             // 止まったページを、そのタブで最後に見たページとして覚える
                             if case .list(let kind, let index) = settled {
                                 Task { await library.selectPage(index, for: library.key(kind)) }
                             }
                         },
                         onMotion: { value in
                             motion.update(value)
                             tabProgress.update(Self.tabPosition(value))
                         })
                .overlay(alignment: .top) {
                    LibraryBars(motion: motion, library: library, page: $page)
                }
                .clipped()
        }
        // 下に出す設定のときは、切り替えをタブバーのすぐ上に置く。
        .safeAreaInset(edge: .bottom) {
            if controlsAtBottom {
                BottomControlBar {
                    switcher
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("ライブラリ")
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        // ページ数が減って今のページが無くなったら、そのタブで最後に見たページへ
        .onChange(of: neighbors) { _, _ in
            if case .list(let kind, let index) = page, index >= pageCount(kind) {
                page = currentPage(of: page.tab)
            }
        }
        .onAppear { tabProgress.update(CGFloat(page.tab.index)) }
        .task {
            // 横めくりで来たときに読み込みが走ってかくつかないよう、全部のタブを開いた時点で先に読んでおく
            let history = library.key(.history)
            let bookmarks = library.key(.bookmarks)
            let likes = library.key(.likes)
            async let historyLoad: Void = library.prepare(history, refreshLoaded: false)
            async let bookmarksLoad: Void = library.prepare(bookmarks, refreshLoaded: false)
            async let likesLoad: Void = library.prepare(likes, refreshLoaded: false)
            async let follows: Void = library.prepareFollows()
            // ★・♥の表示用
            async let marks: Void = library.refreshMarks()
            _ = await (historyLoad, bookmarksLoad, likesLoad, follows, marks)
        }
        .markErrorAlert(library)
    }
}

/// 各タブの操作（絞り込み・並び順・ページ番号）。めくる元のタブと行き先のタブの操作だけを、
/// めくりに合わせて一緒に動かす（同じタブのページの間では動かさない）
private struct LibraryBars: View {
    @ObservedObject var motion: LibraryMotion<LibraryView.Page>
    @ObservedObject var library: LibraryStore
    @Binding var page: LibraryView.Page
    /// ページ番号の位置は下の計算で決めるので、変わらない値を渡しておく
    @State private var fixedProgress: PagerProgress = {
        let progress = PagerProgress()
        progress.update(0)
        return progress
    }()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ForEach([LibraryStore.Kind.history, .bookmarks, .likes], id: \.self) { kind in
                    if let offset = offset(of: kind) {
                        bar(kind)
                            .offset(x: offset * geometry.size.width)
                            .allowsHitTesting(abs(offset) < 0.5)
                    }
                }
            }
        }
        .frame(height: LibraryListControls.height)
    }

    private func tab(of kind: LibraryStore.Kind) -> LibraryView.Tab {
        LibraryView.Page.list(kind, 0).tab
    }

    /// 画面幅を1とした横の位置。めくる元・行き先のタブでなければ出さない
    private func offset(of kind: LibraryStore.Kind) -> CGFloat? {
        let value = motion.value
        let tab = tab(of: kind)
        let direction: CGFloat = value.to.map { LibraryView.Page.isForward(value.from, $0) ? 1 : -1 } ?? 1
        if tab == value.from.tab {
            guard let to = value.to, to.tab != tab else { return 0 }
            return -direction * value.fraction
        }
        if let to = value.to, tab == to.tab { return direction * (1 - value.fraction) }
        return nil
    }

    /// ページ番号の印の位置。めくりには合わせず、選んだページ（押した番号・止まったページ）にその場で移す
    private func pagePosition(of kind: LibraryStore.Kind) -> CGFloat {
        if case .list(kind, let index) = page { return CGFloat(index) }
        return CGFloat(library.list(library.key(kind)).page)
    }

    private func bar(_ kind: LibraryStore.Kind) -> some View {
        let position = pagePosition(of: kind)
        return LibraryListControls(
            kind: kind, library: library,
            pageCount: max(1, library.list(library.key(kind)).pageCount ?? 1),
            selectedPage: Binding(
                get: {
                    if case .list(kind, let index) = page { return index }
                    return library.list(library.key(kind)).page
                },
                set: { page = .list(kind, $0) }),
            progress: fixedProgress,
            positionTransform: { _ in position },
            onListChange: {
                // 並び順・絞り込み・月を変えたら、その条件で最後に見たページを出す
                let count = max(1, library.list(library.key(kind)).pageCount ?? 1)
                page = .list(kind, min(library.list(library.key(kind)).page, count - 1))
            })
        .background(Theme.background)
    }
}

// MARK: - フォロー（公式の「フォロー作家」）

/// フォローしている作家（作家ギャラリーと同じ横長の帯）とタグ（ボタン）。長押しでフォロー解除
struct FollowList: View {
    @ObservedObject var library: LibraryStore

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Group {
            if !library.hasLoadedFollows {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = library.followsError, library.followedArtists.isEmpty {
                EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
            } else if library.followedArtists.isEmpty, library.followedTags.isEmpty {
                // 公式と同じ文言
                EmptyState(
                    title: "フォローしている作家はいません。",
                    systemImage: "person.crop.circle.badge.plus",
                    message: "作家のページで「フォロー」を押すと、ここに並びます。"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let tags = library.followedTags
                        if !tags.isEmpty {
                            sectionTitle("フォロー中のタグ \(tags.count)")
                            FlowLayout(spacing: 8) {
                                ForEach(tags) { tag in
                                    Button {
                                        openRoute(.tag(id: tag.id, name: tag.name))
                                    } label: {
                                        Label(tag.name, systemImage: "tag.fill")
                                            .modifier(FollowAttributeStyle())
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { unfollowButton(tag) }
                                }
                            }
                            .padding(.horizontal, 15 * OfficialMetrics.scale)
                            .padding(.bottom, 12)
                        }

                        let artists = library.followedArtists
                        let newCount = artists.filter { $0.newContentCount > 0 }.count
                        if !artists.isEmpty {
                            sectionTitle(newCount > 0
                                         ? "フォロー中の作家 \(artists.count)人・新着 \(newCount)人"
                                         : "フォロー中の作家 \(artists.count)人")
                            ForEach(artists) { artist in
                                Button {
                                    if let slug = artist.slug { openRoute(.artist(slug: slug, name: artist.name)) }
                                } label: {
                                    // フォロー一覧のデータには画像が無いので、作家ごとに取った画像を渡す（作家ギャラリーと同じ見た目）
                                    ArtistBannerRow(
                                        artist: artist,
                                        library: library,
                                        fallbackBannerURL: library.artistBanners[artist.id]
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu { unfollowButton(artist) }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .task {
            // スワイプで来るたびに読み直すと一覧が入れ替わってかくつくので、まだのときだけ
            await library.prepareFollows()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.sectionTitle)
            .padding(.horizontal, 15 * OfficialMetrics.scale)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    private func unfollowButton(_ attribute: KFAttribute) -> some View {
        Button(role: .destructive) {
            Task { await library.toggleFollow(attributeID: attribute.id) }
        } label: {
            Label("フォロー解除", systemImage: "person.badge.minus")
        }
    }
}
// MARK: - Komifloアカウントの一覧（閲覧履歴・ブックマーク・いいね）

/// メニューから単独で開く一覧。その一覧のページ（1 2 3 …）を、ライブラリと同じページめくりで切り替える
struct RemoteComicList: View {
    let kind: LibraryStore.Kind
    @ObservedObject var library: LibraryStore
    let isActive: Bool
    var refreshLoaded = true

    @State private var isShown = false
    @State private var page: Int
    @State private var motion: LibraryMotion<Int>
    @State private var fixedProgress: PagerProgress = {
        let progress = PagerProgress()
        progress.update(0)
        return progress
    }()

    init(kind: LibraryStore.Kind, library: LibraryStore, isActive: Bool, refreshLoaded: Bool = true) {
        self.kind = kind
        self.library = library
        self.isActive = isActive
        self.refreshLoaded = refreshLoaded
        let page = library.list(library.key(kind)).page
        _page = State(initialValue: page)
        _motion = State(initialValue: LibraryMotion(page: page))
    }

    private var pageCount: Int { max(1, library.list(library.key(kind)).pageCount ?? 1) }

    private struct Neighbors: Hashable {
        let key: LibraryStore.ListKey
        let count: Int
    }

    var body: some View {
        let key = library.key(kind)
        let count = pageCount
        VStack(spacing: 0) {
            RemoteComicListControls(kind: kind, library: library, pageCount: count,
                                    page: $page, progress: fixedProgress)
            LibraryPager(page: page,
                         neighbor: { index, forward in
                             let next = index + (forward ? 1 : -1)
                             return next >= 0 && next < count ? next : nil
                         },
                         isForward: { $0 < $1 },
                         neighborsVersion: AnyHashable(Neighbors(key: key, count: count)),
                         content: { index in
                             AnyView(RemoteComicFeed(key: key, page: index, library: library,
                                                     isActive: isActive && isShown && page == index,
                                                     refreshLoaded: refreshLoaded))
                         },
                         onSettle: { settled in
                             if page != settled { page = settled }
                             Task { await library.selectPage(settled, for: library.key(kind)) }
                         },
                         onMotion: { motion.update($0) })
        }
        .onChange(of: count) { _, newCount in
            if page >= newCount { page = newCount - 1 }
        }
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
    }
}

/// メニューの一覧の操作
private struct RemoteComicListControls: View {
    let kind: LibraryStore.Kind
    let library: LibraryStore
    let pageCount: Int
    @Binding var page: Int
    let progress: PagerProgress

    var body: some View {
        // ページ番号の印はめくりに合わせず、選んだページにその場で移す
        let position = CGFloat(page)
        LibraryListControls(kind: kind, library: library, pageCount: pageCount, selectedPage: $page,
                            progress: progress, positionTransform: { _ in position }, onListChange: {
            let count = max(1, library.list(library.key(kind)).pageCount ?? 1)
            page = min(library.list(library.key(kind)).page, count - 1)
        })
    }
}

/// 一覧の上の操作。1段目に絞り込みと並び順（ブックマークは「全て 既読 未読 新しい順 古い順」、
/// 閲覧履歴は並び順のあとに月）、2段目にページ番号。高さを固定し、一覧の先頭が隠れないようにする。
/// ライブラリとメニューで共用する
private struct LibraryListControls: View {
    static let height: CGFloat = 88

    let kind: LibraryStore.Kind
    @ObservedObject var library: LibraryStore
    let pageCount: Int
    @Binding var selectedPage: Int
    let progress: PagerProgress
    var positionTransform: (CGFloat) -> CGFloat = { $0 }
    /// 並び順・絞り込み・月を変えたとき
    let onListChange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if kind == .bookmarks {
                        ForEach(LibraryStore.BookmarkFilter.allCases) { filter in
                            FilterChip(title: filter.label, isSelected: library.bookmarkFilter == filter,
                                       horizontalPadding: 11) {
                                library.setBookmarkFilter(filter)
                                onListChange()
                            }
                        }
                        separator
                    }
                    ForEach(LibraryStore.ListOrder.allCases) { order in
                        FilterChip(title: order.label, isSelected: library.order(kind) == order,
                                   horizontalPadding: 11) {
                            library.setOrder(order, for: kind)
                            onListChange()
                        }
                    }
                    if kind == .history, !library.historyMonths.isEmpty {
                        separator
                        FilterChip(title: "全ての月", isSelected: library.historyMonth == nil) {
                            library.setHistoryMonth(nil)
                            onListChange()
                        }
                        ForEach(library.historyMonths, id: \.self) { month in
                            FilterChip(title: Self.monthLabel(month), isSelected: library.historyMonth == month) {
                                library.setHistoryMonth(month)
                                onListChange()
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 44)
            PagerTabs(items: Array(0..<pageCount), selection: $selectedPage, progress: progress, scrolls: true,
                      font: .footnote.weight(.semibold), positionTransform: positionTransform,
                      scrollsToSelection: false, title: { String($0 + 1) })
                .frame(height: 32)
                .padding(.vertical, 6)
        }
        .frame(height: Self.height, alignment: .top)
        .task {
            if kind == .history, library.historyMonths.isEmpty { await library.loadHistoryMonths() }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 1, height: 18)
    }

    /// 公式と同じ「26.9」の形
    private static func monthLabel(_ month: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month], from: month)
        return "\((parts.year ?? 0) % 100).\(parts.month ?? 0)"
    }
}

/// 一覧の1ページ。末尾で続きを読み込まず、ページは左右のスワイプとページ番号で切り替える
private struct RemoteComicFeed: View {
    let key: LibraryStore.ListKey
    let page: Int
    @ObservedObject var library: LibraryStore
    let isActive: Bool
    var refreshLoaded = true

    private struct LoadTrigger: Hashable {
        let key: LibraryStore.ListKey
        let page: Int
    }

    private var feed: LibraryStore.PagedFeed { library.list(key) }

    private var emptyTitle: String {
        switch key.kind {
        case .history: return "閲覧履歴はまだありません"
        case .bookmarks: return "ブックマークはまだありません"
        case .likes: return "いいねした作品はまだありません"
        }
    }

    /// 絞り込み中は、公式と同じ文言で「該当なし」を出す
    private var emptyMessage: String {
        switch key.kind {
        case .history where key.month != nil:
            return "この月に閲覧された作品はありません"
        case .bookmarks where (key.filter ?? .all) != .all:
            return "該当作品がありません。"
        default:
            return "Komifloで追加すると、ここに表示されます。"
        }
    }

    private var emptyIcon: String {
        switch key.kind {
        case .history: return "clock"
        case .bookmarks: return "star"
        case .likes: return "heart"
        }
    }

    var body: some View {
        Group {
            if let items = feed.pages[page] {
                if items.isEmpty, page == 0 {
                    EmptyState(title: emptyTitle, systemImage: emptyIcon, message: emptyMessage)
                } else {
                    // 公式の閲覧履歴・ブックマークと同じ、表紙カードの2列グリッド
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                Group {
                                    if let total = feed.total {
                                        Text("\(total)作品")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.sectionTitle)
                                .padding(.horizontal, 15 * OfficialMetrics.scale)
                                .id("top")
                                ComicGrid(comics: items, library: library, showsMagazineLogo: true)
                                // このページの最後の作品が、一覧の何作品目か
                                if let shown = library.shownCount(key, page: page), let total = feed.total {
                                    Text("\(shown)/\(total)作品")
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(Theme.sectionTitle)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        // 並び順・絞り込みを変えたら先頭から見せる
                        .onChange(of: key) { _, _ in proxy.scrollTo("top", anchor: .top) }
                    }
                }
            } else if let error = feed.errors[page] {
                VStack(spacing: 16) {
                    EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
                        .frame(maxHeight: 260)
                    Button("再読み込み") {
                        Task { await library.reload(key) }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        // 表示中のページだけを取得し、スワイプで来たときに待たないよう前後のページも読んでおく。
        // 停止後に始めた取得は、次のスワイプだけでは中断しない
        .task(id: isActive ? LoadTrigger(key: key, page: page) : nil) {
            guard isActive else { return }
            await library.prepare(key, page: page, refreshLoaded: refreshLoaded)
            let count = library.list(key).pageCount ?? 1
            for neighbor in [page + 1, page - 1] where neighbor >= 0 && neighbor < count {
                guard !Task.isCancelled else { return }
                await library.prepare(key, page: neighbor, refreshLoaded: false)
            }
        }
    }
}
