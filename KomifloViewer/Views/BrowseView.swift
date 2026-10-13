import SwiftUI

/// 下のタブの「さがす」。検索バーの下に「タグ / 作家」の切り替え。
/// タグの並び順と作家の行（五十音）を同じページ列に置き、左右スワイプで切り替える。
/// 入力した文字でタグ・作家を絞り込み、検索キーを押すと作品を検索する
struct SearchView: View {
    enum Section: String, CaseIterable, Identifiable {
        case tags = "タグ"
        case artists = "作家"
        var id: String { rawValue }
    }

    enum Page: Hashable {
        case tags(TagListView.TagSort)
        /// 作家の行（"" は All、ひらがなは あ・か・…）
        case artists(String)

        var section: Section {
            if case .tags = self { return .tags }
            return .artists
        }

        static let artistStart = TagListView.TagSort.allCases.count

        static func sectionPosition(_ position: CGFloat) -> CGFloat {
            min(1, max(0, position - CGFloat(artistStart - 1)))
        }
    }

    /// 公式の行ボタン（表示はカタカナ、APIにはひらがなを渡す）
    private static let kanaRows: [(label: String, value: String)] = [
        ("All", ""), ("ア", "あ"), ("カ", "か"), ("サ", "さ"), ("タ", "た"), ("ナ", "な"),
        ("ハ", "は"), ("マ", "ま"), ("ヤ", "や"), ("ラ", "ら"), ("ワ", "わ"),
    ]

    private static var pages: [Page] {
        TagListView.TagSort.allCases.map { .tags($0) } + kanaRows.map { .artists($0.value) }
    }

    let library: LibraryStore
    /// この値が変わるたびに検索欄にカーソルを入れる（「さがす」タブを開いたとき）
    var focusToken: Int = 0

    /// 検索欄と切り替えを画面の下に出す（アプリ設定で共通。既定は上）
    @AppStorage(ControlsPosition.key) private var controlsAtBottom = false

    @State private var tabProgress = PagerProgress()
    @State private var page: Page = .artists("")
    @State private var searchText = ""
    /// 絞り込みに使う文字。入力が止まってから反映して、1文字ごとに一覧を作り直してちらつかないようにする
    @State private var filterText = ""
    @State private var submittedQuery = ""
    /// 一番上で下に引っぱったときに増やして、検索欄にカーソルを入れる
    @State private var pullFocusToken = 0

    private let prompt = "タグ・作家・作品名で検索"
    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var searchField: some View {
        InlineSearchField(text: $searchText, prompt: prompt, onSubmit: submit, focusToken: focusToken + pullFocusToken)
    }

    private var switcher: some View {
        PagerTabs(items: Section.allCases, selection: Binding(
            get: { page.section },
            set: { page = $0 == .tags ? .tags(.popular) : .artists(UserDefaults.standard.string(forKey: "artists.kana") ?? "") }
        ), progress: tabProgress, positionTransform: Page.sectionPosition, title: { $0.rawValue })
    }

    private func submit() {
        submittedQuery = query
    }

    private var showsControls: Bool { submittedQuery.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if !controlsAtBottom {
                searchField
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                if showsControls {
                    switcher
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if controlsAtBottom {
                BottomControlBar {
                    searchField
                    if showsControls { switcher }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: searchText) { _, text in
            if text.isEmpty {
                submittedQuery = ""
                filterText = ""
            }
        }
        .onChange(of: page) { _, value in
            if case .artists(let kana) = value {
                UserDefaults.standard.set(kana, forKey: "artists.kana")
            }
        }
        .task {
            // ライブラリのフォローと同じく、「作家」へスワイプする前に一覧を読んでおく（保存済みなら何もしない）
            let kana = UserDefaults.standard.string(forKey: "artists.kana") ?? ""
            guard ArtistGalleryCache.shared.entry(for: kana) == nil,
                  let result = try? await library.api.artists(kana: kana.isEmpty ? nil : kana, page: 0),
                  ArtistGalleryCache.shared.entry(for: kana) == nil else { return }
            ArtistGalleryCache.shared.store(
                .init(artists: result.artists, page: 1, totalPages: result.artists.isEmpty ? 1 : result.totalPages),
                for: kana
            )
        }
        .task(id: searchText) {
            // 入力が止まってから絞り込む
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            filterText = query
        }
        .navigationTitle("さがす")
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
    }

    /// 一番上で下に引っぱったら、検索欄にカーソルを入れてキーボードを出す
    private func focusSearchField() {
        pullFocusToken += 1
    }

    private var content: some View {
        ZStack {
            // 検索中も元の一覧を保持し、閉じたときにタブの位置決めをやり直さない。
            PagedView(items: Self.pages, selection: $page, commitsSelectionOnIdle: true, progress: tabProgress) { item in
                switch item {
                case .tags(let sort):
                    TagListView(library: library, filter: filterText, sort: sort, onPullDown: focusSearchField)
                        .padding(.top, SearchTagBar.height)
                case .artists(let kana):
                    ArtistGalleryView(
                        library: library,
                        fixedKana: kana,
                        onPullDown: focusSearchField,
                        externalQuery: filterText
                    )
                    // 一覧の領域は固定し、共通の五十音バーを重ねる場所だけ空ける。
                    .padding(controlsAtBottom ? .bottom : .top, SearchKanaBar.height(atBottom: controlsAtBottom))
                }
            }
            .overlay(alignment: controlsAtBottom ? .bottom : .top) {
                SearchKanaBar(rows: Self.kanaRows, selection: $page, progress: tabProgress, atBottom: controlsAtBottom)
            }
            .overlay(alignment: .top) {
                SearchTagBar(selection: $page, progress: tabProgress)
            }
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)

            if !submittedQuery.isEmpty {
                SearchResultsView(query: submittedQuery, library: library)
                    .id(submittedQuery)
            }
        }
        // キーボードが出ているときに一覧をスクロールしたら、キーボードを閉じる
        .scrollDismissesKeyboard(.immediately)
    }
}

/// タグ同士の切り替えでは固定し、作家との境界でだけ一覧と一緒に出入りする。
private struct SearchTagBar: View {
    @Binding var selection: SearchView.Page
    @ObservedObject var progress: PagerProgress

    static let height: CGFloat = 40

    private var position: CGFloat {
        if let position = progress.position { return position }
        if case .tags(let sort) = selection {
            return CGFloat(TagListView.TagSort.allCases.firstIndex(of: sort) ?? 0)
        }
        return CGFloat(SearchView.Page.artistStart)
    }

    var body: some View {
        GeometryReader { geometry in
            PagerTabs(items: TagListView.TagSort.allCases.map { SearchView.Page.tags($0) },
                      selection: $selection, progress: progress) { item in
                if case .tags(let sort) = item { return sort.label }
                return ""
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .background(Theme.background)
            .offset(x: -geometry.size.width * SearchView.Page.sectionPosition(position))
        }
        .frame(height: Self.height)
        .clipped()
        .allowsHitTesting(position < CGFloat(SearchView.Page.artistStart))
    }
}

/// 五十音同士では固定し、タグとの境界でだけ一覧と一緒に出入りする。
private struct SearchKanaBar: View {
    let rows: [(label: String, value: String)]
    @Binding var selection: SearchView.Page
    @ObservedObject var progress: PagerProgress
    let atBottom: Bool

    static func height(atBottom: Bool) -> CGFloat { atBottom ? 42 : 40 }

    private var position: CGFloat {
        SearchView.Page.sectionPosition(progress.position
            ?? (selection.section == .artists ? CGFloat(SearchView.Page.artistStart) : 0))
    }

    var body: some View {
        GeometryReader { geometry in
            PagerTabs(items: rows.map { SearchView.Page.artists($0.value) }, selection: $selection,
                      progress: progress, scrolls: true, font: .footnote.weight(.semibold),
                      positionTransform: { $0 - CGFloat(SearchView.Page.artistStart) }) { item in
                if case .artists(let kana) = item {
                    return rows.first { $0.value == kana }?.label ?? "All"
                }
                return "All"
            }
            .frame(height: 32)
            .padding(.horizontal, atBottom ? 16 : 0)
            .padding(.top, atBottom ? 10 : 0)
            .padding(.bottom, atBottom ? 0 : 8)
            .background {
                if atBottom { Rectangle().fill(.ultraThinMaterial) }
            }
            .offset(x: geometry.size.width * max(0, 1 - position))
        }
        .frame(height: Self.height(atBottom: atBottom))
        .clipped()
        .contentShape(Rectangle())
        .allowsHitTesting(position > 0)
    }
}

// MARK: - キーワード検索の結果

private struct SearchResultsView: View {
    let query: String
    @ObservedObject var library: LibraryStore

    @Environment(\.openRoute) private var openRoute

    @State private var attributes: [KFSearchAttribute] = []
    @State private var comics: [ComicSummary] = []
    @State private var total: Int?
    @State private var page = 0
    @State private var totalPages: Int?
    @State private var isLoading = false
    @State private var error: String?

    private var hasMore: Bool { totalPages.map { page < $0 } ?? true }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !attributes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("タグ・作者・雑誌").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(attributes) { attribute in
                                    Button {
                                        open(attribute)
                                    } label: {
                                        Label(attribute.name, systemImage: icon(for: attribute))
                                            .font(.footnote)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(Theme.bar, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .padding(.horizontal, 15)
                    }
                }

                if let total {
                    Text("作品 \(total)件").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15)
                }
                ComicGrid(comics: comics, library: library, showsTitles: true, onLastAppear: {
                    if error == nil { Task { await loadMore() } }
                }, showsMagazineLogo: true)
                if isLoading {
                    LoadingFooter()
                } else if let error {
                    Text(error).font(.footnote).padding(.horizontal, 15)
                    Button("再読み込み") { Task { await loadMore() } }.padding(.horizontal, 15)
                } else if comics.isEmpty, !hasMore, attributes.isEmpty {
                    Text("「\(query)」に一致するものは見つかりませんでした。").padding(.horizontal, 15)
                }
            }
            .padding(.vertical, 12)
        }
        .dismissesKeyboardOnScroll()
        .task {
            attributes = (try? await library.api.searchAttributes(query: query)) ?? []
        }
        .task { await loadMore() }
    }

    private func icon(for attribute: KFSearchAttribute) -> String {
        switch attribute.type {
        case "artists", "artist": return "person.fill"
        case "magazine", "magazines": return "books.vertical.fill"
        default: return "tag.fill"
        }
    }

    private func open(_ attribute: KFSearchAttribute) {
        switch attribute.type {
        case "artists", "artist":
            if let slug = attribute.slug { openRoute(.artist(slug: slug, name: attribute.name)) }
        default:
            openRoute(.tag(id: attribute.id, name: attribute.name))
        }
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            // Komifloのページは0始まり
            let response = try await library.api.searchContents(query: query, page: page)
            let known = Set(comics.map(\.id))
            comics += (response.results ?? []).map(\.summary).filter { !known.contains($0.id) }
            total = response.total
            page += 1
            totalPages = response.totalPages ?? page
            if response.results?.isEmpty ?? true { totalPages = page }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 雑誌一覧

enum MagazineShelfLayout {
    static let twoColumnsKey = "layout.magazineCoversTwoColumns"
}

/// 雑誌一覧（公式の「ラインアップ」と同じ）：スマホでは2列のタイル。
/// 各タイルは雑誌の画像をぼかして暗くした上に、雑誌のロゴ。特別号は一番下に横長の帯
struct MagazineShelfView: View {
    @ObservedObject var library: LibraryStore
    @AppStorage(MagazineShelfLayout.twoColumnsKey) private var coversTwoColumns = false
    /// ロゴのタイル（公式） / 最新号の表紙
    let style: Style

    @Environment(\.openRoute) private var openRoute
    /// 一度読んだ雑誌の一覧（ページを行き来するたびに読み直さない）
    @MainActor private static var cachedMagazines: [MagazineTitle]?
    @State private var state: LoadState<[MagazineTitle]>

    init(library: LibraryStore, style: Style) {
        self.library = library
        self.style = style
        _state = State(initialValue: Self.cachedMagazines.map { .loaded($0) } ?? .loading)
    }

    enum Style: String {
        case logo, cover
    }


    private let columns = [
        GridItem(.flexible(), spacing: 0),
        GridItem(.flexible(), spacing: 0),
    ]

    private var coverColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: OfficialMetrics.columnCount(coversTwoColumns ? 2 : 3))
    }

    var body: some View {
        LoadStateView(state: state, retry: load) { magazines in
            let regular = Self.ordered(magazines.filter { !$0.isSpecial })
            let special = magazines.first(where: \.isSpecial)
            ScrollView {
                VStack(spacing: 0) {

                    if style == .logo {
                        LazyVGrid(columns: columns, spacing: 0) {
                            ForEach(regular) { magazine in
                                Button {
                                    openRoute(.magazine(magazine))
                                } label: {
                                    MagazineTile(magazine: magazine)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(magazine.name)
                            }
                        }
                    } else {
                        LazyVGrid(columns: coverColumns, alignment: .leading, spacing: 20) {
                            ForEach(regular) { magazine in
                                Button {
                                    openRoute(.magazine(magazine))
                                } label: {
                                    MagazineCoverCell(magazine: magazine, library: library)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(magazine.name)
                            }
                        }
                        .padding(.horizontal, 15 * OfficialMetrics.scale)
                        .padding(.bottom, 20)
                    }
                    if let special {
                        // 公式と同じ、ピンクの文字の「特別号」の帯
                        Button {
                            openRoute(.magazine(special))
                        } label: {
                            Text("特別号")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 70)
                                .background(Theme.bar)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { if case .loading = state { await load() } }
    }

    private static func ordered(_ magazines: [MagazineTitle]) -> [MagazineTitle] {
        MagazineLineup.ordered(magazines, slug: { $0.slug })
    }

    private func load() async {
        // 前回保存した雑誌の一覧ですぐ表示し、裏で公式から取り直す
        if case .loading = state,
           let saved = try? await APICache.fromCache({ try await library.api.magazineRack() }), !saved.isEmpty {
            state = .loaded(saved)
        }
        do {
            let magazines = try await library.api.magazineRack()
            Self.cachedMagazines = magazines
            if case .loaded(let current) = state, current == magazines { return }
            state = .loaded(magazines)
        } catch {
            // 前回の一覧が出ていれば、取り直しに失敗してもそのまま
            if case .loaded = state { return }
            state = .failed(error.localizedDescription)
        }
    }
}

/// 雑誌のタイル（公式と同じく高さ100pt。画像をぼかして暗くし、ロゴを重ねる）
private struct MagazineTile: View {
    let magazine: MagazineTitle

    var body: some View {
        ZStack {
            Color(red: 91 / 255, green: 34 / 255, blue: 55 / 255)
            CachedImage(url: magazine.coverURL) { Color.clear }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .blur(radius: 8)
                .opacity(0.6)
                .clipped()
            Color(red: 34 / 255, green: 33 / 255, blue: 39 / 255).opacity(0.7)
            RadialGradient(
                colors: [.black.opacity(0.1), .black.opacity(0.35)],
                center: .center, startRadius: 0, endRadius: 110
            )
            MagazineLogo(slug: magazine.slug, name: magazine.name)
                .padding(.horizontal, MagazineLogo.tileHorizontalInset)
        }
        .frame(height: 100 * OfficialMetrics.scale)
        .clipped()
        .overlay(alignment: .topLeading) {
            if let published = magazine.latestPublished,
               Date().timeIntervalSince(published) < 7 * 24 * 60 * 60 {
                Text("NEW")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 表紙の表示のセル：最新号の表紙と、雑誌名・最新号の日付
private struct MagazineCoverCell: View {
    private static let publicationDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    let magazine: MagazineTitle
    @ObservedObject var library: LibraryStore

    @State private var coverURL: URL?

    init(magazine: MagazineTitle, library: LibraryStore) {
        self.magazine = magazine
        self.library = library
        // 一度調べた表紙は、画面を作った瞬間から出す
        _coverURL = State(initialValue: magazine.latestIssueID.flatMap { library.cachedIssueCover(issueID: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverImage(url: coverURL, placeholderTitle: magazine.name)
                .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 3)
                .overlay {
                    if let identity = MagazineIdentity.display(slug: magazine.slug, issue: magazine.name) {
                        MagazineThumbnailLogo(identity: identity, atBottom: true)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let published = magazine.latestPublished,
                       Date().timeIntervalSince(published) < 7 * 24 * 60 * 60 {
                        Text("NEW")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                            .padding(4)
                    }
                }
            Text(magazine.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let published = magazine.latestPublished {
                Text(Self.publicationDate.string(from: published))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            guard coverURL == nil, let issueID = magazine.latestIssueID else { return }
            coverURL = await library.issueCover(issueID: issueID)
        }
    }
}

/// 雑誌のロゴ。公式サイトの縦に並んだロゴ画像から、その雑誌の段だけを切り出す。
/// ロゴが無い雑誌は名前を文字で出す
struct MagazineLogo: View {
    let slug: String
    let name: String

    /// 公式の1段の比率。画像全体の高さは、ロゴの追加で変わるため固定しない。
    static let rowAspect: CGFloat = 1125 / 384
    static let tileHorizontalInset: CGFloat = 10

    static func tileLogoWidth(in pageWidth: CGFloat) -> CGFloat {
        max(0, pageWidth / 2 - tileHorizontalInset * 2)
    }

    var body: some View {
        if let row = MagazineIdentity.rows[slug] {
            CachedImage(url: MagazineLogoRaster.url, spriteRow: row) { Color.clear }
                .aspectRatio(Self.rowAspect, contentMode: .fit)
                .clipped()
                .accessibilityLabel(name)
        } else {
            Text(name)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

// MARK: - 雑誌のページ

/// 雑誌のページ（公式の /magazines/<雑誌> と同じ作り）：
/// 上に雑誌名の帯、その下に号ごとの見出しと、その号に載った話の表紙を横スクロールで
struct MagazineIssuesView: View {
    let magazine: MagazineTitle
    @ObservedObject var library: LibraryStore
    var headerImageURL: URL?
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState<[KFContent]> = .loading
    /// 号の棚は見えるところから少しずつ増やす
    @State private var visibleCount = 6
    @State private var headerThumbnail: TagHeaderThumbnail.Selection?

    var body: some View {
        ImageHeaderPage { width, layout, scroll in
            ImagePageHeader(artist: nil, title: magazine.name, total: issueCount,
                            width: width, layout: layout, scroll: scroll, isFollowing: false,
                            followAnimated: false, onFollow: nil, onBack: { dismiss() },
                            bannerURL: headerThumbnail?.url,
                            bannerFocus: headerThumbnail?.focus,
                            bannerProtectedHead: headerThumbnail?.protectedHead,
                            magazineBranding: MagazineIdentity.rows[magazine.slug] == nil ? nil
                                : MagazineHeaderBranding(slug: magazine.slug, name: magazine.name),
                            countUnit: "号",
                            sourceTrailingInset: 15 * OfficialMetrics.scale)
        } content: { _, width, minimumHeight in
            LoadStateView(state: state, retry: load) { issues in
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(issues.prefix(visibleCount)), id: \.id) { issue in
                        IssueShelf(issue: issue, library: library,
                                   magazine: magazine.isSpecial ? nil
                                       : MagazineIdentity.display(slug: magazine.slug, issue: magazine.name))
                            .onAppear {
                                if issue.id == issues.prefix(visibleCount).last?.id, visibleCount < issues.count {
                                    visibleCount += 6
                                }
                            }
                    }

                    if visibleCount < issues.count {
                        LoadingFooter()
                    } else {
                        endNote(issues)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .frame(width: width)
            .frame(minHeight: minimumHeight, alignment: .top)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { if case .loading = state { await load() } }
        .task(id: headerImageURL ?? magazine.coverURL) {
            let url = headerImageURL ?? magazine.coverURL
            do {
                let thumbnail = try await TagHeaderThumbnail.select(url: url)
                guard !Task.isCancelled else { return }
                headerThumbnail = thumbnail
            } catch {
                guard !Task.isCancelled else { return }
                headerThumbnail = url.map { .init(url: $0, focus: nil, protectedHead: nil) }
                library.actionError = error.localizedDescription
            }
        }
        .markErrorAlert(library)
        .refreshable { await load() }
    }

    private var issueCount: Int? {
        if case .loaded(let issues) = state { return issues.count }
        return nil
    }

    /// 最後に「これで全部」と分かるように
    private func endNote(_ issues: [KFContent]) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(issues.isEmpty
                 ? "公開中の号はありません"
                 : "Komifloで読めるバックナンバーは、この\(issues.count)号ですべてです")
                .font(.footnote.weight(.semibold))
            if let oldest = issues.last?.published, let newest = issues.first?.published, issues.count > 1 {
                Text("\(oldest.formatted(.dateTime.year().month())) 〜 \(newest.formatted(.dateTime.year().month()))に出た号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func load() async {
        do {
            let attributeIDs: [Int]
            if magazine.isSpecial {
                // 特別号の棚は、特別号・アンソロジーなどの分類をまとめたもの（サイトと同じ）
                attributeIDs = try await library.api.magazines()
                    .filter { attribute in
                        guard let slug = attribute.slug else { return false }
                        return slug == "xtc" || slug == "wani-anthology" || slug.hasSuffix("-special-issue")
                    }
                    .map(\.id)
            } else {
                attributeIDs = [try await library.api.attribute(slug: magazine.slug).id]
            }
            let calendar = Calendar(identifier: .gregorian)
            let newest = calendar.date(byAdding: .day, value: 2, to: Date())!
            let oldest = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))!
            let issues = try await library.api.magazineIssues(attributeIDs: attributeIDs, from: newest, to: oldest)
                .filter { $0.type == nil || $0.type == "volume" }
                .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            visibleCount = 6
            state = .loaded(issues)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// 号の中の作品一覧
struct IssueView: View {
    let issueID: Int
    let title: String
    @ObservedObject var library: LibraryStore

    @Environment(\.openRoute) private var openRoute
    @State private var state: LoadState<[ComicSummary]> = .loading

    var body: some View {
        LoadStateView(state: state, retry: load) { comics in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let cover = comics.first(where: { $0.title.contains("表紙") }) {
                        Button { openRoute(.comic(id: cover.id)) } label: {
                            HStack(alignment: .center, spacing: 16) {
                                CoverImage(url: cover.coverURL, placeholderTitle: title)
                                    .frame(width: 110)
                                    .modifier(HomeMagazineArtwork(comic: cover, enabled: true, library: library,
                                                                  atBottom: true, magazine: magazine))
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(title).font(.headline)
                                    Label("表紙の作品情報", systemImage: "chevron.right").font(.subheadline)
                                }
                                .foregroundStyle(Theme.accent)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 15)
                    }
                    Text("掲載作品").font(.headline).padding(.horizontal, 15)
                    ComicGrid(comics: comics.filter { !$0.title.contains("表紙") }, library: library,
                              showsTitles: true, showsMagazineLogo: true, magazine: magazine, magazineLogoAtBottom: true)
                }
                .padding(.vertical, 16)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        .task { if case .loading = state { await load() } }
    }

    private var magazine: MagazineIdentity? {
        MagazineIdentity.resolve(slug: nil, issue: title)
    }

    private func load() async {
        if let comics = await library.issueComics(issueID: issueID) {
            state = .loaded(comics)
        } else {
            state = .failed(KomifloAPIError.invalidResponse.localizedDescription)
        }
    }
}

// MARK: - タグ

struct TagListView: View {
    /// 公式のタグ一覧と同じ並び順
    enum TagSort: String, CaseIterable, Identifiable {
        case nameDesc = "name_desc", nameAsc = "name_asc", related, popular = "popular_desc"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .related: return "関連"
            case .nameAsc: return "名前順"
            case .nameDesc: return "名前の逆順"
            case .popular: return "人気順"
            }
        }
        /// キャッシュAPIのファイル名。関連順は名前順のデータを並べ替えて作る（公式と同じ）
        var cacheName: String { self == .related ? "name_asc" : rawValue }
    }

    /// 公式の「関連順」の並び（サイトの設定 tagRelatedSort と同じ順）
    private static let relatedOrder: [String] = [
        "jd", "jk", "hitozuma", "oneesan", "mini", "shota", "kyonyu", "hinnyu", "kanbotsuchikubi",
        "paizuri", "fellatio", "sixnine", "bukkake", "tekoki", "ashifechi", "shirifechi", "nakadashi",
        "shiofuki", "onanii", "omocha", "lotion", "anal", "inmou", "paipan", "shojo", "doutei", "bosei",
        "joseijoui", "gyakuten", "gyakutennashi", "renai", "couple", "osananajimi", "ane", "imouto",
        "futago", "harem", "fukusuu", "rankou", "bitch", "inran", "gyaru", "kyaba", "hightone",
        "kasshoku", "muchimuchi", "nioifechi", "kneehigh", "tights", "garter", "suit", "kateikyoushi",
        "jokyoushi", "ol", "office", "senpai", "kouhai", "doukyuusei", "gakuen", "seifuku", "taisougi",
        "kyouei", "sport", "shorthair", "ponytail", "osage", "mitsuami", "megane", "twintail", "maid",
        "tsundere", "ojousama", "costume", "nurse", "idol", "mizugi", "onsen", "wafuku", "gibo",
        "jukujo", "chijo", "yagai", "satsuei", "shuchi", "omorashi", "kimootoko", "shitsuke", "sm",
        "hard", "darkkei", "haitoku", "furin", "netori", "netorare", "netorase", "yuri", "lesplay",
        "otokonoko", "futanari", "seitenkan", "fantasy", "succubus", "ishukan", "kemomimi", "gyagu",
        "interview", "zennenreimuke", "original", "illustration", "colour", "hyoshi",
    ]

    /// 公式の「関連順」に並べる
    static func sortedByRelated(_ tags: [KFAttribute]) -> [KFAttribute] {
        let order = Dictionary(uniqueKeysWithValues: relatedOrder.enumerated().map { ($1, $0) })
        return tags.sorted { (order[$0.slug ?? ""] ?? Int.max) < (order[$1.slug ?? ""] ?? Int.max) }
    }

    let library: LibraryStore

    @Environment(\.openRoute) private var openRoute
    let sort: TagSort
    @State private var state: LoadState<[KFAttribute]> = .loading
    /// 絞り込みの文字（「さがす」の検索欄から渡される。検索欄は1つだけにする）
    let filter: String

    /// 一番上で下に引っぱったときの動き（「さがす」タブでは検索欄にカーソルを入れる）
    var onPullDown: (() -> Void)?

    init(library: LibraryStore, filter: String, sort: TagSort = .popular, onPullDown: (() -> Void)? = nil) {
        self.library = library
        self.filter = filter
        self.sort = sort
        self.onPullDown = onPullDown
    }

    var body: some View {
        tagList
        .task(id: sort) { await load() }
    }

    private var tagList: some View {
        LoadStateView(state: state, retry: load) { tags in
            let query = filter.trimmingCharacters(in: .whitespaces)
            let filtered = query.isEmpty ? tags : tags.filter { tag in
                tag.name.localizedCaseInsensitiveContains(query)
                    || (tag.searchTerms?.localizedCaseInsensitiveContains(query) ?? false)
                    || (tag.slug?.localizedCaseInsensitiveContains(query) ?? false)
            }
            List {
                Section {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, tag in
                        Button {
                            openRoute(.tag(id: tag.id, name: tag.name))
                        } label: {
                            HStack {
                                if sort == .popular, query.isEmpty {
                                    // 人気順のときは順位を出す（数値は作品数ではなく人気度なので出さない）
                                    Text("\(index + 1)")
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundStyle(index < 3 ? Theme.star : .secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .frame(minWidth: 28)
                                } else {
                                    Image(systemName: "tag.fill")
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 28)
                                }
                                Text(tag.name).foregroundStyle(.primary)
                                Spacer()
                                if sort != .popular {
                                    Text("\(tag.contentCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(8)
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .modifier(PullDownAction(action: onPullDown))
            .dismissesKeyboardOnScroll()
        }
    }

    private func load() async {
        do {
            var tags = try await library.api.tags(sort: sort.cacheName)
            if sort == .related {
                tags = Self.sortedByRelated(tags)
            }
            state = .loaded(tags)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

extension AttributeComicsView {
    /// 掛け合わせを変えたときに、最初から読み直す
    fileprivate func reload() async {
        comics = []
        page = 0
        totalPages = nil
        total = nil
        error = nil
        isLoading = false
        await loadMore()
    }
}

/// 掛け合わせるタグを選ぶ
struct TagPickerSheet: View {
    @ObservedObject var library: LibraryStore
    let baseName: String
    let excludedIDs: Set<Int>
    let initialTags: [KFAttribute]
    let onConfirm: ([KFAttribute]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tags: [KFAttribute] = []
    @State private var filter = ""
    @State private var selectedTags: [KFAttribute]

    init(library: LibraryStore, baseName: String, excludedIDs: Set<Int>,
         initialTags: [KFAttribute], onConfirm: @escaping ([KFAttribute]) -> Void) {
        self.library = library
        self.baseName = baseName
        self.excludedIDs = excludedIDs
        self.initialTags = initialTags
        self.onConfirm = onConfirm
        _selectedTags = State(initialValue: initialTags)
    }

    private var filtered: [KFAttribute] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return tags.filter { tag in
            !excludedIDs.contains(tag.id) && !selectedTags.contains(where: { $0.id == tag.id }) && (
                query.isEmpty
                    || tag.name.localizedCaseInsensitiveContains(query)
                    || (tag.searchTerms?.localizedCaseInsensitiveContains(query) ?? false)
                    || (tag.slug?.localizedCaseInsensitiveContains(query) ?? false)
            )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                InlineSearchField(text: $filter, prompt: "タグを絞り込み（ひらがな・英語も可）")
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                selectedCombination
                List(filtered) { tag in
                    Button {
                        selectedTags.append(tag)
                    } label: {
                        HStack {
                            Image(systemName: "tag.fill")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28)
                            // 人気順のデータの数値は人気度なので出さない
                            Text(tag.name).foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.background.ignoresSafeArea())
                .overlay {
                    if tags.isEmpty { ProgressView() }
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("タグを掛け合わせる")
            .navigationBarTitleDisplayMode(.inline)
            .darkNavigationBar()
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("決定") {
                        onConfirm(selectedTags)
                        dismiss()
                    }
                    .disabled(selectedTags.map(\.id) == initialTags.map(\.id))
                }
            }
            .task {
                tags = (try? await library.api.tags(sort: "popular_desc")) ?? []
            }
        }
    }

    private var selectedCombination: some View {
        FlowLayout(spacing: 8) {
            Text(baseName)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.accent, in: Capsule())
            ForEach(selectedTags) { tag in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedTags.removeAll { $0.id == tag.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("+ \(tag.name)")
                        Image(systemName: "xmark.circle.fill")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.3), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tag.name)を外す")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - 作家ギャラリー

/// 公式の作家ギャラリーと同じ：読み仮名順・20人ずつ・「あ行」などで絞り込み・新着の印
struct ArtistGalleryView: View {
    /// 公式の行ボタン（表示はカタカナ、APIにはひらがなを渡す：ア→あ、カ→か …）
    private static let kanaRows: [(label: String, value: String)] = [
        ("ア", "あ"), ("カ", "か"), ("サ", "さ"), ("タ", "た"), ("ナ", "な"),
        ("ハ", "は"), ("マ", "ま"), ("ヤ", "や"), ("ラ", "ら"), ("ワ", "わ"),
    ]

    let library: LibraryStore

    @Environment(\.openRoute) private var openRoute
    @AppStorage("artists.kana") private var storedKana = ""
    /// 「さがす」タブでは、行（ア・カ・…）ごとに1ページにして左右スワイプで切り替える。そのときはこの行に固定し、行のボタンは出さない
    var fixedKana: String?
    private var kana: String { fixedKana ?? storedKana }
    /// 一番上で下に引っぱったときの動き（「さがす」タブでは検索欄にカーソルを入れる）
    var onPullDown: (() -> Void)?

    @State private var artists: [KFAttribute] = []
    @State private var page = 0
    @State private var totalPages: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchText = ""
    /// 今の一覧がどの行（ア・カ・…）のものか
    @State private var loadedKana: String?
    /// 読み込んだ作家の一覧（行ごと）。端末内にも保存して、アプリを起動し直してもすぐ出す
    private var cache: ArtistGalleryCache { .shared }
    /// 「さがす」タブの共通の検索欄の文字。nil のとき（メニューから単独で開いたとき）だけ自分の検索欄を出す
    var externalQuery: String?

    private var hasMore: Bool { totalPages.map { page < $0 } ?? true }

    private var query: String { (externalQuery ?? searchText).trimmingCharacters(in: .whitespaces) }

    private var filteredArtists: [KFAttribute] {
        guard !query.isEmpty else { return artists }
        return artists.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.nameRead?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.slug?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    @State private var galleryProgress = PagerProgress()
    @State private var selectedKana = UserDefaults.standard.string(forKey: "artists.kana") ?? ""

    var body: some View {
        if fixedKana == nil {
            VStack(spacing: 0) {
                InlineSearchField(text: $searchText, prompt: "作家名で検索")
                    .padding(.horizontal, 8).padding(.top, 4)
                PagerTabs(items: [""] + Self.kanaRows.map(\.value), selection: $selectedKana,
                          progress: galleryProgress, scrolls: true, font: .footnote.weight(.semibold)) { value in
                    Self.kanaRows.first { $0.value == value }?.label ?? "All"
                }
                .padding(.vertical, 8)
                PagedView(items: [""] + Self.kanaRows.map(\.value), selection: $selectedKana,
                          commitsSelectionOnIdle: true, progress: galleryProgress) { value in
                    ArtistGalleryView(library: library, fixedKana: value, externalQuery: searchText)
                }
            }
            .onChange(of: selectedKana) { _, value in storedKana = value }
        } else {
            artistList
        }
    }

    private var artistList: some View {
        VStack(spacing: 0) {
            // 公式と同じ：作家の検索欄（「さがす」タブの中では共通の検索欄を使うので出さない）
            if externalQuery == nil {
                InlineSearchField(text: $searchText, prompt: "作家名で検索")
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }

            if artists.isEmpty, let error {
                EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
            } else if artists.isEmpty, !hasMore {
                EmptyState(title: "作家がいません", systemImage: "person.2", message: "\(kana)行の作家は見つかりませんでした。")
            } else if artists.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 公式の作家ギャラリーと同じ：横長の作家画像の上に作家名の帯を、すき間なく縦に並べる
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredArtists) { artist in
                            Button {
                                if let slug = artist.slug {
                                    openRoute(.artist(slug: slug, name: artist.name))
                                }
                            } label: {
                                ArtistBannerRow(artist: artist)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if artist.id == artists.last?.id { Task { await loadMore() } }
                            }
                        }
                        if isLoading {
                            LoadingFooter()
                        }
                    }
                }
                .modifier(PullDownAction(action: onPullDown))
            .dismissesKeyboardOnScroll()
            }
        }
        .task(id: kana) {
            // もう出している行なら何もしない（画面に戻ってくるたびに読み直さない）
            if loadedKana == kana, !artists.isEmpty { return }
            if let cached = cache.entry(for: kana) {
                artists = cached.artists
                page = cached.page
                totalPages = cached.totalPages
                loadedKana = kana
                // 保存してあった一覧は出したまま、裏で最初のページだけ取り直して新しい作家を反映する
                await refreshFirstPage(kana: kana)
                return
            }
            artists = []
            page = 0
            totalPages = nil
            error = nil
            await loadMore()
        }
        .task(id: query) {
            // 検索中は、まだ読み込んでいない作家も含めて全員から探す
            if !query.isEmpty { await loadMore() }
        }
        .onChange(of: isLoading) { _, loading in
            // 読み込み完了を合図に続きを読む。短いタイマーで待ち続けない。
            if !loading, hasMore, error == nil, !query.isEmpty || loadedKana != kana {
                Task { await loadMore() }
            }
        }
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        let requestedKana = kana
        do {
            let result = try await library.api.artists(kana: requestedKana.isEmpty ? nil : requestedKana, page: page)
            // 読み込み中に行を切り替えたら、古い結果は捨てる
            guard requestedKana == kana else { return }
            let known = Set(artists.map(\.id))
            artists += result.artists.filter { !known.contains($0.id) }
            page += 1
            totalPages = result.totalPages
            if result.artists.isEmpty { totalPages = page }
            loadedKana = requestedKana
            cache.store(.init(artists: artists, page: page, totalPages: totalPages), for: requestedKana)
        } catch {
            guard requestedKana == kana else { return }
            self.error = error.localizedDescription
        }
    }

    /// 最初のページだけ取り直して先頭に反映する（アプリを起動して最初の1回だけ。一覧は消さない）
    private func refreshFirstPage(kana requestedKana: String) async {
        guard cache.needsRefresh(requestedKana) else { return }
        guard let result = try? await library.api.artists(kana: requestedKana.isEmpty ? nil : requestedKana, page: 0),
              requestedKana == kana, !result.artists.isEmpty else { return }
        cache.markRefreshed(requestedKana)
        let freshIDs = Set(result.artists.map(\.id))
        let merged = result.artists + artists.filter { !freshIDs.contains($0.id) }
        if merged.map(\.id) != artists.map(\.id) { artists = merged }
        totalPages = result.totalPages
        cache.store(.init(artists: artists, page: page, totalPages: totalPages), for: requestedKana)
    }
}

/// 作家ギャラリーの一覧の保存場所（メモリと端末内）
@MainActor
final class ArtistGalleryCache {
    static let shared = ArtistGalleryCache()

    struct Entry: Codable {
        var artists: [KFAttribute]
        var page: Int
        var totalPages: Int?
    }

    private var entries: [String: Entry]
    /// このアプリの起動中に、もう取り直した行
    private var refreshed: Set<String> = []
    private let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ArtistGallery.json")
    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
    }

    func entry(for kana: String) -> Entry? { entries[kana] }

    func needsRefresh(_ kana: String) -> Bool { !refreshed.contains(kana) }

    func markRefreshed(_ kana: String) { refreshed.insert(kana) }

    func store(_ entry: Entry, for kana: String) {
        entries[kana] = entry
        refreshed.insert(kana)
        // 書き込みは少しまとめてから、画面の動きを止めないよう裏で行う
        saveTask?.cancel()
        let snapshot = entries
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - タグ・作者の作品一覧

/// タグ・作者の作品一覧（どちらも attribute の作品として取れる）
struct AttributeComicsView: View {
    enum Source {
        case tag(id: Int)
        /// slug しか分からないタグ（公式ホームのリンクなど）
        case tagSlug(slug: String)
        case artist(slug: String)
    }

    let source: Source
    let title: String
    @ObservedObject var library: LibraryStore

    @State private var attributeID: Int?
    @State private var displayName = ""
    @State private var comics: [ComicSummary] = []
    @State private var total: Int?
    @State private var page = 0
    @State private var totalPages: Int?
    @State private var isLoading = false
    @State private var error: String?
    /// タグの掛け合わせで足したタグ（公式の「タグA + タグB」）
    @State private var extraTags: [KFAttribute] = []
    @State private var isPickingTag = false
    @State private var pendingTags: [KFAttribute]?
    /// 作者の単行本（公式の作者ページと同じ）
    @State private var tankoubons: [KFContent] = []
    @State private var selectedTankoubonID: Int?
    @Environment(\.openURL) private var openURL

    private var hasMore: Bool { totalPages.map { page < $0 } ?? true }

    private var isTag: Bool {
        switch source {
        case .tag, .tagSlug: return true
        case .artist: return false
        }
    }

    private var screenTitle: String {
        let base = displayName.isEmpty ? title : displayName
        return ([base] + extraTags.map(\.name)).joined(separator: " + ")
    }

    var body: some View {
        VStack(spacing: 0) {
            if isTag {
                combinationBar
            }
            content
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $isPickingTag, onDismiss: applyPickedTags) {
            TagPickerSheet(
                library: library,
                baseName: displayName.isEmpty ? title : displayName,
                excludedIDs: Set([attributeID].compactMap { $0 }),
                initialTags: extraTags
            ) { tags in
                pendingTags = tags
            }
        }
    }

    private func applyPickedTags() {
        guard let pendingTags else { return }
        self.pendingTags = nil
        extraTags = pendingTags
        Task { await reload() }
    }

    /// 単行本の棚（漫画と同じ右→左）。タップで購入先を選ぶ
    private var tankoubonShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(tankoubons, id: \.id) { volume in
                    Button {
                        selectedTankoubonID = volume.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            CoverImage(url: volume.coverURL, placeholderTitle: volume.title ?? "")
                                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 3)
                            Text(volume.title ?? "")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2, reservesSpace: true)
                            if let releaseDate = volume.releaseDate {
                                Text(releaseDate.prefix(10).replacingOccurrences(of: "-", with: "/"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 100)
                    }
                    .buttonStyle(.plain)
                    .shelfItemContent()
                }
            }
            .padding(.horizontal, 16)
        }
        .mangaShelfDirection()
        .confirmationDialog(
            selectedTankoubon?.title ?? "単行本",
            isPresented: Binding(
                get: { selectedTankoubonID != nil },
                set: { if !$0 { selectedTankoubonID = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(selectedTankoubon?.purchaseLinks ?? [], id: \.self) { link in
                Button("\(link.store)で見る") { openURL(link.url) }
            }
        } message: {
            Text((selectedTankoubon?.purchaseLinks.isEmpty ?? true)
                 ? "購入先の情報がありません。"
                 : "単行本を買うと、手元に残して読めます。購入ページをブラウザで開きます。")
        }
    }

    private var selectedTankoubon: KFContent? {
        tankoubons.first { $0.id == selectedTankoubonID }
    }

    /// 掛け合わせ中のタグと「＋タグを掛け合わせる」
    private var combinationBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
                ForEach(extraTags) { tag in
                    Button {
                        extraTags.removeAll { $0.id == tag.id }
                        Task { await reload() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("+ \(tag.name)")
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.3), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tag.name)を外す")
                }
                Button {
                    isPickingTag = true
                } label: {
                    Label("タグを掛け合わせる", systemImage: "plus")
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.bar, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }

    private var content: some View {
        Group {
            if comics.isEmpty, let error {
                EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
            } else if comics.isEmpty, !hasMore, !extraTags.isEmpty {
                // 公式と同じ文言
                EmptyState(
                    title: "該当する作品がありません",
                    systemImage: "tag.slash",
                    message: "選んだタグの組み合わせに当てはまる作品はありませんでした。別のタグを試してください。"
                )
            } else if comics.isEmpty, !hasMore {
                EmptyState(title: "作品がありません", systemImage: "tray", message: "作品が見つかりませんでした。")
            } else if comics.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !tankoubons.isEmpty {
                        Section("単行本") {
                            tankoubonShelf
                                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        }
                    }
                    Section {
                        ForEach(comics) { comic in
                            ComicRow(comic: comic, library: library)
                                .onAppear {
                                    if comic.id == comics.last?.id { Task { await loadMore() } }
                                }
                        }
                    } header: {
                        if let total { Text("\(total)作品") }
                    } footer: {
                        if isLoading { LoadingFooter() }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        .toolbar {
            if let attributeID {
                ToolbarItem(placement: .topBarTrailing) {
                    // 公式の作家・タグページのフォローボタンと同じ
                    let isFollowing = library.followedIDs.contains(attributeID)
                    Button {
                        Task { await library.toggleFollow(attributeID: attributeID) }
                    } label: {
                        Label(
                            isFollowing ? "フォロー中" : "フォロー",
                            systemImage: isFollowing ? "checkmark.circle.fill" : "plus.circle"
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isFollowing ? Theme.accent : Color.primary)
                    }
                }
            }
        }
        .task { if comics.isEmpty { await loadMore() } }
        .task { if !library.hasLoadedFollows { await library.loadFollows() } }
        .task {
            if case .artist(let slug) = source, tankoubons.isEmpty {
                tankoubons = (try? await library.api.artistTankoubons(slug: slug)) ?? []
            }
        }
        .markErrorAlert(library)
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            if attributeID == nil {
                switch source {
                case .tag(let id):
                    attributeID = id
                case .tagSlug(let slug):
                    let tag = try await library.api.attribute(slug: slug)
                    attributeID = tag.id
                    displayName = tag.name
                case .artist(let slug):
                    let artist = try await library.api.attribute(slug: slug)
                    attributeID = artist.id
                    displayName = artist.name
                    total = artist.contentCount
                }
            }
            guard let attributeID else { return }
            // Komifloのページは0始まり。page は「読み込み済みのページ数」＝次に読むページ番号
            let ids = [attributeID] + extraTags.map(\.id)
            let response = try await library.api.attributeContents(attributeIDs: ids, page: page)
            // 読み込み中に掛け合わせを変えたら、古い結果は捨てる
            guard ids == [attributeID] + extraTags.map(\.id) else { return }
            let known = Set(comics.map(\.id))
            comics += (response.results ?? []).map(\.summary).filter { !known.contains($0.id) }
            if let responseTotal = response.total { total = responseTotal }
            page += 1
            totalPages = response.totalPages ?? page
            if response.results?.isEmpty ?? true { totalPages = page }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
