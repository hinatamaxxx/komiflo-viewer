import SwiftUI

/// ランキングとロングヒットはホームの一覧を使い、話題の棚だけ続きを取得する。
struct HomeShelfPageView: View {
    let attributeID: Int
    let kind: HomeShelfKind
    let title: String
    let homeComics: [ComicSummary]
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var feed = ChronologicalComicFeed()
    @State private var order: HomeRankingOrder = .ranked
    @StateObject private var orderProgress = PagerProgress()
    @State private var referenceDate = Date()
    /// 先頭の作品の作家のプロフィール画像（無ければ画像なしの帯）
    @State private var authorImageURL: URL?

    var body: some View {
        ImageHeaderPage(footerHeight: kind == .recent ? RankingOrderPicker.height : 0) { width, layout, scroll in
            ImagePageHeader(artist: nil, title: title, total: kind == .topical ? feed.total : homeComics.count,
                            width: width, layout: layout, scroll: scroll,
                            isFollowing: false, followAnimated: false, onFollow: nil,
                            onBack: { dismiss() }, bannerURL: authorImageURL,
                            sourceTrailingInset: 15 * OfficialMetrics.scale,
                            sectionPicker: kind == .recent ? AnyView(
                                RankingOrderPicker(order: $order, progress: orderProgress)
                                    .background(Theme.background)) : nil)
        } content: { _, width, minimumHeight in
            Group {
                if kind == .recent {
                    PagedView(items: HomeRankingOrder.allCases, selection: $order,
                              sizesToContent: true, keepsPagesAlive: true, commitsSelectionOnIdle: true,
                              progress: orderProgress) { item in
                        fixedList(item.ordered(homeComics), ranks: HomeRankingOrder.ranks(for: homeComics))
                            .padding(.vertical, 12)
                            .frame(width: width)
                            .frame(minHeight: minimumHeight, alignment: .top)
                    }
                } else if kind == .longHits {
                    fixedList(homeComics)
                        .padding(.vertical, 12)
                        .frame(width: width)
                        .frame(minHeight: minimumHeight, alignment: .top)
                } else {
                    ChronologicalComicList(feed: feed.previewing(homeComics), library: library, isActive: true) {
                        await load(continuing: true)
                    }
                    .padding(.vertical, 12)
                    .frame(width: width)
                    .frame(minHeight: minimumHeight, alignment: .top)
                }
            }
        }
        .task { if kind == .topical { await load() } }
        .task(id: homeComics.first?.authorSlug) {
            await ArtistProfileImage.load(authorSlug: homeComics.first?.authorSlug, api: library.api) { authorImageURL = $0 }
        }
        .markErrorAlert(library)
    }

    @ViewBuilder
    private func fixedList(_ comics: [ComicSummary], ranks: [Int: Int] = [:]) -> some View {
        if comics.isEmpty {
            EmptyState(title: "作品がありません", systemImage: "tray", message: "表示できる作品がありません。")
                .frame(height: 260)
        } else {
            ComicGrid(comics: comics, library: library, ranks: ranks, showsMagazineLogo: true)
        }
    }

    private func load(continuing: Bool = false) async {
        guard kind == .topical, let requestedPage = feed.beginLoad(continuing: continuing) else { return }
        let token = feed.token
        let cacheGeneration = APICache.generation
        do {
            func publish(_ response: KFContentListResponse, updating: Bool) throws {
                try Task.checkCancellation()
                guard token == feed.token, cacheGeneration == APICache.generation else { throw CancellationError() }
                let contents = kind.ordered(response.results ?? [], attributeID: attributeID, date: referenceDate)
                let count = response.total ?? (requestedPage == 0 && response.totalPages == 1 ? contents.count : nil)
                if requestedPage == 0 {
                    guard feed.replacePage(contents.map(\.summary), requestedPage: 0, returnedPage: response.page,
                                           pages: response.totalPages, count: count) else {
                        throw KomifloAPIError.invalidResponse
                    }
                } else {
                    feed.append(contents.map(\.summary), requestedPage: requestedPage, returnedPage: response.page,
                                pages: response.totalPages, count: count)
                }
                // 保存済みの先頭を表示中も、取り直しが終わるまで追加取得を重ねない。
                feed.isLoading = updating
            }
            if requestedPage == 0, let cached = try? await APICache.fromCache({
                try await library.api.homeShelfContents(kind: kind, attributeID: attributeID,
                                                       page: 0, date: referenceDate)
            }), !(cached.results ?? []).contains(where: { $0.summary.isCoverExpired }) {
                try publish(cached, updating: true)
            }
            let response = try await library.api.homeShelfContents(kind: kind, attributeID: attributeID,
                                                                   page: requestedPage, date: referenceDate)
            try publish(response, updating: false)
        } catch {
            guard token == feed.token, cacheGeneration == APICache.generation else { return }
            feed.isLoading = false
            if !Task.isCancelled, !(error is CancellationError) { feed.error = error.localizedDescription }
        }
    }
}

/// 履歴と同じピンクの選択部品・横スワイプで、順位の方向だけを切り替える。
private struct RankingOrderPicker: View {
    static let height: CGFloat = 44
    @Binding var order: HomeRankingOrder
    let progress: PagerProgress

    var body: some View {
        PagerTabs(items: HomeRankingOrder.allCases, selection: $order,
                  progress: progress, scrolls: true, font: .footnote.weight(.semibold), title: { $0.label })
            .frame(height: 32)
            .padding(.vertical, 6)
    }
}
