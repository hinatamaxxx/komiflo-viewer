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

    var body: some View {
        ImageHeaderPage { width, layout, scroll in
            ImagePageHeader(artist: nil, title: heading?.title ?? "", total: feed.total,
                            width: width, layout: layout, scroll: scroll, isFollowing: false,
                            followAnimated: false, onFollow: nil, onBack: { dismiss() },
                            bannerURL: headerImageURL,
                            sourceTrailingInset: 15 * OfficialMetrics.scale)
        } content: { _, width, minimumHeight in
            VStack(alignment: .leading, spacing: 16) {
                if let subtitle = heading?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.sectionTitle)
                        .padding(.horizontal, 15 * OfficialMetrics.scale)
                }

                ChronologicalComicList(feed: feed, library: library, isActive: true,
                                       emptyMessage: "このコレクションには作品がありません。") {
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

    private func load(continuing: Bool = false) async {
        guard let requestedPage = feed.beginLoad(continuing: continuing) else { return }
        do {
            let response = try await library.api.readingList(id: collectionID, page: requestedPage)
            try Task.checkCancellation()
            // バナーの管理名を仮表示せず、この応答の正式名称を最初から使う。
            heading = CollectionHeading(name: response.results?.name, fallback: title)
            feed.append((response.results?.contents ?? []).map(\.summary), requestedPage: requestedPage,
                        returnedPage: nil, pages: response.totalPages, count: response.total)
        } catch {
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
