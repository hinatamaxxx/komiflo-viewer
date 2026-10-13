import SwiftUI

/// 閲覧履歴・ブックマーク・いいねをまとめた画面（すべてKomifloアカウントの内容）
struct LibraryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case history = "閲覧履歴"
        case bookmarks = "ブックマーク"
        case likes = "いいね"
        case follows = "フォロー"
        var id: String { rawValue }
    }

    /// 同じ向きのスワイプを入れ子にせず、並び順・絞り込みも1本のページ列に含める。
    enum Page: Hashable {
        case history(LibraryStore.HistoryOrder), bookmarks(LibraryStore.BookmarkFilter), likes, follows

        static let all: [Page] = [.history(.newest), .history(.oldest),
                                 .bookmarks(.all), .bookmarks(.read), .bookmarks(.unread), .likes, .follows]

        static func tabPosition(_ position: CGFloat) -> CGFloat {
            min(1, max(0, position - 1)) + min(2, max(0, position - 4))
        }

        var tab: Tab {
            switch self {
            case .history: return .history
            case .bookmarks: return .bookmarks
            case .likes: return .likes
            case .follows: return .follows
            }
        }

        var historyOrder: LibraryStore.HistoryOrder? {
            if case .history(let order) = self { return order }
            return nil
        }

        var bookmarkFilter: LibraryStore.BookmarkFilter? {
            if case .bookmarks(let filter) = self { return filter }
            return nil
        }
    }

    let library: LibraryStore
    @State private var page: Page = .history(.newest)
    @State private var historyControlsHeight: CGFloat = 48
    @State private var bookmarkControlsHeight: CGFloat = 44
    /// 一覧の切り替えを画面の下に出す（アプリ設定で共通。既定は上）
    @AppStorage(ControlsPosition.key) private var controlsAtBottom = false
    @State private var isPaging = false
    @State private var tabProgress = PagerProgress()

    private var switcher: some View {
        PagerTabs(items: Tab.allCases, selection: Binding(
            get: { page.tab },
            set: { tab in
                switch tab {
                case .history: page = .history(library.historyOrder)
                case .bookmarks: page = .bookmarks(library.bookmarkFilter)
                case .likes: page = .likes
                case .follows: page = .follows
                }
            }
        ), progress: tabProgress, positionTransform: Page.tabPosition, title: { $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
                if !controlsAtBottom {
                    switcher
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                PagedView(items: Page.all, selection: $page, keepsPagesAlive: true, commitsSelectionOnIdle: true,
                          onScrollActivityChange: { isPaging = $0 }, progress: tabProgress) { item in
                    switch item {
                    case .history(let order):
                        RemoteComicList(kind: .history, library: library, isActive: page == item && !isPaging,
                                        fixedHistoryOrder: order, refreshLoaded: false)
                            .padding(.top, historyControlsHeight)
                    case .bookmarks(let filter):
                        RemoteComicList(kind: .bookmarks, library: library, isActive: page == item && !isPaging,
                                        fixedBookmarkFilter: filter)
                            .padding(.top, bookmarkControlsHeight)
                    case .likes:
                        RemoteComicList(kind: .likes, library: library, isActive: page == item && !isPaging)
                    case .follows:
                        FollowList(library: library)
                    }
                }
                .overlay(alignment: .top) {
                    LibraryHistoryControls(library: library, page: $page, progress: tabProgress)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if historyControlsHeight != height { historyControlsHeight = height }
                        }
                    LibraryBookmarkControls(library: library, page: $page, progress: tabProgress)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if bookmarkControlsHeight != height { bookmarkControlsHeight = height }
                        }
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
            .task {
                // 横スワイプで来たときに読み込みが走ってかくつかないよう、全部のタブを開いた時点で先に読んでおく
                async let history: Void = library.prepareFeed(.history, refreshLoaded: false)
                async let bookmarks: Void = library.prepareFeed(.bookmarks, refreshLoaded: false)
                async let likes: Void = library.prepareFeed(.likes, refreshLoaded: false)
                async let follows: Void = library.prepareFollows()
                // ★・♥の表示用
                async let marks: Void = library.refreshMarks()
                _ = await (history, bookmarks, likes, follows, marks)
            }
            .markErrorAlert(library)
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

struct RemoteComicList: View {
    let kind: LibraryStore.Kind
    @ObservedObject var library: LibraryStore
    let isActive: Bool
    /// ライブラリでは親のページ列に参加し、単独画面だけ内部でページを持つ。
    var fixedHistoryOrder: LibraryStore.HistoryOrder?
    var fixedBookmarkFilter: LibraryStore.BookmarkFilter?
    var refreshLoaded = true
    @State private var isShown = false
    @State private var isPaging = false
    @State private var historyProgress = PagerProgress()
    @State private var historyPage: LibraryStore.HistoryOrder
    @State private var bookmarkPage: LibraryStore.BookmarkFilter
    private var isCurrent: Bool { isActive && isShown }

    init(kind: LibraryStore.Kind, library: LibraryStore, isActive: Bool,
         fixedHistoryOrder: LibraryStore.HistoryOrder? = nil,
         fixedBookmarkFilter: LibraryStore.BookmarkFilter? = nil, refreshLoaded: Bool = true) {
        self.kind = kind
        self.library = library
        self.isActive = isActive
        self.fixedHistoryOrder = fixedHistoryOrder
        self.fixedBookmarkFilter = fixedBookmarkFilter
        self.refreshLoaded = refreshLoaded
        _historyPage = State(initialValue: library.historyOrder)
        _bookmarkPage = State(initialValue: library.bookmarkFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            if fixedHistoryOrder == nil && fixedBookmarkFilter == nil { controls }
            if let order = fixedHistoryOrder {
                RemoteComicFeed(kind: kind, library: library,
                                isActive: isCurrent && library.historyOrder == order, historyOrder: order)
            } else if let filter = fixedBookmarkFilter {
                RemoteComicFeed(kind: kind, library: library,
                                isActive: isCurrent && library.bookmarkFilter == filter, bookmarkFilter: filter)
            } else if kind == .history {
                PagedView(items: LibraryStore.HistoryOrder.allCases, selection: $historyPage,
                          keepsPagesAlive: true, commitsSelectionOnIdle: true,
                          onScrollActivityChange: { isPaging = $0 }, progress: historyProgress) { order in
                    RemoteComicFeed(kind: kind, library: library,
                                    isActive: isCurrent && !isPaging && historyPage == order && library.historyOrder == order,
                                    historyOrder: order)
                }
                .onChange(of: historyPage) { _, order in
                    Task { await library.setHistoryOrder(order) }
                }
                .onChange(of: library.historyOrder) { _, order in
                    if historyPage != order { historyPage = order }
                }
            } else if kind == .bookmarks {
                PagedView(items: LibraryStore.BookmarkFilter.allCases, selection: $bookmarkPage,
                          keepsPagesAlive: true, commitsSelectionOnIdle: true,
                          onScrollActivityChange: { isPaging = $0 }, progress: historyProgress) { filter in
                    RemoteComicFeed(kind: kind, library: library,
                                    isActive: isCurrent && !isPaging && bookmarkPage == filter && library.bookmarkFilter == filter,
                                    bookmarkFilter: filter)
                }
                .onChange(of: bookmarkPage) { _, filter in
                    Task { await library.setBookmarkFilter(filter) }
                }
                .onChange(of: library.bookmarkFilter) { _, filter in
                    if bookmarkPage != filter { bookmarkPage = filter }
                }
            } else {
                RemoteComicFeed(kind: kind, library: library, isActive: isCurrent)
            }
        }
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
        .task(id: isCurrent) {
            guard isCurrent else { return }
            if let fixedHistoryOrder {
                // 停止後に始めた取得は、次のスワイプだけでは中断しない。
                await Task { await library.setHistoryOrder(fixedHistoryOrder) }.value
            }
            if let fixedBookmarkFilter {
                await Task { await library.setBookmarkFilter(fixedBookmarkFilter) }.value
            }
            guard !Task.isCancelled else { return }
            await library.prepareFeed(kind, refreshLoaded: refreshLoaded)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch kind {
        case .bookmarks:
            BookmarkControls(filter: $bookmarkPage, progress: historyProgress)
        case .history:
            HistoryControls(library: library, order: $historyPage, progress: historyProgress)
        case .likes:
            EmptyView()
        }
    }

}

/// 絞り込みの表示・選択追従を、ライブラリとメニューで共用する。
private struct BookmarkControls: View {
    @Binding var filter: LibraryStore.BookmarkFilter
    let progress: PagerProgress
    var positionTransform: (CGFloat) -> CGFloat = { $0 }

    var body: some View {
        PagerTabs(items: LibraryStore.BookmarkFilter.allCases, selection: $filter,
                  progress: progress, scrolls: true, font: .footnote, selectedFont: .footnote.bold(),
                  positionTransform: positionTransform, title: { $0.label })
            .frame(height: 32)
            .padding(.vertical, 6)
    }
}

/// 絞り込み同士ではバーを固定し、前後のタブへ移るときだけ一覧と一緒に動かす。
private struct LibraryBookmarkControls: View {
    let library: LibraryStore
    @Binding var page: LibraryView.Page
    @ObservedObject var progress: PagerProgress

    var body: some View {
        let position = progress.position ?? CGFloat(LibraryView.Page.all.firstIndex(of: page) ?? 0)
        BookmarkControls(filter: Binding(
            get: { page.bookmarkFilter ?? library.bookmarkFilter },
            set: { page = .bookmarks($0) }
        ), progress: progress, positionTransform: { $0 - 2 })
        .background(Theme.background)
        .visualEffect { content, geometry in
            content.offset(x: (min(1, max(0, 2 - position)) - min(1, max(0, position - 4))) * geometry.size.width)
        }
        .allowsHitTesting(position > 1 && position < 5)
    }
}

/// 新しい順・古い順と月の選択を、ライブラリとメニューで共用する。
private struct HistoryControls: View {
    @ObservedObject var library: LibraryStore
    @Binding var order: LibraryStore.HistoryOrder
    let progress: PagerProgress

    var body: some View {
        VStack(spacing: 0) {
            ChronologicalOrderPicker(order: $order, progress: progress)
            if !library.historyMonths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "全て", isSelected: library.historyMonth == nil) {
                            Task { await library.setHistoryMonth(nil) }
                        }
                        ForEach(library.historyMonths, id: \.self) { month in
                            FilterChip(
                                title: Self.monthLabel(month),
                                isSelected: library.historyMonth == month
                            ) {
                                Task { await library.setHistoryMonth(month) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 6)
            }
        }
        .task {
            if library.historyMonths.isEmpty { await library.loadHistoryMonths() }
        }
    }

    /// 公式と同じ「26.9」の形
    private static func monthLabel(_ month: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month], from: month)
        return "\((parts.year ?? 0) % 100).\(parts.month ?? 0)"
    }

}

/// 履歴とタグで共用する、新しい順・古い順のピンクのボタン。
struct ChronologicalOrderPicker: View {
    static let height: CGFloat = 44
    @Binding var order: LibraryStore.HistoryOrder
    let progress: PagerProgress

    var body: some View {
        PagerTabs(items: LibraryStore.HistoryOrder.allCases, selection: $order,
                  progress: progress, scrolls: true, font: .footnote.weight(.semibold), title: { $0.label })
            .frame(height: 32)
            .padding(.vertical, 6)
    }
}

/// 履歴の2ページで操作バーを共有し、ブックマークへ移るときだけ一緒に退く。
private struct LibraryHistoryControls: View {
    let library: LibraryStore
    @Binding var page: LibraryView.Page
    @ObservedObject var progress: PagerProgress

    var body: some View {
        let position = progress.position ?? CGFloat(LibraryView.Page.all.firstIndex(of: page) ?? 0)
        HistoryControls(library: library, order: Binding(
            get: { page.historyOrder ?? library.historyOrder },
            set: { page = .history($0) }
        ), progress: progress)
        .background(Theme.background)
        .visualEffect { content, geometry in
            content.offset(x: -min(1, max(0, position - 1)) * geometry.size.width)
        }
        .allowsHitTesting(position < 2)
    }
}

/// ページごとにスクロール位置と末尾表示を保持し、移動中に一覧を入れ替えない。
private struct RemoteComicFeed: View {
    let kind: LibraryStore.Kind
    @ObservedObject var library: LibraryStore
    let isActive: Bool
    var historyOrder: LibraryStore.HistoryOrder?
    var bookmarkFilter: LibraryStore.BookmarkFilter?
    @State private var isEndVisible = false

    private var feed: LibraryStore.Feed {
        if let historyOrder { return library.historyFeed(for: historyOrder) }
        if let bookmarkFilter { return library.bookmarkFeed(for: bookmarkFilter) }
        return library.feed(kind)
    }
    private var items: [ComicSummary] { feed.items }

    private var emptyTitle: String {
        switch kind {
        case .history: return "閲覧履歴はまだありません"
        case .bookmarks: return "ブックマークはまだありません"
        case .likes: return "いいねした作品はまだありません"
        }
    }

    /// 絞り込み中は、公式と同じ文言で「該当なし」を出す
    private var emptyMessage: String {
        switch kind {
        case .history where library.historyMonth != nil:
            return "この月に閲覧された作品はありません"
        case .bookmarks where (bookmarkFilter ?? library.bookmarkFilter) != .all:
            return "該当作品がありません。"
        default:
            return "Komifloで追加すると、ここに表示されます。"
        }
    }

    private var emptyIcon: String {
        switch kind {
        case .history: return "clock"
        case .bookmarks: return "star"
        case .likes: return "heart"
        }
    }

    var body: some View {
        Group {
            if let error = feed.error, feed.items.isEmpty {
                VStack(spacing: 16) {
                    EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
                        .frame(maxHeight: 260)
                    Button("再読み込み") {
                        Task { await library.loadMore(kind, reset: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            } else if !feed.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                EmptyState(title: emptyTitle, systemImage: emptyIcon, message: emptyMessage)
            } else {
                // 公式の閲覧履歴・ブックマークと同じ、表紙カードの2列グリッド
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

                        ComicGrid(comics: items, library: library, showsMagazineLogo: true)

                        // 最後まで来たら自動で続きを読み込む
                        Color.clear
                            .frame(height: 1)
                            .onAppear { isEndVisible = true }
                            .onDisappear { isEndVisible = false }

                        if feed.isLoading {
                            LoadingFooter()
                        } else if let error = feed.error {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 15)
                        }
                    }
                    .padding(.vertical, 8)
                }
                // 非表示タブの末尾では取得せず、選択後も末尾が見えていれば続ける。
                .task(id: isActive && isEndVisible ? items.last?.id : nil) {
                    guard isActive, isEndVisible else { return }
                    await library.loadMore(kind)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

}
