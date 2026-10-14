import SwiftUI
import UIKit

/// 作家ページ（公式の /artists/<slug> と同じ作り）：
/// 作家の帯・フォロー、「作品 / 商品」の切り替え、表紙カードの2列グリッドと番号付きのページ送り
struct ArtistPageView: View {
    enum Section: String, CaseIterable, Identifiable {
        case works = "作品"
        case goods = "商品"
        var id: String { rawValue }
    }

    let slug: String
    let title: String
    @ObservedObject var library: LibraryStore

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var artist: KFAttribute?
    @State private var section: Section = .works
    @State private var comics: [ComicSummary] = []
    /// 表示中のページ（0始まり。Komifloのページと同じ）
    @State private var page = 0
    @State private var totalPages = 1
    @State private var total: Int?
    @State private var firstPageSize = 20
    @State private var isLoading = false
    @State private var error: String?
    @State private var tankoubons: [KFContent] = []
    @State private var selectedTankoubonID: Int?
    @State private var tabProgress = PagerProgress()
    @State private var followToggledAt: Date?
    private var isFollowing: Bool { artist.map { library.followedIDs.contains($0.id) } ?? false }
    private var followAnimated: Bool { followToggledAt.map { Date().timeIntervalSince($0) < 3 } ?? false }

    /// 一度開いた作家ページの中身（アプリを開いている間は、もう一度開いたときに読み直さずにすぐ出す）
    private struct Snapshot {
        var artist: KFAttribute
        var comics: [ComicSummary]
        var page: Int
        var totalPages: Int
        var total: Int?
        var firstPageSize: Int
        var tankoubons: [KFContent]
    }

    @MainActor private static var snapshots: [String: Snapshot] = [:]

    init(slug: String, title: String, library: LibraryStore) {
        self.slug = slug
        self.title = title
        self.library = library
        if let saved = Self.snapshots[slug], !saved.comics.contains(where: \.isCoverExpired) {
            _artist = State(initialValue: saved.artist)
            _comics = State(initialValue: saved.comics)
            _page = State(initialValue: saved.page)
            _totalPages = State(initialValue: saved.totalPages)
            _total = State(initialValue: saved.total)
            _firstPageSize = State(initialValue: saved.firstPageSize)
            _tankoubons = State(initialValue: saved.tankoubons)
        }
    }

    private func saveSnapshot() {
        guard let artist else { return }
        Self.snapshots[slug] = Snapshot(
            artist: artist, comics: comics, page: page, totalPages: totalPages,
            total: total, firstPageSize: firstPageSize, tankoubons: tankoubons
        )
    }

    var body: some View {
        navigationContent
        .task { if artist == nil { await loadArtist() } }
        .task { if !library.hasLoadedFollows { await library.loadFollows() } }
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
        .markErrorAlert(library)
    }

    private var navigationContent: some View {
        ImageHeaderPage(footerHeight: ArtistHeaderLayout.tabsHeight) { width, layout, scroll in
            ImagePageHeader(artist: artist, title: title, total: total, width: width, layout: layout,
                            scroll: scroll, isFollowing: isFollowing, followAnimated: followAnimated,
                            onFollow: artist == nil ? nil : toggleFollow, onBack: { dismiss() },
                            bannerURL: artist?.bannerURL,
                            sectionPicker: AnyView(PagerTabs(items: Section.allCases, selection: $section,
                                progress: tabProgress, title: { $0.rawValue })
                                .padding(.horizontal, 15 * OfficialMetrics.scale)
                                .frame(height: ArtistHeaderLayout.tabsHeight)
                                .background(Theme.background)),
                            topTrailing: { AnyView(shareButton(height: $0)) }, followCrossesBoundary: true)
        } content: { proxy, width, minimumHeight in
            // 一覧だけを切り替え、帯・タブ・縦の位置は共用する。
            PagedView(items: Section.allCases, selection: $section, sizesToContent: true, progress: tabProgress) { item in
                VStack(alignment: .leading, spacing: 14) {
                    switch item {
                    case .works: works(proxy: proxy, width: width)
                    case .goods: goods(width: width)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(width: width)
                .frame(minHeight: minimumHeight, alignment: .top)
            }
        }
    }

    private func toggleFollow() {
        guard let id = artist?.id else { return }
        followToggledAt = Date()
        Task { await library.toggleFollow(attributeID: id) }
    }

    private func shareButton(height: CGFloat) -> some View {
        ImageHeaderShareButton(url: URL(string: "https://komiflo.com")!
            .appendingPathComponent("artists").appendingPathComponent(artist?.slug ?? slug),
                               label: "作家ページを共有", height: height)
    }

    // MARK: - 作品

    @ViewBuilder
    private func works(proxy: ScrollViewProxy, width: CGFloat) -> some View {
        if let error, comics.isEmpty {
            EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
                .frame(height: 240)
        } else if comics.isEmpty, isLoading || artist == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else if comics.isEmpty {
            EmptyState(title: "作品がありません", systemImage: "tray", message: "この作家の作品は見つかりませんでした。")
                .frame(height: 240)
        } else {
            ComicGrid(comics: comics, library: library, columnWidth: columnWidth(in: width),
                      showsTitles: true, linksToArtist: false, showsMagazineLogo: true)
                .opacity(isLoading ? 0.4 : 1)
            if totalPages > 1 {
                NumberedPager(page: page, totalPages: totalPages) { newPage in
                    Task {
                        await loadWorks(page: newPage)
                        withAnimation { proxy.scrollTo("top", anchor: .top) }
                    }
                }
            }
        }
    }

    // MARK: - 商品（単行本）

    @ViewBuilder
    private func goods(width: CGFloat) -> some View {
        if tankoubons.isEmpty {
            EmptyState(title: "商品はありません", systemImage: "books.vertical", message: "この作家の単行本は見つかりませんでした。")
                .frame(height: 240)
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(columnWidth(in: width)), spacing: 13 * OfficialMetrics.scale, alignment: .top),
                               count: OfficialMetrics.columnCount(2)),
                spacing: 20
            ) {
                ForEach(tankoubons, id: \.id) { volume in
                    Button {
                        selectedTankoubonID = volume.id
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverImage(url: volume.coverURL, placeholderTitle: volume.title ?? "")
                            Text(volume.title ?? "")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if let releaseDate = volume.releaseDate {
                                Text(releaseDate.prefix(10).replacingOccurrences(of: "-", with: "/"))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.sectionTitle)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 15 * OfficialMetrics.scale)
        }
    }

    private var selectedTankoubon: KFContent? {
        tankoubons.first { $0.id == selectedTankoubonID }
    }

    private func columnWidth(in width: CGFloat) -> CGFloat {
        let count = CGFloat(OfficialMetrics.columnCount(2))
        return max(0, (width - (15 * 2 + 13 * (count - 1)) * OfficialMetrics.scale) / count)
    }

    // MARK: - 読み込み

    private func loadArtist() async {
        do {
            let loaded = try await library.api.attribute(slug: slug)
            artist = loaded
            // 作家のデータの作品数は 0 のことが多い（APIが数を入れていない）ので、0 のときは作品一覧から数える
            total = loaded.contentCount > 0 ? loaded.contentCount : nil
            await loadWorks(page: 0)
            await countWorksIfNeeded()
            tankoubons = (try? await library.api.artistTankoubons(slug: slug)) ?? []
            saveSnapshot()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadWorks(page newPage: Int) async {
        guard let id = artist?.id else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let response = try await library.api.attributeContents(attributeID: id, page: newPage)
            comics = (response.results ?? []).map(\.summary)
            page = newPage
            totalPages = max(1, response.totalPages ?? 1)
            if let responseTotal = response.total, responseTotal > 0 { total = responseTotal }
            if newPage == 0 {
                firstPageSize = response.pageSize ?? comics.count
                if totalPages == 1 { total = comics.count }
            }
            saveSnapshot()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 作品数が分からないときは「1ページの件数 × (ページ数 − 1) ＋ 最後のページの件数」で数える
    private func countWorksIfNeeded() async {
        guard total == nil, totalPages > 1, let id = artist?.id else { return }
        guard let last = try? await library.api.attributeContents(attributeID: id, page: totalPages - 1) else { return }
        total = (totalPages - 1) * max(firstPageSize, 1) + (last.results?.count ?? 0)
        saveSnapshot()
    }
}

/// 共有と戻るに、同じ寸法の透明寄りのガラスを使う。
struct ImageHeaderControlGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

struct ArtistHeaderHitRegion: ViewModifier {
    @ObservedObject var scroll: ArtistHeaderScroll
    let layout: ArtistHeaderLayout
    var footerHeight: CGFloat = ArtistHeaderLayout.tabsHeight

    func body(content: Content) -> some View {
        content.contentShape(ArtistHeaderHitShape(height: layout.expandedHeight - scroll.offset + footerHeight))
    }
}

private struct ArtistHeaderHitShape: Shape {
    let height: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, height)))
    }
}

struct ArtistHeaderLayout {
    static let controlsHeight: CGFloat = 64
    static let tabsHeight: CGFloat = 56
    static let textSpacing: CGFloat = 8
    static let magazineBottomInset: CGFloat = 10
    let expandedHeight: CGFloat
    let compactHeight: CGFloat
    let statusHeight: CGFloat
    var collapseDistance: CGFloat { max(0, expandedHeight - compactHeight) }
    var magazineSourceBottom: CGFloat { expandedHeight - statusHeight - Self.magazineBottomInset }

    func offset(_ value: CGFloat) -> CGFloat { min(collapseDistance, max(0, value)) }
    func progress(_ value: CGFloat) -> CGFloat { offset(value) / max(1, collapseDistance) }
    func indicatorTop(offset value: CGFloat, footerHeight: CGFloat) -> CGFloat {
        expandedHeight - offset(value) + footerHeight
    }
    func transferredOffset(_ value: CGFloat, from previous: CGFloat, to next: CGFloat) -> CGFloat {
        max(0, value - offset(previous)) + offset(next)
    }

    /// 表示サイズが違っても、元の部品が境界を通った割合で上側へ登らせる。
    func risingTop(sourceTop: CGFloat, sourceHeight: CGFloat, targetTop: CGFloat,
                   targetHeight: CGFloat, offset value: CGFloat) -> CGFloat {
        let crossed = offset(value) - (sourceTop - Self.controlsHeight)
        let revealed = min(sourceHeight, max(0, crossed)) * targetHeight / max(1, sourceHeight)
        let remaining = max(0, crossed - sourceHeight)
        return max(targetTop, Self.controlsHeight - revealed - remaining)
    }
}

/// タグのフォローを、文字と同じ境界で切り、隠れ切った時点で上の帯に現す。
struct TagHeaderFollowVisibility {
    let visibleHeight: CGFloat
    let isCompact: Bool

    init(layout: ArtistHeaderLayout, offset: CGFloat, followHeight: CGFloat) {
        let bannerHeight = layout.expandedHeight - layout.offset(offset)
        let bottom = bannerHeight - 10
        isCompact = bottom <= layout.compactHeight
        visibleHeight = min(followHeight, max(0, bottom - layout.compactHeight))
    }
}

/// iOS 17では、固定された表示枠に対する内容全体の移動量を直接受け取る。
struct ArtistLegacyScrollOffset: ViewModifier {
    let coordinateSpace: UUID
    let scroll: ArtistHeaderScroll
    let layout: ArtistHeaderLayout
    var onOffset: ((CGFloat) -> Void)? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content.onGeometryChange(for: CGFloat.self) { geometry in
                layout.offset(-geometry.frame(in: .named(coordinateSpace)).minY)
            } action: { offset in
                (onOffset ?? scroll.update)(offset)
            }
        }
    }
}

/// スクロールによる更新は帯だけで受け、作品一覧を毎回作り直さない。
final class ArtistHeaderScroll: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published var nameHeight: CGFloat = 26
    @Published var countTextHeight: CGFloat = 14
    @Published var magazineLogoHeight: CGFloat = 48

    func nameCut(in layout: ArtistHeaderLayout) -> CGFloat {
        min(nameHeight, max(0, layout.offset(offset) - 8))
    }

    var countCrossingStart: CGFloat { 8 + nameHeight + ArtistHeaderLayout.textSpacing }

    func countCut(in layout: ArtistHeaderLayout) -> CGFloat {
        min(countTextHeight, max(0, layout.offset(offset) - countCrossingStart))
    }

    func update(_ value: CGFloat) {
        guard offset != value else { return }
        offset = value
    }
}

struct ImagePageHeader: View {
    let artist: KFAttribute?
    let title: String
    let total: Int?
    let width: CGFloat
    let layout: ArtistHeaderLayout
    @ObservedObject var scroll: ArtistHeaderScroll
    let isFollowing: Bool
    let followAnimated: Bool
    let onFollow: (() -> Void)?
    let onBack: () -> Void
    var bannerURL: URL?
    var magazineBranding: MagazineHeaderBranding?
    var countUnit = "作品"
    /// 件数の代わりに名前の下へ出す文字（配信カレンダーの表示中の月など）
    var countText: String?
    /// 縮んだ帯で、件数を名前の下ではなく横に並べる
    var compactCountInline = false
    var sourceTrailingInset: CGFloat = 124
    var sectionPicker: AnyView?
    var topTrailing: ((CGFloat) -> AnyView)?
    var followCrossesBoundary = false
    /// フォローボタンの文字（特集のいいねでは「いいね済み」「いいね」）
    var followTitles: (on: String, off: String) = ("フォロー中", "フォロー")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followSize: CGSize = .zero

    private var offset: CGFloat { layout.offset(scroll.offset) }
    private var progress: CGFloat { layout.progress(scroll.offset) }
    private var bannerHeight: CGFloat { layout.expandedHeight - offset }
    private var countIsBelowBoundary: Bool {
        scroll.countCut(in: layout) < scroll.countTextHeight / 2
    }
    private var sourceBoundaryHeight: CGFloat {
        max(0, bannerHeight - layout.compactHeight)
    }
    private var socialWidth: CGFloat {
        let count = ArtistSocialLinks.count(for: artist)
        return CGFloat(count) * ArtistSocialLinks.tapSize + CGFloat(max(0, count - 1) * 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            bannerContent
            if let sectionPicker { sectionPicker }
        }
    }

    private var bannerContent: some View {
        ZStack(alignment: .topLeading) {
            sourceContent
            HStack(spacing: 8) {
                backButton.fixedSize()
                if let magazineBranding {
                    MagazineCompactHeading(branding: magazineBranding, total: total, countUnit: countUnit,
                                           width: width, scroll: scroll, layout: layout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ArtistCompactTitle(name: artist?.name ?? title, count: countLabel, scroll: scroll, layout: layout,
                                       inline: compactCountInline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if followCrossesBoundary {
                    Color.clear.frame(width: followSize.width, height: followControlHeight)
                        .overlay {
                            if followVisibility.isCompact {
                                followContent
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                        }
                        .animation(reduceMotion ? nil : .spring(duration: 0.22), value: followVisibility.isCompact)
                    if let topTrailing {
                        topTrailing(followControlHeight)
                    }
                } else {
                    if let topTrailing { topTrailing(followControlHeight) }
                    Color.clear.frame(width: followSize.width, height: 1).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 15 * OfficialMetrics.scale)
            .frame(height: ArtistHeaderLayout.controlsHeight)
            .padding(.top, layout.statusHeight)
        }
        .frame(width: width, height: bannerHeight, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if followCrossesBoundary {
                followContent
                    .mask(alignment: .bottom) { Rectangle().frame(height: followVisibility.visibleHeight) }
                    .allowsHitTesting(followVisibility.visibleHeight > 0)
                    .accessibilityHidden(followVisibility.visibleHeight == 0)
                    .padding(.trailing, 15 * OfficialMetrics.scale)
                    .padding(.bottom, 10)
            } else {
                followContent
                    .padding(.trailing, 15 * OfficialMetrics.scale)
                    .padding(.bottom, 10)
            }
        }
        .background { bannerBackground }
    }

    private var followControlHeight: CGFloat {
        followSize.height > 0 ? followSize.height : UIFont.preferredFont(forTextStyle: .subheadline).lineHeight + 14
    }

    private var followVisibility: TagHeaderFollowVisibility {
        TagHeaderFollowVisibility(layout: layout, offset: offset, followHeight: followSize.height)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .foregroundStyle(Theme.accent)
                .frame(width: followControlHeight, height: followControlHeight)
                .modifier(ImageHeaderControlGlass())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("戻る")
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: ArtistHeaderLayout.textSpacing) {
            if let magazineBranding {
                MagazineHeading(branding: magazineBranding, total: total, countUnit: countUnit, width: width, scroll: scroll)
            } else {
                nameContent
                countContent
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 15 * OfficialMetrics.scale)
        .padding(.trailing, sourceTrailingInset)
        .padding(.top, magazineBranding == nil ? layout.compactHeight + 8 : layout.statusHeight + layout.magazineSourceBottom - 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: -offset)
        .frame(height: bannerHeight, alignment: .topLeading)
        .mask(alignment: .bottom) { Rectangle().frame(height: sourceBoundaryHeight) }
    }

    private var nameContent: some View {
        HStack(spacing: 8) {
            Text(artist?.name ?? title)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let artist, artist.newContentCount > 0 {
                Text("新着")
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 3)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll.nameHeight = $0 }
        .accessibilityHidden(scroll.nameCut(in: layout) >= scroll.nameHeight / 2)
    }

    private var countLabel: String? {
        countText ?? total.map { "\($0)\(countUnit)" }
    }

    @ViewBuilder
    private var countContent: some View {
        if let countLabel {
            countRow(countLabel)
                .allowsHitTesting(countIsBelowBoundary)
                .accessibilityHidden(!countIsBelowBoundary)
        }
    }

    private func countRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.7), radius: 3)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll.countTextHeight = $0 }
            if socialWidth > 0 {
                socialContent
            }
        }
    }

    private var socialContent: some View {
        // 大きいアイコンは文字の行に重ね、行の高さと縦の間隔を広げない。
        Color.clear.frame(width: socialWidth, height: 1)
            .overlay { ArtistSocialLinks(artist: artist) }
            .opacity(progress < 1 ? 1 : 0)
            .allowsHitTesting(progress < 1)
            .accessibilityHidden(progress >= 1)
    }

    @ViewBuilder
    private var followContent: some View {
        if let onFollow {
            FollowButton(isFollowing: isFollowing, animated: followAnimated,
                         onTitle: followTitles.on, offTitle: followTitles.off, action: onFollow)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { followSize = $0 }
        }
    }

    private var bannerBackground: some View {
        return CachedImage(url: bannerURL) {
            LinearGradient(colors: [Theme.placeholder, Theme.bar], startPoint: .leading, endPoint: .trailing)
        }
        .frame(width: width, height: layout.expandedHeight)
        .clipped()
        .blur(radius: 12 * progress, opaque: true)
        .background(Theme.bar)
        .overlay {
            LinearGradient(colors: [.black.opacity(0.2 + 0.2 * progress), .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: width, height: bannerHeight, alignment: .bottom)
        .clipped()
    }

}

/// 公式の作家情報にあるリンクだけを、作品数の隣へ表示する。
private struct ArtistSocialLinks: View {
    let artist: KFAttribute?
    static let circleSize: CGFloat = 36
    static let tapSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 4) {
            if let url = Self.profileURL(artist?.twitter) {
                Link(destination: url) {
                    Image("ArtistX")
                        .resizable().scaledToFit()
                        .frame(width: 21, height: 21)
                        .frame(width: Self.circleSize, height: Self.circleSize)
                        .background(Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255), in: Circle())
                        .frame(width: Self.tapSize, height: Self.tapSize)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Xで作家のプロフィールを開く")
            }
            if let url = Self.profileURL(artist?.pixiv) {
                Link(destination: url) {
                    Image("ArtistPixiv")
                        .resizable().scaledToFit()
                        .frame(width: 27, height: 27)
                        .frame(width: Self.circleSize, height: Self.circleSize)
                        .background(Color(red: 0, green: 151 / 255, blue: 220 / 255), in: Circle())
                        .frame(width: Self.tapSize, height: Self.tapSize)
                        .contentShape(Circle())
                }
                .accessibilityLabel("pixivで作家のプロフィールを開く")
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    static func count(for artist: KFAttribute?) -> Int {
        [profileURL(artist?.twitter), profileURL(artist?.pixiv)].compactMap { $0 }.count
    }

    private static func profileURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }
}

/// 帯の右上の共有ボタン（作家・特集で共用。戻るボタンと同じガラスの丸）
struct ImageHeaderShareButton: View {
    let url: URL
    let label: String
    let height: CGFloat

    var body: some View {
        ShareLink(item: url) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: height * 0.48, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: height, height: height)
                .modifier(ImageHeaderControlGlass())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tint(Theme.accent)
        .accessibilityLabel(label)
    }
}

/// 元の文字と同じバー下端で切り、上側も一つの境界から登らせる。
private struct ArtistCompactTitle: View {
    let name: String
    let count: String?
    @ObservedObject var scroll: ArtistHeaderScroll
    let layout: ArtistHeaderLayout
    /// 件数を名前の横に並べる（名前と一緒に登る）
    var inline = false
    @State private var nameHeight: CGFloat = 23
    @State private var countHeight: CGFloat = 16

    private var nameTop: CGFloat {
        max(0, (ArtistHeaderLayout.controlsHeight - nameHeight - (count == nil || inline ? 0 : countHeight + 1)) / 2)
    }
    private var crossingY: CGFloat {
        ArtistHeaderLayout.controlsHeight + 8 - layout.offset(scroll.offset)
    }
    private var nameY: CGFloat { max(nameTop, crossingY) }
    /// 縦に並べるときと同じく、帯の中の件数が境界を越えた分だけ下から登り、名前の横で止まる
    private var inlineCountY: CGFloat {
        max(nameTop, crossingY + scroll.nameHeight + ArtistHeaderLayout.textSpacing)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.system(size: 19, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nameHeight = $0 }
                if inline, let count {
                    // 横に並べても、登り始めは帯の中の件数が境界を越えたとき（名前より件数の行の分だけ遅い）
                    Text(count)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .layoutPriority(1)
                        .offset(y: inlineCountY - nameY)
                        .accessibilityHidden(scroll.countCut(in: layout) == 0)
                }
            }
            .offset(y: nameY)
            .accessibilityHidden(scroll.nameCut(in: layout) == 0)
            if !inline, let count {
                Text(count)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { countHeight = $0 }
                    .offset(y: max(nameTop + nameHeight + 1, crossingY + scroll.nameHeight + ArtistHeaderLayout.textSpacing))
                    .accessibilityHidden(scroll.countCut(in: layout) == 0)
            }
        }
        .frame(height: ArtistHeaderLayout.controlsHeight, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .foregroundStyle(.white)
    }
}

/// 画像付きの上部は独自にぼかすため、標準のスクロール端の覆いを重ねない。
struct ArtistTopScrollEdge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// 上端はヘッダー自身が時計領域を含む。移動する一覧の安全領域を再加算しない。
struct ArtistScrollInsets: UIViewRepresentable {
    @ObservedObject var scroll: ArtistHeaderScroll
    let layout: ArtistHeaderLayout
    let footerHeight: CGFloat
    var onResolve: ((UIScrollView) -> Void)? = nil

    func makeUIView(context: Context) -> InsetView {
        let view = InsetView()
        view.isUserInteractionEnabled = false
        view.indicatorTop = layout.indicatorTop(offset: scroll.offset, footerHeight: footerHeight)
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ view: InsetView, context: Context) {
        view.indicatorTop = layout.indicatorTop(offset: scroll.offset, footerHeight: footerHeight)
        view.onResolve = onResolve
        view.configureInsets()
    }

    final class InsetView: UIView {
        private weak var configuredScroll: UIScrollView?
        private var configuredInsets: UIEdgeInsets?
        var indicatorTop: CGFloat = 0
        private var configuredIndicatorTop: CGFloat?
        var onResolve: ((UIScrollView) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            configureInsets()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureInsets()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            configureInsets()
        }

        func configureInsets() {
            guard let window else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    // 下端とスクロール表示の余白だけ、固定された窓の値で管理する。
                    let safe = window.safeAreaInsets
                    let needsLayout = configuredScroll !== scroll || configuredInsets != safe
                    let needsIndicator = needsLayout || configuredIndicatorTop != indicatorTop
                    // バーの移動は内容の余白を再設定せず、慣性中の配置を変えない。
                    if needsLayout {
                        configuredScroll = scroll
                        configuredInsets = safe
                        let content = UIEdgeInsets(top: 0, left: 0, bottom: safe.bottom, right: 0)
                        if scroll.contentInsetAdjustmentBehavior != .never {
                            scroll.contentInsetAdjustmentBehavior = .never
                        }
                        if scroll.contentInset != content { scroll.contentInset = content }
                        if scroll.automaticallyAdjustsScrollIndicatorInsets {
                            scroll.automaticallyAdjustsScrollIndicatorInsets = false
                        }
                    }
                    let indicators = UIEdgeInsets(top: indicatorTop, left: 0, bottom: safe.bottom, right: 0)
                    if needsIndicator {
                        configuredIndicatorTop = indicatorTop
                        if scroll.verticalScrollIndicatorInsets != indicators {
                            scroll.verticalScrollIndicatorInsets = indicators
                        }
                    }
                    if scroll.bounds.height > 0, scroll.contentSize.height >= scroll.bounds.height {
                        onResolve?(scroll)
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

/// 移動する画面の余白ではなく、動かないウインドウの時計領域を使う。
struct ArtistWindowInsetReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> InsetView {
        let view = InsetView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: InsetView, context: Context) { view.onChange = onChange }

    final class InsetView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reportedInset: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportInset()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportInset()
        }

        private func reportInset() {
            guard let inset = window?.safeAreaInsets.top, reportedInset != inset else { return }
            reportedInset = inset
            let update = onChange
            DispatchQueue.main.async { update?(inset) }
        }
    }
}
