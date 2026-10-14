import SwiftUI

/// ホーム。公式ホーム（/attribute/slug/homepage）と同じセクションを、同じ順番・近い大きさで並べる。
/// 公式の並び：トップカルーセル → 新着・話題 → セカンドカルーセル → 新作ランキング → ロングヒット
/// → サードカルーセル → 特集2本 → 作家バナー → 残りの特集 → タグ
struct HomeView: View {
    @ObservedObject var library: LibraryStore
    let onOpenWeb: (URL) -> Void

    @Environment(\.openRoute) private var openRoute
    @Environment(\.openURL) private var openURL

    @State private var topBanners: [HomeBanner] = []
    @State private var secondBanners: [HomeBanner] = []
    @State private var thirdBanners: [HomeBanner] = []
    @State private var artistBanners: [HomeBanner] = []
    @State private var featured: [HomeShelf] = []
    @State private var homeTags: [KFAttribute] = []
    @State private var isLoading = false
    @State private var loadError: String?
    /// バナーを読み終えたか（読み終えるまでは、同じ高さの仮の枠で場所を確保して、表示がずれないようにする）
    @State private var didLoadBanners = false

    /// まだ何も届いていない間は、公式ホームと同じ並びで仮の枠を出しておく
    private var showsPlaceholders: Bool { loadError == nil && (isLoading || !didLoadBanners) }

    /// 上の切り替え：ホームと、ホームのバナーを集めたピックアップ
    enum Page: String, CaseIterable, Hashable {
        case home = "ホーム"
        case pickup = "ピックアップ"
    }

    @State private var page: Page = .home
    @State private var tabProgress = PagerProgress()
    /// 一覧の切り替えを画面の下に出す（アプリ設定で共通。既定は上）
    @AppStorage(ControlsPosition.key) private var controlsAtBottom = false

    /// 上の切り替えを、一覧のスクロールに合わせて押し出す・引き出す（帯だけが購読し、一覧は描き直さない）
    @State private var reveal = SwitcherReveal()
    @State private var switcherHeight: CGFloat = 48

    /// 上の切り替えの分だけ、一覧の先頭を下げる（切り替えは一覧の上に重ねるので、隠しても一覧はずれない）
    private var topBarSpace: CGFloat { controlsAtBottom ? 0 : switcherHeight }

    private var switcher: some View {
        PagerTabs(items: Page.allCases, selection: $page, progress: tabProgress, title: { $0.rawValue })
    }

    var body: some View {
        // 3.32.270までのホームと同じく、一覧はタブバーの下まで描く（ページを安全領域で切ると、タブバーの後ろが黒帯になる）。
        // 最後の行がタブバーに隠れないよう、下の余白は一覧の内側に付ける
        GeometryReader { outer in
            let bottomInset = outer.safeAreaInsets.bottom
            // 2ページとも同じ取得結果を使う。ピックアップのために追加の通信はしない
            PagedView(items: Page.allCases, selection: $page, keepsPagesAlive: true, commitsSelectionOnIdle: true,
                      progress: tabProgress) { item in
                switch item {
                case .home: homePage(bottomInset: bottomInset)
                case .pickup:
                    PickupBannerList(sections: pickupSections, isLoading: showsPlaceholders,
                                     loadError: loadError, topInset: topBarSpace, bottomInset: bottomInset,
                                     onTap: open, onReload: { await load(force: true) },
                                     onScroll: { scrolled(.pickup, offset: $0) },
                                     onScrollPhase: { scrollPhase(.pickup, moving: $0, touching: $1) })
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .top) {
            if !controlsAtBottom {
                RevealingBar(reveal: reveal) {
                    switcher
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.background)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            reveal.height = height
                            if switcherHeight != height { switcherHeight = height }
                        }
                }
            }
        }
        // ページを切り替えたら、切り替えを出し直す
        .onChange(of: page) { _, _ in reveal.show() }
        .safeAreaInset(edge: .bottom) {
            if controlsAtBottom {
                BottomControlBar { switcher }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("ホーム")
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        // 右上のプロフィールメニューはやめ、公式と同じメニュー（左上の☰）に移した
        // 作家ページを開いても、ホームの取得を途中で打ち切らない。
        .onAppear {
            Task { _ = await ImageCache.shared.thumbnail(for: MagazineLogoRaster.url) }
            Task { await load() }
        }
        .markErrorAlert(library)
    }

    /// ピックアップの区分（公式ホームのカルーセルの種類ごと）。空の区分は出さない
    private var pickupSections: [PickupBannerList.Section] {
        [
            // 縦横比はホームでの表示と同じ（トップ375×162、セカンド・サード267×115、作家375×121）
            .init(title: "雑誌", banners: topBanners, isArtist: false, aspect: 375 / 162, collapsible: true),
            .init(title: "特集", banners: secondBanners, isArtist: false, aspect: 267 / 115),
            .init(title: "ストア", banners: thirdBanners, isArtist: false, aspect: 267 / 115),
            .init(title: "作家", banners: artistBanners, isArtist: true, aspect: 375 / 121),
        ].filter { !$0.banners.isEmpty }
    }

    /// 一覧のスクロール量（下へ進むほど大きい）が変わったときだけ呼ばれる。表示中のページの動きだけを帯へ伝える
    /// 指で動かしている・惰性で動いている間かを帯へ伝える（iOS 18以降）
    private func scrollPhase(_ item: Page, moving: Bool, touching: Bool) {
        guard item == page, !controlsAtBottom else { return }
        reveal.setUserScrolling(moving, touching: touching)
    }

    private func scrolled(_ item: Page, offset: CGFloat) {
        guard item == page, !controlsAtBottom else { return }
        reveal.scrolled(item, offset: offset)
    }

    private func homePage(bottomInset: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !topBanners.isEmpty {
                    TopCarousel(banners: topBanners, onTap: open)
                } else if !didLoadBanners, loadError == nil {
                    BannerPlaceholder(height: 178 * OfficialMetrics.scale)
                }

                featuredShelf(0)
                bannerRow(secondBanners)
                featuredShelf(1)
                featuredShelf(2)
                bannerRow(thirdBanners)
                featuredShelf(3)
                featuredShelf(4)
                if !artistBanners.isEmpty {
                    ArtistBannerCarousel(banners: artistBanners, onTap: open)
                } else if !didLoadBanners, loadError == nil {
                    BannerPlaceholder(height: 135 * OfficialMetrics.scale)
                }
                ForEach(Array(featured.indices.dropFirst(5)), id: \.self) { index in
                    featuredShelf(index)
                }

                if !homeTags.isEmpty {
                    tagSection
                }

                if let loadError, featured.isEmpty {
                    VStack(spacing: 12) {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("再読み込み") { Task { await load(force: true) } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 12)
            // iOS 17だけ、内容の位置からスクロール量を読む（iOS 18以降はScrollOffsetReader）
            .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .scrollView).minY } action: { value in
                if #unavailable(iOS 18.0) { scrolled(.home, offset: value) }
            }
        }
        // 先頭で0・引っ張ると負になるスクロール量を、上の切り替えの表示に使う
        .modifier(ScrollOffsetReader { scrolled(.home, offset: $0) })
        .modifier(ScrollPhaseObserver { scrollPhase(.home, moving: $0, touching: $1) })
        .contentMargins(.top, topBarSpace)
        .contentMargins(.bottom, bottomInset)
        .refreshable { await load(force: true) }
    }

    // MARK: - セクション

    @ViewBuilder
    private func featuredShelf(_ index: Int) -> some View {
        if featured.indices.contains(index) {
            let shelf = featured[index]
            if !shelf.comics.isEmpty {
                CoverShelf(
                    title: shelf.title,
                    comics: shelf.comics,
                    library: library,
                    ranked: shelf.ranked,
                    moreRoute: shelf.moreRoute,
                    showsMagazineLogo: true
                )
            } else if !shelf.isLoaded {
                // 中身が届くまで、同じ高さの仮の棚で場所を確保する
                ShelfPlaceholder(title: shelf.title)
            }
        } else if featured.isEmpty, showsPlaceholders, index < 5 {
            ShelfPlaceholder(title: "")
        }
    }

    /// 宣伝バナーの行（読み込み中は同じ高さの仮の枠）
    @ViewBuilder
    private func bannerRow(_ banners: [HomeBanner]) -> some View {
        if !banners.isEmpty {
            SmallBannerRow(banners: banners, onTap: open)
        } else if !didLoadBanners, loadError == nil {
            BannerPlaceholder(height: 131 * OfficialMetrics.scale, inset: true)
        }
    }

    /// 公式ホームの一番下のタグ
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("タグから探す")
                .font(.title3.weight(.bold))
            FlowLayout(spacing: 8) {
                ForEach(homeTags) { tag in
                    Button {
                        openRoute(.tag(id: tag.id, name: tag.name))
                    } label: {
                        Text(tag.name)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.bar, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// バナーのリンク先を開く（アプリにある画面はアプリで、無いものはブラウザ表示で）
    private func open(_ banner: HomeBanner) {
        if let route = banner.route {
            switch route {
            case .collection, .tag, .tagSlug, .magazine, .deliveryCalendar:
                if let imageURL = banner.imageURL {
                    openRoute(.banner(destination: route, imageURL: imageURL))
                } else {
                    openRoute(route)
                }
            default:
                openRoute(route)
            }
            return
        }
        guard let href = banner.href, !href.isEmpty else { return }
        if href.hasPrefix("http"), let url = URL(string: href) {
            let host = url.host?.lowercased() ?? ""
            if host == "komiflo.com" || host.hasSuffix(".komiflo.com") {
                onOpenWeb(url)
            } else {
                openURL(url)
            }
        } else if let url = URL(string: "https://komiflo.com/#!" + (href.hasPrefix("/") ? href : "/" + href)) {
            onOpenWeb(url)
        }
    }

    // MARK: - 読み込み

    /// ホームの中身をまとめたもの（揃ってから一度に差し替えるので、更新しても表示がちらつかない）
    private struct HomeContent {
        var top: [HomeBanner] = []
        var second: [HomeBanner] = []
        var third: [HomeBanner] = []
        var artists: [HomeBanner] = []
        var featured: [HomeShelf] = []
        var tags: [KFAttribute] = []
    }

    /// 起動したとき：前回保存した内容をすぐ出し、裏で公式から取り直して、届いたら差し替える。
    /// 引っぱって更新したとき（force）：今の表示のまま公式から取り直して差し替える
    private func load(force: Bool = false) async {
        // 最近読んだ作品・★♥は裏で更新する
        Task {
            if force {
                await library.loadMore(.history, reset: true)
            } else if !library.history.hasLoaded {
                await library.restoreFromCache(.history)
                await library.refreshTop(.history)
            } else {
                await library.refreshTop(.history)
            }
        }
        Task { await library.refreshMarks() }

        guard force || featured.isEmpty, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let api = library.api
        if featured.isEmpty, topBanners.isEmpty,
           let saved = try? await APICache.fromCache({ try await Self.fetchHome(api: api) }) {
            guard !Task.isCancelled else { return }
            // 前回の内容（通信しないのですぐ出る）
            apply(saved)
        }
        do {
            let content = try await Self.fetchHome(api: api)
            try Task.checkCancellation()
            apply(content)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            // 取り直せなくても、前回の内容が出ていればそのまま
            if featured.isEmpty, topBanners.isEmpty {
                loadError = error.localizedDescription
            }
            didLoadBanners = true
        }
    }

    private func apply(_ content: HomeContent) {
        topBanners = content.top
        secondBanners = content.second
        thirdBanners = content.third
        artistBanners = content.artists
        featured = content.featured
        homeTags = content.tags
        didLoadBanners = true
        HomeBanner.updateMagazineBanners(content.top)
    }

    /// 公式ホームと同じ取り方で、バナー・特集の棚・タグをまとめて取る
    @MainActor
    private static func fetchHome(api: KomifloAPI) async throws -> HomeContent {
        let sections = try await api.homepageSections()
        func section(_ slug: String) -> KFAttribute? { sections.first { $0.slug == slug } }

        async let top = HomeBanner.load(section: section("carousel"), api: api)
        async let second = HomeBanner.load(section: section("second_carousel"), api: api)
        async let third = HomeBanner.load(section: section("third_carousel"), api: api)
        async let artists = HomeBanner.load(section: section("homepage-artists"), api: api, isArtist: true)

        var featured: [HomeShelf] = []
        if let featuredSection = section("featured-tags"),
           let shelves = try? await api.cachedAttribute(id: featuredSection.id).siblings {
            featured = shelves.map { HomeShelf(attribute: $0) }
            await withTaskGroup(of: (Int, [ComicSummary]).self) { group in
                for (index, shelf) in shelves.enumerated() {
                    group.addTask { (index, await HomeShelf.loadComics(for: shelf, api: api)) }
                }
                for await (index, comics) in group where featured.indices.contains(index) {
                    featured[index].comics = comics
                    featured[index].isLoaded = true
                }
            }
        }

        var tags: [KFAttribute] = []
        if let tagsSection = section("homepage-tags") {
            tags = (try? await api.cachedAttribute(id: tagsSection.id).siblings) ?? []
        }

        let content = HomeContent(
            top: await top,
            second: await second,
            third: await third,
            artists: await artists,
            featured: featured,
            tags: tags
        )
        // 子の取得が中断されて空になっても、完成したホームとして渡さない。
        try Task.checkCancellation()
        return content
    }
}

// MARK: - データ

/// 公式ホームのバナー（カルーセル・作家バナー）
struct HomeBanner: Identifiable {
    let id: Int
    let name: String
    let href: String?
    let imageURL: URL?
    let route: Route?

    /// トップカルーセル（ピックアップの「雑誌」）の雑誌バナー。雑誌のページの帯に使う（slugで引く）
    @MainActor static private(set) var magazineBanners: [String: URL] = [:]

    /// ホームを読み直すたび（保存してある前回の分→公式の最新）に入れ替え、いつも最新のバナーを使う。
    /// カルーセルから外れた雑誌のバナーも残さない
    @MainActor static func updateMagazineBanners(_ banners: [HomeBanner]) {
        var latest: [String: URL] = [:]
        for banner in banners {
            guard case .magazine(let magazine) = banner.route, let url = banner.imageURL,
                  latest[magazine.slug] == nil else { continue }
            latest[magazine.slug] = url
        }
        guard !latest.isEmpty else { return }
        magazineBanners = latest
    }

    /// セクションの中身（siblings）を取り、1枚ずつバナー画像を取る（公式と同じ順番）
    @MainActor
    static func load(section: KFAttribute?, api: KomifloAPI, isArtist: Bool = false) async -> [HomeBanner] {
        guard let section, let items = try? await api.cachedAttribute(id: section.id).siblings else { return [] }
        var images: [Int: URL] = [:]
        await withTaskGroup(of: (Int, URL?).self) { group in
            for item in items {
                group.addTask { (item.id, try? await api.attributeInfo(id: item.id).bannerURL) }
            }
            for await (id, url) in group {
                if let url { images[id] = url }
            }
        }
        return items.map { item in
            let route: Route?
            if isArtist, let slug = item.slug {
                route = .artist(slug: slug, name: item.name)
            } else {
                route = item.href.flatMap { Route(sitePath: $0, title: item.name) }
            }
            return HomeBanner(id: item.id, name: item.name, href: item.href, imageURL: images[item.id], route: route)
        }
    }
}

/// 公式ホームの特集の棚
struct HomeShelf: Identifiable {
    let id: Int
    let slug: String
    let title: String
    var comics: [ComicSummary] = []
    /// 中身を読み終えたか（読み終えるまでは仮の棚を出す）
    var isLoaded = false

    init(attribute: KFAttribute) {
        id = attribute.id
        slug = attribute.slug ?? ""
        title = attribute.name
    }

    var ranked: Bool { slug == "most-popular-recent" }

    /// 特別な棚は同じ取得条件の一覧、それ以外は既存のタグページへ開く。
    var moreRoute: Route? {
        if let kind = HomeShelfKind(rawValue: slug) {
            return .homeShelf(id: id, kind: kind, name: title, homeComics: comics)
        }
        return .tag(id: id, name: title,
                    options: TagListingOptions(fromTop: slug != "original", filter: "-plus"), homeComics: comics)
    }

    /// 公式ホームと同じ取り方で棚の作品を取る
    @MainActor
    static func loadComics(for shelf: KFAttribute, api: KomifloAPI) async -> [ComicSummary] {
        let contents: [KFContent]
        var shuffles = true
        if let kind = shelf.slug.flatMap(HomeShelfKind.init(rawValue:)) {
            let response = try? await api.homeShelfContents(kind: kind, attributeID: shelf.id, page: 0)
            contents = kind.ordered(response?.results ?? [], attributeID: shelf.id)
            shuffles = false
        } else {
            contents = (try? await api.cachedAttribute(id: shelf.id).content) ?? []
            // 公式は「オリジナル」だけ並べ替えない
            if shelf.slug == "original" { shuffles = false }
        }
        var comics = contents.map(\.summary)
        if shuffles {
            // 公式と同じく、日替わりで並びを変える（同じ日のうちは同じ並び）
            var generator = DailyShuffle(seed: shelf.id)
            comics = generator.shuffle(comics)
        }
        return Array(comics.prefix(20))
    }
}

/// 日替わりの並び替え（日本時間の朝5時で切り替わる）。乱数は seedrandom（ARC4）と互換
struct DailyShuffle {
    private var bytes = Array(0..<256)
    private var i = 0
    private var j = 0

    init(seed: Int, date: Date = Date(), calendar: Calendar = .current) {
        let day = calendar.component(.day, from: date.addingTimeInterval(-5 * 3600))
        let text = "\(seed)_\(String(format: "%02d", day))"
        var key = [Int](repeating: 0, count: text.utf16.count)
        var mixed = 0
        for (index, character) in text.utf16.enumerated() {
            mixed ^= key[index] * 19
            key[index] = (mixed + Int(character)) & 255
        }
        var position = 0
        for index in 0..<256 {
            position = (position + key[index % key.count] + bytes[index]) & 255
            bytes.swapAt(index, position)
        }
        for _ in 0..<256 { _ = byte() }
    }

    private mutating func byte() -> Int {
        i = (i + 1) & 255
        j = (j + bytes[i]) & 255
        bytes.swapAt(i, j)
        return bytes[(bytes[i] + bytes[j]) & 255]
    }

    private mutating func random() -> Double {
        var numerator = 0.0
        for _ in 0..<6 { numerator = numerator * 256 + Double(byte()) }
        var denominator = 281474976710656.0
        var extra = 0
        while numerator < 4503599627370496 {
            numerator = (numerator + Double(extra)) * 256
            denominator *= 256
            extra = byte()
        }
        while numerator >= 9007199254740992 {
            numerator /= 2
            denominator /= 2
            extra >>= 1
        }
        return (numerator + Double(extra)) / denominator
    }

    mutating func shuffle<T>(_ values: [T]) -> [T] {
        var result = values
        for index in result.indices {
            let other = index + Int((random() * Double(result.count - index)).rounded(.down))
            result.swapAt(index, other)
        }
        return result
    }
}

// MARK: - バナーの表示（公式の大きさに合わせる）

/// トップカルーセル：公式のスマホ表示と同じく全幅・高さ162pt（375pt幅のとき）。
/// 画像は高さに合わせて中央を切り出す。下にページの点。自動でめくれる
private struct TopCarousel: View {
    let banners: [HomeBanner]
    let onTap: (HomeBanner) -> Void

    @State private var index = 0
    /// 公式と同じ3.2秒ごとの自動送り
    private let timer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    var body: some View {
        // 勢いの弱いスワイプでも途中で止まらない、アプリ共通のページ送り
        PagedView(items: Array(banners.indices), selection: $index, showsIndicator: true) { offset in
            BannerImage(banner: banners[offset], height: 162 * OfficialMetrics.scale, cornerRadius: 0)
                .frame(maxHeight: .infinity, alignment: .top)
                .onTapGesture { onTap(banners[offset]) }
        }
        .frame(height: 178 * OfficialMetrics.scale)
        .onReceive(timer) { _ in
            guard banners.count > 1 else { return }
            withAnimation { index = (index + 1) % banners.count }
        }
    }
}

/// セカンド・サードカルーセル：公式のスマホ表示と同じく1枚が281×115pt（375pt幅のとき）。
/// 次のバナーが右に少し見える横スクロール
private struct SmallBannerRow: View {
    let banners: [HomeBanner]
    let onTap: (HomeBanner) -> Void

    @State private var currentID: Int?
    private let timer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(banners) { banner in
                    // 公式と同じく、281ptの枠の中に角丸10・幅267の画像を左6ptあけて置く（バナー同士にすき間ができる）
                    BannerImage(banner: banner, height: 115 * OfficialMetrics.scale, cornerRadius: 10)
                        .frame(width: 267 * OfficialMetrics.scale)
                        .padding(.leading, 6 * OfficialMetrics.scale)
                        .padding(.trailing, 8 * OfficialMetrics.scale)
                        .onTapGesture { onTap(banner) }
                        .id(banner.id)
                }
            }
            .scrollTargetLayout()
        }
        // 公式と同じく、1回のスワイプで次のバナーにきっちり止まる（勢いよくはじいても1枚ずつ）
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        // 3.2秒ごとに次のバナーへ自動で進む（最後まで行ったら先頭へ）。指で動かしたら、そこから続ける
        .scrollPosition(id: $currentID, anchor: .leading)
        .onReceive(timer) { _ in
            guard banners.count > 1 else { return }
            let index = banners.firstIndex { $0.id == currentID } ?? 0
            let next = banners[(index + 1) % banners.count].id
            withAnimation(.easeInOut(duration: 0.5)) { currentID = next }
        }
        .frame(height: 131 * OfficialMetrics.scale, alignment: .top)
    }
}

/// 作家バナー：スマホでは全幅（1250×434）。作家名つき
private struct ArtistBannerCarousel: View {
    let banners: [HomeBanner]
    let onTap: (HomeBanner) -> Void

    @State private var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 公式のスマホ表示と同じく全幅・高さ121pt（375pt幅のとき）。見出しは無く、各バナーに作家名
            PagedView(items: Array(banners.indices), selection: $index, showsIndicator: true) { offset in
                let banner = banners[offset]
                BannerImage(banner: banner, height: 121 * OfficialMetrics.scale, cornerRadius: 0)
                        .overlay(alignment: .bottomLeading) {
                            Text(banner.name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                                )
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .onTapGesture { onTap(banner) }
            }
            .frame(height: 135 * OfficialMetrics.scale)
            // 公式と同じく3.2秒ごとに次の作家へ（最後の次は最初に戻る）
            .onReceive(timer) { _ in
                guard banners.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    index = (index + 1) % banners.count
                }
            }
        }
    }

    private let timer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()
}

/// ピックアップ：ホームのカルーセル・作家バナーを、種類ごとにホームと同じ縦横比で縦に並べる。
/// iPadなど幅が広いときは2列以上にする
private struct PickupBannerList: View {
    struct Section: Identifiable {
        let title: String
        let banners: [HomeBanner]
        let isArtist: Bool
        /// ホームで表示しているときと同じ縦横比（画像は中央を切り出す）
        let aspect: CGFloat
        /// 雑誌の区分だけ、見出しで折りたためる
        var collapsible = false
        var id: String { title }
    }

    /// アプリ設定「ピックアップの雑誌を折りたたむ」（標準オン）。開いた・閉じた操作は画面を作り直すまで優先する
    @AppStorage(PickupSettings.collapsesMagazinesKey) private var collapsesMagazines = true
    @State private var magazinesExpanded: Bool?
    private var showsMagazines: Bool { magazinesExpanded ?? !collapsesMagazines }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.sectionTitle)
            .padding(.leading, 15)
    }

    let sections: [Section]
    let isLoading: Bool
    let loadError: String?
    /// 上に重ねた切り替えの高さと、タブバーの高さ（一覧の内側の余白にする）
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onTap: (HomeBanner) -> Void
    let onReload: () async -> Void
    /// 先頭で0・引っ張ると負になるスクロール量（変わったときだけ）
    let onScroll: (CGFloat) -> Void
    /// 指で動かしている・惰性で動いている間か、指が触れている間か（iOS 18以降）
    let onScrollPhase: (_ moving: Bool, _ touching: Bool) -> Void

    /// 一覧の幅。iPadなど広いときは、1枚320pt以上を保てる数だけ横に並べる
    @State private var width: CGFloat = 0
    private var columnCount: Int { max(1, Int((width - 32 + 12) / (320 + 12))) }

    var body: some View {
        ScrollView {
            // 上へ戻ったときに行を作り直して位置が補正されると、帯がスクロールと誤って動くため、
            // 数十枚のバナーは最初からすべて並べる（遅延表示の一覧にしない）
            VStack(alignment: .leading, spacing: 28) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if section.collapsible {
                            // 見出しを押すと開く・閉じる
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { magazinesExpanded = !showsMagazines }
                            } label: {
                                HStack(spacing: 6) {
                                    title(section.title)
                                    Spacer()
                                    Image(systemName: showsMagazines ? "chevron.up" : "chevron.down")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Theme.sectionTitle)
                                }
                                .padding(.trailing, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(showsMagazines ? "開いています" : "閉じています")
                        } else {
                            title(section.title)
                        }
                        if !section.collapsible || showsMagazines {
                            VStack(spacing: 12) {
                                ForEach(rows(section.banners), id: \.first?.id) { row in
                                    HStack(alignment: .top, spacing: 12) {
                                        ForEach(row) { banner in
                                            card(banner, isArtist: section.isArtist, aspect: section.aspect)
                                        }
                                        // 最後の行が欠けても、1枚の幅は他の行と同じにする
                                        ForEach(row.count..<columnCount, id: \.self) { _ in
                                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                if sections.isEmpty {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            VStack(spacing: 12) {
                                Text(loadError ?? "表示できるバナーがありません。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Button("再読み込み") { Task { await onReload() } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .scrollView).minY } action: { value in
                if #unavailable(iOS 18.0) { onScroll(value) }
            }
        }
        .modifier(ScrollOffsetReader(onChange: onScroll))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
            if width != value { width = value }
        }
        .modifier(ScrollPhaseObserver(onChange: onScrollPhase))
        .contentMargins(.top, topInset)
        .contentMargins(.bottom, bottomInset)
        .refreshable { await onReload() }
    }

    private func rows(_ banners: [HomeBanner]) -> [[HomeBanner]] {
        stride(from: 0, to: banners.count, by: columnCount).map {
            Array(banners[$0..<min($0 + columnCount, banners.count)])
        }
    }

    private func card(_ banner: HomeBanner, isArtist: Bool, aspect: CGFloat) -> some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                CachedImage(url: banner.imageURL) {
                    ZStack {
                        LinearGradient(colors: [Theme.placeholder, Theme.bar], startPoint: .leading, endPoint: .trailing)
                        Text(banner.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
            // 作家バナーはホームと同じく下に作家名を重ねる
            .overlay(alignment: .bottomLeading) {
                if isArtist {
                    Text(banner.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { onTap(banner) }
            .accessibilityLabel(banner.name)
            .accessibilityAddTraits(.isButton)
    }
}

/// 読み込み中のバナーの仮の枠（本物と同じ高さで場所を確保し、表示がずれないようにする）
private struct BannerPlaceholder: View {
    let height: CGFloat
    /// 宣伝バナーの行のように、左に少し余白があって角が丸い枠
    var inset = false

    var body: some View {
        RoundedRectangle(cornerRadius: inset ? 10 : 0)
            .fill(Theme.bar)
            .frame(height: inset ? 115 * OfficialMetrics.scale : height - 16 * OfficialMetrics.scale)
            .padding(.leading, inset ? 6 * OfficialMetrics.scale : 0)
            .padding(.trailing, inset ? 94 * OfficialMetrics.scale : 0)
            .frame(height: height, alignment: .top)
            .redacted(reason: .placeholder)
    }
}

/// 読み込み中の棚の仮の表示（本物の棚と同じ高さ）
private struct ShelfPlaceholder: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.isEmpty ? " " : title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.sectionTitle)
                .padding(.horizontal, 15)
            HStack(alignment: .top, spacing: OfficialMetrics.cardSpacing) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        Color.clear
                            .aspectRatio(coverAspect, contentMode: .fit)
                            .background(Theme.bar, in: RoundedRectangle(cornerRadius: 4))
                        // 作者名とコメントアイコンの行と同じ高さ
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.bar)
                            .frame(width: OfficialMetrics.cardWidth * 0.6, height: 14)
                            .frame(height: 22, alignment: .leading)
                    }
                    .frame(width: OfficialMetrics.cardWidth)
                }
            }
            .padding(.horizontal, OfficialMetrics.shelfInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }
}

/// バナー画像（読み込み中・画像なしのときは名前入りの帯）
private struct BannerImage: View {
    let banner: HomeBanner
    /// 公式と同じく高さを決め、画像は高さに合わせて中央を切り出す
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                CachedImage(url: banner.imageURL) {
                    ZStack {
                        LinearGradient(colors: [Theme.placeholder, Theme.bar], startPoint: .leading, endPoint: .trailing)
                        Text(banner.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(Rectangle())
            .accessibilityLabel(banner.name)
            .accessibilityAddTraits(.isButton)
    }
}

/// ホームのピックアップの設定
enum PickupSettings {
    /// 雑誌の区分を最初は閉じておく（標準オン）
    static let collapsesMagazinesKey = "layout.pickupCollapsesMagazines"
}

/// 上の切り替えの出入り。一覧が動いた分だけ帯を押し出し・引き出す（0で全部見え、heightで隠れきる）
final class SwitcherReveal: ObservableObject {
    @Published private(set) var hidden: CGFloat = 0
    var height: CGFloat = 48
    /// ページごとの直前のスクロール量と、表示中のページの現在量
    private var offsets: [AnyHashable: CGFloat] = [:]
    private var current: CGFloat = 0
    /// 指で動かしている・惰性で動いている間か。iOS 17は知らせが無いので常に追従する
    private var userScrolling: Bool = {
        if #available(iOS 18.0, *) { return false }
        return true
    }()

    /// 最後に動いた向き（上へ戻したならtrue）。指を離したときの寄せ方に使う
    private var revealing = false

    /// moving：指で動かしている・惰性で動いている間。touching：指が触れている間
    func setUserScrolling(_ moving: Bool, touching: Bool) {
        let released = userScrolling && !touching
        userScrolling = moving
        // 指を離したら、途中で止まっている帯を最後に動かした向きへ寄せる
        if released { settle() }
    }

    func scrolled(_ page: AnyHashable, offset: CGFloat) {
        let previous = offsets[page] ?? offset
        offsets[page] = offset
        current = offset
        // 指以外の位置の補正では帯を動かさない（先頭付近で一覧の上に隠れたままにはしない）
        guard userScrolling else {
            set(min(hidden, max(0, offset)))
            return
        }
        if offset != previous { revealing = offset < previous }
        // 先頭付近では、一覧の先頭と一緒に帯も戻ってくる（一覧の上に隠れたままにしない）
        set(min(max(0, hidden + offset - previous), height, max(0, offset)))
    }

    /// 途中で止まった帯を、最後に動かした向きへ寄せる（上へ戻していたら全部出し、下へ進めていたら隠す）。
    /// 距離で近い方へ寄せると、少しだけ上へ戻したときに出かけた帯がまた隠れてしまう
    private func settle() {
        guard hidden > 0, hidden < height else { return }
        let target: CGFloat = !revealing && current >= height ? height : 0
        withAnimation(.easeOut(duration: 0.2)) { set(target) }
    }

    func show() {
        guard hidden != 0 else { return }
        withAnimation(.easeOut(duration: 0.2)) { set(0) }
    }

    private func set(_ value: CGFloat) {
        if hidden != value { hidden = value }
    }
}

/// 帯を、隠れた分だけ上へずらして上端で切る（ホームの見出しに重ならない）
private struct RevealingBar<Content: View>: View {
    @ObservedObject var reveal: SwitcherReveal
    @ViewBuilder let content: Content

    var body: some View {
        content
            .offset(y: -reveal.hidden)
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
            .allowsHitTesting(reveal.hidden < reveal.height)
    }
}

/// 縦の一覧のスクロール量（先頭で0、下へ進むほど大きく、先頭で引っ張ると負）を、変わったときだけ知らせる。
/// スクロールの画面自身の位置を使う。内容の位置から計算すると、上の余白の扱いで先頭が0にならなかった
private struct ScrollOffsetReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, value in onChange(value) }
        } else {
            content
        }
    }
}

/// 縦の一覧を指で動かしている・惰性で動いている間か（moving）と、指が触れている間か（touching）を、
/// スクロールの段階が変わったときだけ知らせる。iOS 17では知らせない
private struct ScrollPhaseObserver: ViewModifier {
    let onChange: (_ moving: Bool, _ touching: Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                let touching = phase == .tracking || phase == .interacting
                onChange(touching || phase == .decelerating, touching)
            }
        } else {
            content
        }
    }
}
