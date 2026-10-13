import SwiftUI
import UIKit
import ImageIO

/// インデックスの操作設定（アプリ設定・ビュアー設定で共用する）
enum ReaderMode {
    /// インデックスのスワイプ：true で作品は1つずつ・ページは画面ごとに止まる（標準）、false で自由にスクロール
    static let indexSnapsKey = "reader.indexSnaps"
}

enum NativeReadingLayout: String, CaseIterable {
    case horizontal, verticalPages, verticalScroll
    static let key = "reader.native.readingLayout"
    static let verticalSwipeKey = "reader.native.verticalSwipe"
    var next: Self {
        self == .verticalScroll ? .horizontal : .verticalScroll
    }
    var title: String {
        self == .verticalScroll ? "縦スクロール" : "スワイプ表示"
    }
    var icon: String {
        switch self { case .horizontal: "arrow.left.and.right"; case .verticalPages: "rectangle.split.1x2"; case .verticalScroll: "arrow.up.and.down" }
    }
}


/// インデックスだけピンクの丸。隠すときは画面の下へ滑って消える
struct NativeReaderBars: View {
    let visible: Bool
    let isBookmarked: Bool
    let isLiked: Bool
    let isAutoplaying: Bool
    /// インデックスを開いているか（公式と同じく、真ん中のボタンが「閉じる」になる）
    var isIndexOpen = false
    var usesGlass = false
    var adaptiveGlassControls = false
    @ObservedObject var headerAppearance = ReaderHeaderAppearance()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var topInset: CGFloat = 0
    var transparentHeader = false
    var readingLayout = NativeReadingLayout.horizontal
    var onToggleReadingMode: (() -> Void)? = nil
    /// パネルの退出中も操作は止めるが、矢印は閉じ始めに戻す。
    var indexIconIsOpen: Bool? = nil
    /// 閉じるパネルの上端が到達したら、下ナビも一緒に押し出す。
    var indexExitOffset: CGFloat? = nil
    var indexExitBoundary: CGFloat = 0
    var shareURL: URL?
    let onBack: () -> Void
    let onSettings: () -> Void
    let onInfo: () -> Void
    let onBookmark: () -> Void
    let onIndex: () -> Void
    let onLike: () -> Void
    let onAutoplay: () -> Void

    private static let pink = Theme.accent

    private var glassHeaderTint: Color? {
        guard adaptiveGlassControls else { return nil }
        return headerAppearance.isOverComic ? nil : Self.pink
    }

    var body: some View {
        VStack(spacing: 0) {
            // インデックスを開いている間は、公式と同じく上のバーは出さない
            topBar
                .opacity(visible && !isIndexOpen ? 1 : 0)
                .offset(y: visible && !isIndexOpen ? 0 : -14)
                .allowsHitTesting(!isIndexOpen)
                .animation(.linear(duration: 0.15), value: visible && !isIndexOpen)
            Spacer()
            // 公式と同じく、画面の下の端から 32 の位置
            bottomBar
                .padding(.horizontal, usesGlass ? 16 : 0)
                .padding(.bottom, usesGlass ? 16 : 32)
                .modifier(ReaderBottomBarMotion(offset: indexExitOffset ?? (visible ? 0 : 140),
                                               indexBoundary: indexExitOffset == nil ? nil : indexExitBoundary))
                .animation(.easeOut(duration: 0.3), value: visible)
        }
        .ignoresSafeArea(.container, edges: usesGlass ? [] : .bottom)
        .allowsHitTesting(visible)
    }

    private var topBar: some View {
        ZStack {
            topControls
            // 真ん中のKのロゴ（公式サイトのアイコン画像）
            CachedImage(url: URL(string: "https://komiflo.com/assets/img/favicon/favicon_64.png")) {
                Color.clear
            }
            .frame(width: 26, height: 26)
            .accessibilityLabel("Komiflo")
        }
        .foregroundStyle(adaptiveGlassControls && readingLayout == .verticalScroll ? Color.white : Self.pink)
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, usesGlass ? 16 : 0)
        .padding(.top, usesGlass ? 8 : 0)
        .padding(.top, topInset)
        .padding(.bottom, 48)
        .background(alignment: .top) {
            if !transparentHeader {
                LinearGradient(colors: [.black.opacity(0.9), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            }
        }
    }

    @ViewBuilder
    private var topControls: some View {
        if #available(iOS 26.0, *), usesGlass, adaptiveGlassControls {
            // 個別の枠は維持し、描画だけを同じコンテナで扱う。
            GlassEffectContainer(spacing: 0) { topButtons }
        } else {
            topButtons
        }
    }

    private var topButtons: some View {
        HStack(spacing: adaptiveGlassControls ? 8 : 0) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .regular))
                        Text("戻る")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .padding(.leading, 11)
                    .padding(.trailing, 8)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .modifier(ReaderGlassStyle(enabled: usesGlass, adaptiveControl: adaptiveGlassControls, adaptiveTint: glassHeaderTint))
                }
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 22, weight: .regular))
                            .frame(width: 52, height: 48)
                            .contentShape(Rectangle())
                            .modifier(ReaderGlassStyle(enabled: usesGlass, adaptiveControl: adaptiveGlassControls, adaptiveTint: glassHeaderTint))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("作品を共有")
                }
                Spacer()
                if let onToggleReadingMode {
                    Button(action: onToggleReadingMode) {
                        HStack(spacing: 5) {
                            Image(systemName: readingLayout.next == .verticalScroll ? "arrow.down" : "arrow.left")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.2))
                            Text(readingLayout.next == .verticalScroll ? "縦読み" : "横読み")
                                .font(.system(size: 13, weight: .medium))
                        }
                            .frame(width: 78, height: 48)
                            .contentShape(Rectangle())
                            .modifier(ReaderGlassStyle(enabled: usesGlass, adaptiveControl: adaptiveGlassControls, adaptiveTint: glassHeaderTint))
                    }
                    .accessibilityLabel("\(readingLayout.next.title)に切り替え")
                    .accessibilityValue(readingLayout.title)
                    .accessibilityIdentifier("reader-reading-mode")
                }
                Button(action: onSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 52, height: 48)
                        .contentShape(Rectangle())
                        .modifier(ReaderGlassStyle(enabled: usesGlass, adaptiveControl: adaptiveGlassControls, adaptiveTint: glassHeaderTint))
                }
                .accessibilityLabel("コミックビューア設定")
            }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: headerAppearance.isOverComic)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            barButton("info.bubble", label: "コメント・作品情報", action: onInfo)
            barButton(isBookmarked ? "star.fill" : "star", label: "リーディングリスト", action: onBookmark)
            Button(action: onIndex) {
                Image(systemName: "eject")
                    .rotation3DEffect(.degrees((indexIconIsOpen ?? isIndexOpen) ? 180 : 0), axis: (x: 1, y: 0, z: 0))
                    .animation(nil, value: indexIconIsOpen ?? isIndexOpen)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 37)
                    .background(Capsule().fill(Self.pink))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
            }
            .padding(.horizontal, 8)
            .accessibilityLabel("インデックス")
            barButton(isLiked ? "heart.fill" : "heart", label: "いいね", action: onLike)
            barButton(isAutoplaying ? "pause" : "play", label: "自動再生", action: onAutoplay)
        }
        .padding(.horizontal, usesGlass ? 12 : 18)
        .frame(height: 48)
        .modifier(ReaderGlassStyle(enabled: usesGlass, originalFill: .black))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
    }

    private func barButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 41, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// パネルと同じ補間位置を使い、上端が下ナビへ届くまでナビを保つ。
private struct ReaderBottomBarMotion: AnimatableModifier {
    var offset: CGFloat
    let indexBoundary: CGFloat?
    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }
    func body(content: Content) -> some View {
        content.offset(y: indexBoundary.map { max(0, offset - $0) } ?? offset)
    }
}

/// インデックス（公式の「インデックス」をネイティブで描いたもの）。公式と同じ並び・配色：
/// 濃い灰色（#222）の全画面に、上から「閉じる」、同じ号の作品の表紙（今の作品はピンク）、
/// この作品のページの縮小画像（番号付き・今のページはピンク）。どちらも右から左へ並ぶ。
/// 作品の表紙は真ん中に1つ出し、スワイプで1作品ずつ移る。ページは画面にぴったり収まる数（スマホなら2ページほど）を並べ、
/// スワイプで画面ごとに送る（設定で、どちらも自由なスクロールにできる）。大きさは画面に合わせて自動で決める。
/// ページの縮小画像は公式が配っているものを、開いている間だけメモリに読み込んで出す（端末には保存しない）
struct NativeIndexView: View {
    let issueTitle: String?
    let chapters: [ComicSummary]
    let currentComic: Int
    let comicTitle: String?
    let pageThumbs: [URL]
    let pageCount: Int
    let currentPage: Int
    let onSelectPage: (Int) -> Void
    let onSelectChapter: (Int) -> Void
    let onClose: () -> Void
    var loadedImages: [Int: UIImage] = [:]
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat, CGFloat) -> Void)?
    var onDragCancelled: (() -> Void)?

    /// スワイプで1つずつ・画面ごとに止まるか（設定）
    @AppStorage(ReaderMode.indexSnapsKey) private var snaps = true

    private static let background = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    private static let text = Color(red: 221 / 255, green: 221 / 255, blue: 221 / 255)
    private static let subText = Color(red: 170 / 255, green: 170 / 255, blue: 170 / 255)
    private static let pink = Theme.accent

    /// 下スワイプで閉じるときに、指に合わせて下げる量
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        NativeIndexGestureHost(onChanged: { distance in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let onDragChanged { onDragChanged(distance) }
                else { dragOffset = distance }
            }
        }, onEnded: { distance, predicted in
            if let onDragEnded { onDragEnded(distance, predicted) }
            else if distance > 100 || predicted > 250 { onClose() }
            else { withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 } }
        }, onCancelled: {
            if let onDragCancelled { onDragCancelled() }
            else { withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 } }
        }) {
            GeometryReader { proxy in
                content(layout: IndexLayout(size: proxy.size))
                    .background(Self.background)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        // 安全領域を含むパネルの枠内で、背景と部品をまとめて退出させる。
        .clipped()
        .offset(y: onDragChanged == nil ? dragOffset : 0)
    }

    private func content(layout: IndexLayout) -> some View {
        VStack(spacing: 0) {
            closeButton
            chaptersSection(layout: layout)
                .padding(.bottom, 16)
            pagesSection(layout: layout)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.down")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Self.text)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("閉じる")
    }

    /// 同じ号の作品（表紙を真ん中に1つ。スワイプで1作品ずつ）
    private func chaptersSection(layout: IndexLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(issueTitle ?? "")
                .font(.system(size: 16))
                .foregroundStyle(Self.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 56)
            ChapterRow(
                chapters: chapters,
                currentComic: currentComic,
                itemSize: layout.chapterSize,
                containerWidth: layout.width,
                snaps: snaps
            ) { comic in
                chapterCell(comic, size: layout.chapterSize)
            }
        }
    }

    /// この作品のページ（画面にぴったり収まる数ずつ。スワイプで画面ごとに）
    private func pagesSection(layout: IndexLayout) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(comicTitle ?? "")
                    .font(.system(size: 16))
                    .foregroundStyle(Self.text)
                    .lineLimit(1)
                Text("\(pageCount)ページ")
                    .font(.system(size: 10))
                    .foregroundStyle(Self.subText)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            PageRow(
                count: pageThumbs.count,
                currentPage: currentPage,
                perScreen: layout.pagesPerScreen,
                itemSize: layout.pageSize,
                containerWidth: layout.width,
                snaps: snaps
            ) { index in
                pageCell(index + 1, url: pageThumbs[index], size: layout.pageSize)
            }
        }
    }

    private func chapterCell(_ comic: ComicSummary, size: CGSize) -> some View {
        Button { onSelectChapter(comic.id) } label: {
            CachedImage(url: comic.coverURL) { Color.white.opacity(0.027) }
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay {
                    if comic.id == currentComic {
                        Rectangle().strokeBorder(Self.pink, lineWidth: 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(comic.title)
    }

    private func pageCell(_ page: Int, url: URL, size: CGSize) -> some View {
        let active = page == currentPage
        return Button { onSelectPage(page) } label: {
            MemoryThumbnail(url: url, loadedImage: loadedImages[page])
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay {
                    if active { Rectangle().strokeBorder(Self.pink, lineWidth: 4) }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(page)")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 31, minHeight: 24)
                        .background(active ? Self.pink.opacity(0.85) : Self.background)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(page)ページ")
    }
}

/// インデックスの大きさ（画面の大きさから自動で決める）。
/// 公式の並び：閉じる 32・見出し 56・作品の表紙・すき間 16・見出し 56・ページ・下のバー 48・下の端まで 32。
/// 縮小画像は 203:286（公式の大きさ。これより大きくはしない）
private struct IndexLayout {
    let width: CGFloat
    let chapterSize: CGSize
    let pageSize: CGSize
    let pagesPerScreen: Int

    static let ratio: CGFloat = 203 / 286
    static let gap: CGFloat = 16
    static let edge: CGFloat = 8

    init(size: CGSize) {
        width = size.width
        let available = max(size.height - (32 + 56 + 16 + 56 + 48 + 32), 200)
        // 作品の表紙：残りの半分まで（公式の 286 が上限）
        let chapterHeight = min(286, available / 2)
        chapterSize = CGSize(width: (chapterHeight * Self.ratio).rounded(), height: chapterHeight.rounded())
        // ページ：残りの高さに収まる大きさで、横幅にぴったり収まる数を並べる
        let pageMaxHeight = min(286, available - chapterHeight)
        let pageMaxWidth = pageMaxHeight * Self.ratio
        let usable = size.width - Self.edge * 2
        let count = max(1, Int(((usable + Self.gap) / (pageMaxWidth + Self.gap)).rounded(.up)))
        let pageWidth = ((usable - Self.gap * CGFloat(count - 1)) / CGFloat(count)).rounded(.down)
        pagesPerScreen = count
        pageSize = CGSize(width: pageWidth, height: (pageWidth / Self.ratio).rounded(.down))
    }
}

/// 作品の表紙の段：今の作品を真ん中に出し、スワイプで1作品ずつ移る（右から左へ並ぶ）
private struct ChapterRow<Cell: View>: View {
    let chapters: [ComicSummary]
    let currentComic: Int
    let itemSize: CGSize
    let containerWidth: CGFloat
    let snaps: Bool
    @ViewBuilder let cell: (ComicSummary) -> Cell

    @State private var position: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: IndexLayout.gap) {
                ForEach(chapters, id: \.id) { comic in
                    cell(comic)
                        .environment(\.layoutDirection, .leftToRight)
                        .id(comic.id)
                }
            }
            .scrollTargetLayout()
        }
        // 表紙が真ん中に来るよう、左右に余白を取る
        .contentMargins(.horizontal, max((containerWidth - itemSize.width) / 2, 0), for: .scrollContent)
        .modifier(SnapBehavior(snaps: snaps, paging: false))
        .scrollPosition(id: $position, anchor: .center)
        .environment(\.layoutDirection, .rightToLeft)
        .frame(height: itemSize.height)
        // 作品の一覧が届いたら、今の作品を真ん中に
        .task(id: chapters.count) {
            guard !chapters.isEmpty else { return }
            position = currentComic
        }
    }
}

/// ページの段：画面にぴったり収まる数ずつ並べ、スワイプで画面ごとに送る（右から左へ並ぶ）
private struct PageRow<Cell: View>: View {
    let count: Int
    let currentPage: Int
    let perScreen: Int
    let itemSize: CGSize
    let containerWidth: CGFloat
    let snaps: Bool
    @ViewBuilder let cell: (Int) -> Cell

    @State private var position: Int?

    var body: some View {
        let screens = count == 0 ? 0 : (count + perScreen - 1) / perScreen
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(0..<screens, id: \.self) { screen in
                    HStack(spacing: IndexLayout.gap) {
                        ForEach(screen * perScreen ..< min((screen + 1) * perScreen, count), id: \.self) { index in
                            cell(index)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, IndexLayout.edge)
                    .frame(width: containerWidth)
                    .id(screen)
                }
            }
            .scrollTargetLayout()
        }
        .modifier(SnapBehavior(snaps: snaps, paging: true))
        .scrollPosition(id: $position)
        .environment(\.layoutDirection, .rightToLeft)
        .frame(height: itemSize.height)
        // ページの一覧が届いたら、今のページがある画面を出す
        .task(id: count) {
            guard count > 0 else { return }
            position = max(currentPage - 1, 0) / max(perScreen, 1)
        }
    }
}

/// スワイプで止まる位置（設定で切り替え）。ページの段は画面ごと、作品の段は1つずつ
private struct SnapBehavior: ViewModifier {
    let snaps: Bool
    let paging: Bool

    func body(content: Content) -> some View {
        if !snaps {
            content
        } else if paging {
            content.scrollTargetBehavior(.paging)
        } else {
            content.scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        }
    }
}

/// ページの縮小画像：メモリにだけ読み込んで出す（端末に保存しない・表紙のキャッシュにも入れない）。
/// 画面から消えたら画像も捨てる
private struct MemoryThumbnail: View {
    let url: URL
    var loadedImage: UIImage? = nil
    @State private var image: UIImage?

    /// 端末に何も残さない通信（キャッシュを使わない）
    private static let transport = NativeReaderTransport()

    var body: some View {
        Group {
            if let image = loadedImage ?? image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.027)
            }
        }
        .task(id: url) {
            image = nil
            guard loadedImage == nil else { return }
            guard NativeReaderDocument.allowedImageURL(url),
                  let (data, _) = try? await Self.transport.data(for: URLRequest(url: url), maximumBytes: 8 * 1024 * 1024,
                                                                successfulStatuses: [200]),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 572
                  ] as CFDictionary) else { return }
            guard !Task.isCancelled else { return }
            image = UIImage(cgImage: thumbnail)
        }
        .onDisappear { image = nil }
    }
}
