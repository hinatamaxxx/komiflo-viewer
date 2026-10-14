import SwiftUI

/// 公式の特集コレクション（/collection/<ID>）。ホームの宣伝バナーから開く。
/// 表紙カードの2列グリッドで、タグと同じく末尾で続きを読み込む。
struct CollectionView: View {
    let collectionID: Int
    let title: String
    @ObservedObject var library: LibraryStore
    var headerImageURL: URL?
    @Environment(\.dismiss) private var dismiss

    @State private var heading: CollectionHeading?
    @State private var feed = ChronologicalComicFeed()
    /// 特集のいいね（公開の特集だけ。作家のフォローボタンと同じ部品）
    @State private var liked: Bool?
    @State private var likesCount: Int?
    @State private var likeToggledAt: Date?
    @State private var isLiking = false

    var body: some View {
        ImageHeaderPage { width, layout, scroll in
            ImagePageHeader(artist: nil, title: heading?.title ?? "", total: feed.total,
                            width: width, layout: layout, scroll: scroll, isFollowing: liked ?? false,
                            followAnimated: likeToggledAt.map { Date().timeIntervalSince($0) < 3 } ?? false,
                            onFollow: liked == nil ? nil : toggleLike, onBack: { dismiss() },
                            bannerURL: headerImageURL,
                            countText: countText,
                            // いいねボタンがある特集は、作家・タグと同じだけ右をあけ、名前と数がボタンの下に入らないようにする
                            sourceTrailingInset: liked == nil ? 15 * OfficialMetrics.scale : 124,
                            // 作家のページと同じく右上に共有。いいねは帯が縮むと共有の左へ移る
                            topTrailing: { height in
                                AnyView(ImageHeaderShareButton(
                                    url: URL(string: "https://komiflo.com/collection/\(collectionID)")!,
                                    label: "特集を共有", height: height))
                            },
                            followCrossesBoundary: true,
                            followTitles: ("いいね済み", "いいね"))
        } content: { _, width, minimumHeight in
            VStack(alignment: .leading, spacing: 16) {
                if let subtitle = heading?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.sectionTitle)
                        .padding(.horizontal, 15 * OfficialMetrics.scale)
                }

                ChronologicalComicList(feed: feed, library: library, isActive: true,
                                       emptyMessage: "このコレクションには作品がありません。", ranks: ranks) {
                    await load(continuing: true)
                }
            }
            .padding(.vertical, 12)
            .frame(width: width)
            .frame(minHeight: minimumHeight, alignment: .top)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await load() }
        .markErrorAlert(library)
    }

    /// 作品数といいねの数（公式の特集のいいねの数と同じ）
    private var countText: String? {
        let parts = [feed.total.map { "\($0)作品" }, likesCount.map { "いいね \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ・ ")
    }

    /// ランキングの特集は、新作ランキングと同じくサムネイルに順位を付ける（公式の並び順が順位）
    private var ranks: [Int: Int] {
        guard heading?.title.contains("ランキング") == true else { return [:] }
        // 先頭の扉絵（「TOP50」などの作家のいない画像）は順位に数えない
        return Dictionary(feed.comics.filter { $0.author != nil }.enumerated().map { ($0.element.id, $0.offset + 1) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// 作家のフォローと同じく、先に表示を変えてから公式へ送り、失敗したら元に戻す
    private func toggleLike() {
        guard !isLiking, let current = liked else { return }
        let newValue = !current
        liked = newValue
        likesCount = likesCount.map { max(0, $0 + (newValue ? 1 : -1)) }
        likeToggledAt = Date()
        isLiking = true
        Task {
            let succeeded = await library.setReadingListLiked(newValue, readingListID: collectionID)
            isLiking = false
            guard !succeeded else { return }
            liked = current
            likesCount = likesCount.map { max(0, $0 + (newValue ? -1 : 1)) }
        }
    }

    /// 先頭は、保存してある前回の応答があればすぐ出し（ホームの棚の一覧と同じ）、公式から取り直して差し替える
    private func load(continuing: Bool = false) async {
        guard let requestedPage = feed.beginLoad(continuing: continuing) else { return }
        let token = feed.token
        let cacheGeneration = APICache.generation
        do {
            func publish(_ response: KFReadingListResponse, updating: Bool) throws {
                try Task.checkCancellation()
                guard token == feed.token, cacheGeneration == APICache.generation else { throw CancellationError() }
                // バナーの管理名を仮表示せず、この応答の正式名称を最初から使う。
                heading = CollectionHeading(name: response.results?.name, fallback: title)
                // いいねを送っている間は、届いた応答で表示を戻さない
                if !isLiking {
                    liked = response.results?.listType == "public" ? response.results?.liked ?? false : nil
                    likesCount = response.results?.listType == "public" ? response.results?.likesCount : nil
                }
                let comics = (response.results?.contents ?? []).map(\.summary)
                if requestedPage == 0 {
                    _ = feed.replacePage(comics, requestedPage: 0, returnedPage: nil,
                                         pages: response.totalPages, count: response.total)
                } else {
                    feed.append(comics, requestedPage: requestedPage, returnedPage: nil,
                                pages: response.totalPages, count: response.total)
                }
                // 保存済みの先頭を表示中も、取り直しが終わるまで追加取得を重ねない。
                feed.isLoading = updating
            }
            if requestedPage == 0, let cached = try? await APICache.fromCache({
                try await library.api.readingList(id: collectionID, page: 0)
            }), !(cached.results?.contents ?? []).contains(where: { $0.summary.isCoverExpired }) {
                try publish(cached, updating: true)
            }
            try publish(try await library.api.readingList(id: collectionID, page: requestedPage), updating: false)
        } catch {
            guard token == feed.token, cacheGeneration == APICache.generation else { return }
            feed.isLoading = false
            if !Task.isCancelled, !(error is CancellationError) { feed.error = error.localizedDescription }
        }
    }
}

struct CollectionHeading {
    let title: String
    let subtitle: String

    init(name: String?, fallback: String) {
        // 公式と同じく "タイトル|サブタイトル|…" に分ける。
        let parts = (name ?? fallback).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        title = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        subtitle = parts.count > 1 ? parts[1] : ""
    }
}
