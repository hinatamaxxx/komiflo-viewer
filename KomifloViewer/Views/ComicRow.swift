import SwiftUI

/// 表紙の縦横比（Komifloの表紙サムネイルは 376×531）
let coverAspect: CGFloat = 376.0 / 531.0

/// 表紙画像（読み込み中・失敗時はタイトル入りの仮表紙）
struct CoverImage: View {
    let url: URL?
    var placeholderTitle: String = ""
    var cornerRadius: CGFloat = 4

    var body: some View {
        // 枠（表紙の縦横比）を先に決めてから、画像をその中に敷き詰める
        Color.clear
            .aspectRatio(coverAspect, contentMode: .fit)
            .overlay { image }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }

    private var image: some View {
        // 一度読み込んだ表紙は保存して使い回すので、2回目からは読み込み表示なしで出る
        CachedImage(url: url) {
            ZStack {
                LinearGradient(colors: [Theme.placeholder, Theme.bar], startPoint: .top, endPoint: .bottom)
                Text(placeholderTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(6)
            }
        }
    }
}

/// 表紙を大きく見せるカード（ホームの横スクロールやグリッド用）
/// 電子書籍アプリのような横スクロール：1回スワイプすると決まった幅（表紙2冊分など）だけ進んで、ぬるっと止まる。
/// 勢いよくはじいても1ページずつ。スクロールの向き（右→左・左→右）に関係なく、動いた方向に1ページ進める
struct ShelfPaging: ScrollTargetBehavior {
    let pageWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let original = context.originalTarget.rect.minX
        let proposed = target.rect.minX
        let maxX = max(0, context.contentSize.width - context.containerSize.width)
        var next = original
        // 少しでもスワイプしたら、その方向に1ページ
        if proposed - original > 8 {
            next = original + pageWidth
        } else if original - proposed > 8 {
            next = original - pageWidth
        }
        target.rect.origin.x = min(max(0, next), maxX)
    }
}

/// 公式のスマホ表示（幅375pt）での大きさ。画面幅に比例させる
enum OfficialMetrics {
    /// iPadで幅に比例させると表紙や帯が画面を占めるため、大きめのiPhone程度（1.2倍）で止める。
    /// 分割表示ではウインドウの幅を使う。iPhoneは従来どおり画面幅に比例させる。
    static var scale: CGFloat {
        guard isPad else { return UIScreen.main.bounds.width / 375 }
        return min(windowWidth / 375, 1.2)
    }
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private static var windowWidth: CGFloat {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.bounds.width ?? UIScreen.main.bounds.width
    }
    /// iPadの広いウインドウでは、iPhoneの列数の2倍に並べて表紙を引き伸ばさない。
    static func columnCount(_ phoneCount: Int) -> Int {
        isPad && windowWidth >= 600 ? phoneCount * 2 : phoneCount
    }
    /// 表紙カードの幅（公式は156pt）と間隔（13pt）
    static var cardWidth: CGFloat { 156 * scale }
    static var cardSpacing: CGFloat { 13 * scale }
    static var shelfInset: CGFloat { 7 * scale }
}

/// 公式と同じ表紙カード：表紙・作者名・コメントアイコン・右上の追加ボタン（タイトルは出さない）。
/// 表紙をタップすると読む画面、コメントアイコンでコメント欄、作者名で作者ページ
struct ComicCard: View {
    let comic: ComicSummary
    @ObservedObject var library: LibraryStore
    var caption: String?
    var captionOpensInfo = false
    /// ランキングの順位（1始まり）
    var rank: Int?
    var readerCollection: [ComicSummary] = []
    var showsMagazineLogo = false
    var magazine: MagazineIdentity?
    var magazineLogoAtBottom = false

    @Environment(\.openRoute) private var openRoute
    @Environment(\.openReader) private var openReader

    private var isBookmarked: Bool { library.bookmarkedIDs.contains(comic.id) }
    private var isLiked: Bool { library.likedIDs.contains(comic.id) }

    /// 表紙の右上の丸いボタン（☆・♡）
    private func markIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.55), in: Circle())
            .contentShape(Circle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                openReader(ReaderRequest(comicID: comic.id, title: comic.title, collection: readerCollection))
            } label: {
                CoverImage(url: comic.coverURL, placeholderTitle: comic.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(comic.title)を読む")
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    // 公式の「リストに追加」ボタン（アプリではブックマーク）。未追加は☆、追加すると★
                    Button {
                        Task { await library.toggleBookmark(comic.id) }
                    } label: {
                        markIcon(isBookmarked ? "star.fill" : "star", color: isBookmarked ? Theme.star : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isBookmarked ? "ブックマークを外す" : "ブックマークする")

                    // いいね。未登録は♡、いいねすると♥（ピンク）
                    Button {
                        Task { await library.toggleLike(comic.id) }
                    } label: {
                        markIcon(isLiked ? "heart.fill" : "heart", color: isLiked ? Theme.accent : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isLiked ? "いいねを取り消す" : "いいねする")
                }
                .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if let rank {
                    RankBadge(rank: rank)
                        .offset(x: -4, y: 6)
                }
            }
            .modifier(HomeMagazineArtwork(comic: comic, enabled: showsMagazineLogo, library: library,
                                          atBottom: magazineLogoAtBottom, magazine: magazine))

            HStack(spacing: 4) {
                if captionOpensInfo {
                    Button {
                        openRoute(.comic(id: comic.id))
                    } label: {
                        Text(caption ?? comic.title)
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(comic.title)の作品情報を表示")
                } else if let slug = comic.authorSlug, caption == nil {
                    Button {
                        openRoute(.artist(slug: slug, name: comic.author ?? ""))
                    } label: {
                        // 公式と同じく作者名はピンク
                        Text(comic.author ?? "")
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(caption ?? comic.author ?? "")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                // コメントを優先するパネル。公式と同じピンクの吹き出しを使う。
                CommentsButton(contentID: comic.id, title: comic.title, library: library) {
                    // 公式と同じ、枠だけの吹き出し（塗りつぶさない）
                    Image(systemName: "bubble.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("コメントを表示")
            }
        }
    }
}

/// ランキングの順位（1〜3位は金・銀・銅）
private struct RankBadge: View {
    let rank: Int

    private var color: Color {
        switch rank {
        case 1: return Color(red: 0.95, green: 0.76, blue: 0.25)
        case 2: return Color(red: 0.75, green: 0.78, blue: 0.82)
        case 3: return Color(red: 0.80, green: 0.52, blue: 0.30)
        default: return Color(white: 0.2)
        }
    }

    var body: some View {
        Text("\(rank)")
            .font(.system(size: rank <= 3 ? 20 : 16, weight: .black, design: .rounded))
            .foregroundStyle(rank <= 3 ? Color.black : Color.white)
            .frame(minWidth: 30, minHeight: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 7))
            .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 2)
            .accessibilityLabel("\(rank)位")
    }
}

/// 作品1件の行（表紙・作品名・作者・補足・★♥ボタン）
struct ComicRow: View {
    let comic: ComicSummary
    var detail: String?
    @ObservedObject var library: LibraryStore

    @Environment(\.openRoute) private var openRoute
    @Environment(\.openReader) private var openReader

    private var detailText: String {
        detail ?? [comic.magazine, comic.likesCount.map { "♥ \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            // 表紙をタップしたら、すぐ漫画を開く（公式の表紙リンクと同じ）
            Button {
                openReader(ReaderRequest(comicID: comic.id, title: comic.title))
            } label: {
                CoverImage(url: comic.coverURL)
                    .frame(width: 48)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(comic.title)を読む")

            VStack(alignment: .leading, spacing: 4) {
                Text(comic.title.isEmpty ? "無題" : comic.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let author = comic.author {
                    if let slug = comic.authorSlug {
                        // 行全体のタップ（作品を開く）とは別に、作者名だけで作者ページへ
                        Button {
                            openRoute(.artist(slug: slug, name: author))
                        } label: {
                            HStack(spacing: 3) {
                                Text(author).lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(author)の作者ページ")
                    } else {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                }

                if !detailText.isEmpty {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                MarkButton(
                    isOn: library.bookmarkedIDs.contains(comic.id),
                    onImage: "star.fill",
                    offImage: "star",
                    color: Theme.star,
                    label: library.bookmarkedIDs.contains(comic.id) ? "ブックマークを外す" : "ブックマークする"
                ) {
                    Task { await library.toggleBookmark(comic.id) }
                }
                MarkButton(
                    isOn: library.likedIDs.contains(comic.id),
                    onImage: "heart.fill",
                    offImage: "heart",
                    color: Theme.accent,
                    label: library.likedIDs.contains(comic.id) ? "いいねを外す" : "いいねする"
                ) {
                    Task { await library.toggleLike(comic.id) }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { openRoute(.comic(id: comic.id)) }
        .accessibilityAddTraits(.isButton)
    }
}

/// ★・♥の切り替えボタン（押しやすいよう大きめ）
struct MarkButton: View {
    let isOn: Bool
    let onImage: String
    let offImage: String
    let color: Color
    let label: String
    var size: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? onImage : offImage)
                .font(.system(size: size))
                .foregroundStyle(isOn ? color : Color.secondary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

/// 表紙の並ぶ向き。漫画と同じ右→左が既定（設定で左→右にもできる）
enum ShelfDirection {
    static let storageKey = "layout.rightToLeft"
    /// 表紙の棚の横スクロール：true = 1冊ずつきっちり止まる（既定）、false = フリー
    static let snapStorageKey = "layout.shelfSnapsOneByOne"
}

private struct ShelfDirectionModifier: ViewModifier {
    @AppStorage(ShelfDirection.storageKey) private var rightToLeft = true

    func body(content: Content) -> some View {
        content.environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
    }
}

extension View {
    /// 表紙の棚・グリッドを漫画と同じ右→左に並べる（横スクロールは右端から始まる）
    func mangaShelfDirection() -> some View {
        modifier(ShelfDirectionModifier())
    }

    /// 棚の中の1冊分。文字や表紙の中身は反転させない
    func shelfItemContent() -> some View {
        environment(\.layoutDirection, .leftToRight)
    }

    /// ★・♥の切り替えに失敗したときのアラート
    func markErrorAlert(_ library: LibraryStore) -> some View {
        modifier(MarkErrorAlert(library: library))
    }

    /// ダークなナビゲーションバー
    func darkNavigationBar() -> some View {
        self
            .toolbarBackground(Theme.bar, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct MarkErrorAlert: ViewModifier {
    @ObservedObject var library: LibraryStore

    func body(content: Content) -> some View {
        content.alert(
            "変更できませんでした",
            isPresented: Binding(
                get: { library.actionError != nil },
                set: { if !$0 { library.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.actionError ?? "")
        }
    }
}

/// 公式のタグ・コレクションページと同じ、表紙カードの2列グリッド（左右15pt・間隔13pt）
struct ComicGrid: View {
    let comics: [ComicSummary]
    let library: LibraryStore
    var columnWidth: CGFloat? = nil
    /// 作家ページでは、作家名の代わりに作品タイトルを表示する。
    var showsTitles = false
    var linksToArtist = true
    var onLastAppear: (() -> Void)? = nil
    var ranks: [Int: Int] = [:]
    var onLastDisappear: (() -> Void)? = nil
    var showsMagazineLogo = false
    var magazine: MagazineIdentity?
    var magazineLogoAtBottom = false

    private var columns: [GridItem] {
        let spacing = 13 * OfficialMetrics.scale
        let size = columnWidth.map { GridItem.Size.fixed($0) } ?? .flexible()
        return Array(repeating: GridItem(size, spacing: spacing, alignment: .top), count: OfficialMetrics.columnCount(2))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 22 * OfficialMetrics.scale) {
            ForEach(comics) { comic in
                ComicCard(comic: comic, library: library, caption: caption(for: comic),
                          captionOpensInfo: showsTitles, rank: ranks[comic.id], readerCollection: comics,
                          showsMagazineLogo: showsMagazineLogo, magazine: magazine,
                          magazineLogoAtBottom: magazineLogoAtBottom)
                    .onAppear { if comic.id == comics.last?.id { onLastAppear?() } }
                    .onDisappear { if comic.id == comics.last?.id { onLastDisappear?() } }
            }
        }
        .padding(.horizontal, 15 * OfficialMetrics.scale)
    }

    private func caption(for comic: ComicSummary) -> String? {
        if showsTitles { return comic.title }
        return linksToArtist ? nil : comic.author ?? ""
    }
}

/// 公式と同じ番号付きのページ送り（<< 1 2 3 >>）。page は0始まり
struct NumberedPager: View {
    let page: Int
    let totalPages: Int
    let onSelect: (Int) -> Void

    var body: some View {
        let window = max(0, page - 2)...max(0, min(totalPages - 1, page + 2))
        HStack(spacing: 4) {
            if page > 0 {
                pageButton("<<") { onSelect(0) }
            }
            ForEach(Array(window), id: \.self) { index in
                if index == page {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 36, minHeight: 40)
                        .background(Theme.bar, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    pageButton("\(index + 1)") { onSelect(index) }
                }
            }
            if page < totalPages - 1 {
                pageButton(">>") { onSelect(totalPages - 1) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func pageButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 36, minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// フォロー中の作家・タグを示す共通の丸い表示。
struct FollowAttributeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.accent, in: Capsule())
    }
}

/// 絞り込み用の丸いボタン
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Theme.accent : Theme.bar, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// iOS 16でも使える空表示
struct EmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 一覧の最後に出す読み込み中表示
struct LoadingFooter: View {
    var text: String?

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            ProgressView()
            if let text {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// 読み込み状態
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 16) {
                EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: message)
                    .frame(maxHeight: 260)
                Button("再読み込み") { Task { await retry() } }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        case .loaded(let value):
            content(value)
        }
    }
}

/// 表紙の横スクロール棚（ホーム・詳細のおすすめで使う）
struct CoverShelf: View {
    let title: String
    let comics: [ComicSummary]
    @ObservedObject var library: LibraryStore
    var captions: [Int: String] = [:]
    /// 順位を表紙に出す（ランキング用）
    var ranked = false
    /// 公式の「もっと見る」の行き先
    var moreRoute: Route?
    var showsMagazineLogo = false
    var magazine: MagazineIdentity?
    var magazineLogoAtBottom = false

    @Environment(\.openRoute) private var openRoute
    @AppStorage(ShelfDirection.snapStorageKey) private var shelfSnapsOneByOne = true
    /// 棚の実際の幅（画面の向きやiPadでも正しく数えるため、測った値を使う）
    @State private var shelfWidth: CGFloat = UIScreen.main.bounds.width

    /// 棚にまるごと見えている表紙の冊数（1回のスワイプでこの冊数だけ進む）
    private var cardsPerPage: Int {
        let available = shelfWidth - OfficialMetrics.shelfInset * 2
        let perCard = OfficialMetrics.cardWidth + OfficialMetrics.cardSpacing
        return max(1, Int((available + OfficialMetrics.cardSpacing) / perCard))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                // 公式の棚の見出し：16pt・太さ600・灰色
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.sectionTitle)
                Spacer()
                if let moreRoute {
                    Button {
                        openRoute(moreRoute)
                    } label: {
                        HStack(spacing: 2) {
                            Text("もっと見る")
                            Image(systemName: "chevron.right")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 15)
            // 公式のスマホ表示と同じ大きさ：表紙156pt・間隔13pt（375pt幅のとき。画面幅に比例）
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: OfficialMetrics.cardSpacing) {
                    // 画面に見えている冊数（ふつうは2冊）ずつを1つの組にして、組ごとにきっちり止める。
                    // こうすると1回のスワイプで、見えている分だけちょうど進む
                    ForEach(Array(stride(from: 0, to: comics.count, by: cardsPerPage)), id: \.self) { start in
                        HStack(alignment: .top, spacing: OfficialMetrics.cardSpacing) {
                            ForEach(start..<min(start + cardsPerPage, comics.count), id: \.self) { index in
                                ComicCard(
                                    comic: comics[index],
                                    library: library,
                                    caption: captions[comics[index].id],
                                    rank: ranked ? index + 1 : nil,
                                    readerCollection: comics,
                                    showsMagazineLogo: showsMagazineLogo, magazine: magazine,
                                    magazineLogoAtBottom: magazineLogoAtBottom
                                )
                                .frame(width: OfficialMetrics.cardWidth)
                                .shelfItemContent()
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, OfficialMetrics.shelfInset)
            }
            // 既定は「1回のスワイプで、見えている冊数（2冊）ずつきっちり止まる」。
            // 設定で「フリー」（指の勢いのまま流れ、止まるときは2冊の区切りにそろう）も選べる
            .scrollTargetBehavior(.viewAligned(limitBehavior: shelfSnapsOneByOne ? .always : .never))
            .mangaShelfDirection()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { shelfWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in shelfWidth = width }
                }
            }
        }
    }
}

/// 作家の帯（公式の作家ギャラリーと同じ：横長の作家画像の上に作家名）
struct ArtistBannerRow: View {
    let artist: KFAttribute
    var height: CGFloat = 74
    var width: CGFloat?
    /// 画像が入っていない作家データ（フォロー一覧など）のとき、画像を取りに行くのに使う
    var library: LibraryStore?
    /// 後から取った画像（フォロー一覧から渡す）
    var fallbackBannerURL: URL?

    /// 見えたときに取った画像（この行だけが受け取るので、他の行や画面は作り直さない）
    @State private var loadedBannerURL: URL?

    private var bannerURL: URL? {
        artist.bannerURL ?? fallbackBannerURL ?? loadedBannerURL
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CachedImage(url: bannerURL) {
                LinearGradient(colors: [Theme.placeholder, Theme.bar], startPoint: .leading, endPoint: .trailing)
            }
            .frame(maxWidth: .infinity)
            .frame(width: width, height: height)
            .clipped()
            // 名前が読めるように、左側を少し暗くする
            LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 8) {
                Text(artist.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 3)
                    .lineLimit(1)
                if artist.newContentCount > 0 {
                    Text("新着")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(width: width, height: height)
        .clipShape(Rectangle())
        .contentShape(Rectangle())
        .task {
            // 画像が無い作家は、見えたときに取りに行く
            if artist.bannerURL == nil, fallbackBannerURL == nil, loadedBannerURL == nil, let library {
                loadedBannerURL = await library.artistBanner(id: artist.id)
            }
        }
    }
}
