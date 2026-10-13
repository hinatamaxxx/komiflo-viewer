import SwiftUI
import UIKit

/// 公式と同じく、読み終わりでは次作品の案内だけを指の移動に追従させる。
@MainActor
final class ReaderEndSwipeMotion: ObservableObject {
    @Published private(set) var displacement: CGSize = .zero
    private(set) var isHorizontalPull = false
    var offset: CGFloat { displacement.height }
    var horizontalOffset: CGFloat { displacement.width }

    func pull(translation: CGFloat, threshold: CGFloat) {
        isHorizontalPull = false
        let next = min(1, max(-1, translation / max(1, threshold))) * 32
        setDisplacement(CGSize(width: 0, height: next), animated: false)
    }

    func pullHorizontal(translation: CGFloat, threshold: CGFloat) {
        // 引き戻して0になっても、消え際までは横操作の案内の高さを保つ。
        isHorizontalPull = true
        let next = min(1, max(-1, translation / max(1, threshold))) * 32
        // 公式の追従補間は、操作が変わったときだけ標準の描画アニメーションへ渡す。
        setDisplacement(CGSize(width: next, height: 0), animated: true)
    }

    private func setDisplacement(_ next: CGSize, animated: Bool) {
        guard displacement != next else { return }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            withAnimation(.easeOut(duration: 0.2)) { displacement = next }
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { displacement = next }
    }

    func reset(animated: Bool = false) {
        setDisplacement(.zero, animated: animated)
    }
}

/// 先頭の黒い余白で、次作品と同じ文字描画と指追従を使う。
struct NativePreviousWorkHint: View {
    let previous: ComicSummary?
    @ObservedObject var swipeMotion: ReaderEndSwipeMotion
    var extensionHeight: CGFloat = 0
    var positionOffset: CGFloat = 0
    var maximumTravel: CGFloat = 48

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.height > 0 {
                let available = max(0, geometry.size.height - extensionHeight)
                let reservedTravel = min(32, max(0, available - NativeReaderEndLayout.messageHeight))
                let top = max(0, (available - NativeReaderEndLayout.messageHeight - reservedTravel) / 2 + positionOffset)
                let lines = NativeReaderEndLayout.messageLines(width: geometry.size.width, top: top,
                    heading: previous.map { "前の作品：" + ($0.author ?? "") } ?? NativeReaderSettings.missingPreviousHeading,
                    title: previous?.title ?? NativeReaderSettings.missingPreviousTitle,
                    instruction: previous == nil ? NativeReaderSettings.missingPreviousInstruction : "スワイプで前の作品へ")
                ReaderEndMessage(lines: lines,
                    offset: swipeMotion.isHorizontalPull ? maximumTravel : max(0, swipeMotion.offset) / 32 * maximumTravel,
                    horizontalOffset: swipeMotion.isHorizontalPull ? (1 + swipeMotion.horizontalOffset / 32) * maximumTravel : 0)
                    // 向きを変えた瞬間は基準位置を先に合わせ、追従と外側のフェードだけを補間する。
                    .animation(nil, value: swipeMotion.isHorizontalPull)
                    // 横へ引くときは、移動に合わせて文字を浮かび上がらせる。縦の表示は従来どおり。
                    .opacity(swipeMotion.horizontalOffset != 0
                        ? Double(min(1, abs(swipeMotion.horizontalOffset) / 16)) : (swipeMotion.offset > 0 ? 1 : 0))
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// 従来のReaderEndSkinを使い、公式Webを開かずに読み終わりの見た目と操作を組み立てる。
struct NativeReaderEndView: View {
    let content: KFContent?
    let next: ComicSummary?
    let recommendations: [ComicSummary]
    @ObservedObject var library: LibraryStore
    let onRead: (ComicSummary) -> Void
    let onPreviousPage: () -> Void
    let onNavigate: (Route) -> Void
    @ObservedObject var swipeMotion = ReaderEndSwipeMotion()
    @State private var recommendationOffset = 0
    @State private var toggledAt: Double = 0
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geometry in
            let comics = orderedRecommendations
            let snapshot = NativeReaderEndLayout.snapshot(size: geometry.size, content: content, next: next,
                                                          recommendations: comics, followed: library.followedIDs,
                                                          liked: library.likedIDs, toggledAt: toggledAt)
            ZStack(alignment: .topLeading) {
                Color(white: 17 / 255)
                if let rect = snapshot.topButton {
                    hit(rect, label: snapshot.topButtonText ?? "前のページに戻る", action: onPreviousPage)
                        .offset(x: swipeMotion.horizontalOffset, y: swipeMotion.offset)
                }
                if let rect = snapshot.follow, let artist = content?.artists.first, let id = artist.id {
                    hit(rect, label: snapshot.followText ?? "フォロー") {
                        toggledAt = Date().timeIntervalSince1970 * 1000
                        Task { await library.toggleFollow(attributeID: id) }
                    }
                }
                if let rect = snapshot.like, let content {
                    hit(rect, label: snapshot.likeText ?? "いいね") {
                        toggledAt = Date().timeIntervalSince1970 * 1000
                        Task { await library.toggleLike(content.id) }
                    }
                }
                if let rect = snapshot.tweet, let content, let url = NativeReaderEndLayout.postURL(content: content) {
                    hit(rect, label: "ポスト") { openURL(url) }
                }
                if let rect = snapshot.shuffle {
                    hit(rect, label: "おすすめを入れ替える") {
                        guard !recommendations.isEmpty else { return }
                        recommendationOffset = (recommendationOffset + (snapshot.thumbs?.count ?? 6)) % recommendations.count
                    }
                }
                ForEach(snapshot.keyedThumbs, id: \.key) { item in
                    if let comic = comics.first(where: { $0.id == item.thumb.id }) {
                        hit(item.thumb.r, label: comic.title) { onRead(comic) }
                    }
                }
                ReaderEndSkin(snapshot: snapshot, library: library, messageOffset: swipeMotion.offset,
                              messageHorizontalOffset: swipeMotion.horizontalOffset, onArtist: {
                    if let artist = content?.artists.first, let slug = artist.slug {
                        onNavigate(.artist(slug: slug, name: artist.name))
                    }
                })
            }
        }
        .background(Color(white: 17 / 255).ignoresSafeArea())
        .onChange(of: content?.id) { _, _ in recommendationOffset = 0; toggledAt = 0 }
    }

    private var orderedRecommendations: [ComicSummary] {
        guard !recommendations.isEmpty else { return [] }
        let offset = recommendationOffset % recommendations.count
        return Array(recommendations.dropFirst(offset)) + Array(recommendations.prefix(offset))
    }

    private func hit(_ rect: ReaderEndSnapshot.Rect, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .frame(width: rect.w, height: rect.h)
            .position(x: rect.rect.midX, y: rect.rect.midY)
            .accessibilityLabel(label)
    }
}

enum NativeReaderEndLayout {
    static let messageHeight: CGFloat = 19.2 + 30.72 + 3.2 + 15.36

    static func messageLines(width: CGFloat, top: CGFloat, heading: String, title: String,
                             instruction: String) -> [ReaderEndSnapshot.Line] {
        typealias Rect = ReaderEndSnapshot.Rect
        let width = max(1, width - 8)
        return [
            .init(r: Rect(x: 4, y: top, w: width, h: 19.2), t: heading, fs: 16, fw: 600),
            .init(r: Rect(x: 4, y: top + 19.2, w: width, h: 30.72), t: title, fs: 25.6, fw: 600),
            .init(r: Rect(x: 4, y: top + 19.2 + 30.72 + 3.2, w: width, h: 15.36),
                  t: instruction, fs: 12.8, fw: 200)
        ]
    }

    static func postURL(content: KFContent) -> URL? {
        let artists = content.artists.map { $0.name + "先生" }.joined(separator: "・")
        var url = URLComponents(string: "https://twitter.com/intent/tweet")!
        url.queryItems = [
            .init(name: "text", value: "【Komifloおすすめ作品】" + (artists.isEmpty ? "" : artists + "の") + " 「\(content.title ?? "")」"),
            .init(name: "url", value: "https://komiflo.com/comics/\(content.id)?share")
        ]
        if let magazine = content.magazine {
            let tag = magazine.replacingOccurrences(of: "WANI ANTHOLOGY", with: "WANI_ANTHOLOGY")
                .replacingOccurrences(of: "BEAST 20", with: "快楽天BEAST 20")
                .replacingOccurrences(of: "-|コミック|comic", with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0].components(separatedBy: "Vol.")[0]
            if !tag.isEmpty { url.queryItems?.append(.init(name: "hashtags", value: tag)) }
        }
        return url.url
    }

    static func snapshot(size: CGSize, content: KFContent?, next: ComicSummary?, recommendations: [ComicSummary],
                         followed: Set<Int>, liked: Set<Int>, toggledAt: Double = 0) -> ReaderEndSnapshot {
        typealias Rect = ReaderEndSnapshot.Rect
        let width = max(1, size.width), height = max(1, size.height)
        // 公式のタッチ表示：上の余白3rem、次作品欄18%、下の欄は最大40rem、表紙は3列。
        let header: CGFloat = 48
        let topHeight = height < width && height < 400 ? 0 : height * 0.18
        let bottomY = topHeight == 0 ? header : header + topHeight
        let containerWidth = min(max(1, width - 32), 640)
        let left = (width - containerWidth) / 2
        let column = containerWidth / 3
        var result = ReaderEndSnapshot(on: true)
        result.toggledAt = toggledAt
        result.comic = content?.id
        result.topArea = Rect(x: 0, y: 0, w: width, h: bottomY)
        result.bg = next?.coverURL?.absoluteString
        if topHeight > 0 {
            if let next {
                let top = header + (topHeight - messageHeight) / 2
                result.lines = messageLines(width: width, top: top,
                    heading: "次の作品：" + (next.author.map { $0 + "の" } ?? ""), title: next.title,
                    instruction: "スワイプで次の作品へ")
            } else {
                result.topButton = Rect(x: (width - 236) / 2, y: header + (topHeight - 46) / 2, w: 236, h: 46)
                result.topButtonText = "前のページに戻る"
                result.topButtonOutlined = true
                result.topButtonSize = 17.6
            }
        }
        let buttonY = bottomY + 12
        let buttonWidth = column * 0.94
        result.follow = Rect(x: left + column * 0.03, y: buttonY, w: buttonWidth, h: 35)
        result.tweet = Rect(x: left + column * 1.03, y: buttonY, w: buttonWidth, h: 35)
        result.like = Rect(x: left + column * 2.03, y: buttonY, w: buttonWidth, h: 35)
        let artist = content?.artists.first
        result.followOn = artist?.id.map { followed.contains($0) } ?? false
        result.followText = result.followOn == true ? "フォロー中" : "フォロー"
        result.artist = Rect(x: left, y: buttonY + 40, w: column, h: 19)
        result.artistText = artist?.name
        result.likeOn = content.map { liked.contains($0.id) } ?? false
        result.likeText = result.likeOn == true ? "いいね済" : "いいね"
        result.count = Rect(x: left + 2 * column, y: buttonY + 40, w: column, h: 19)
        let likeDelta = (result.likeOn == true ? 1 : 0) - (content?.liked == true ? 1 : 0)
        let count = max(0, (content?.likesCount ?? 0) + likeDelta)
        result.countText = count > 0 ? String(count) : ""
        if !recommendations.isEmpty {
            let headingY = bottomY + 83
            result.header = Rect(x: left, y: headingY, w: containerWidth, h: 28)
            result.shuffle = Rect(x: left + containerWidth - 36, y: headingY, w: 36, h: 28)
            let thumbWidth = containerWidth * (1 / 3.0 - 0.02)
            let thumbHeight = thumbWidth * 1.4142
            let gap = containerWidth * 0.02
            let thumbsY = headingY + 32
            let rows = height - thumbsY - 96 >= thumbHeight * 2 + gap ? 2 : 1
            result.thumbs = recommendations.prefix(rows * 3).enumerated().map { index, comic in
                .init(r: Rect(x: left + containerWidth * 0.01 + CGFloat(index % 3) * (thumbWidth + gap),
                              y: thumbsY + CGFloat(index / 3) * (thumbHeight + gap), w: thumbWidth, h: thumbHeight),
                      img: comic.coverURL?.absoluteString ?? "", title: comic.title, id: comic.id)
            }
        }
        return result
    }
}
