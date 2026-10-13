import SwiftUI

/// 並び順ごとの一覧を保持し、表示中の末尾だけで続きを取得する。
struct ChronologicalComicList: View {
    let feed: ChronologicalComicFeed
    let library: LibraryStore
    let isActive: Bool
    var loadsMoreAutomatically = true
    var emptyTitle = "作品がありません"
    var emptyMessage = "表示できる作品がありません。"
    let loadMore: () async -> Void
    @State private var isEndVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = feed.error, feed.comics.isEmpty {
                EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
                    .frame(height: 260)
            } else if !feed.hasLoaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 260)
            } else if feed.comics.isEmpty {
                EmptyState(title: emptyTitle, systemImage: "tray", message: emptyMessage).frame(height: 260)
            } else {
                ComicGrid(comics: feed.comics, library: library,
                          onLastAppear: { isEndVisible = true },
                          onLastDisappear: { isEndVisible = false }, showsMagazineLogo: true)
            }
            if feed.isLoading, !feed.comics.isEmpty {
                LoadingFooter()
            } else if let error = feed.error {
                if !feed.comics.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 15 * OfficialMetrics.scale)
                }
                Button("再読み込み") { Task { await loadMore() } }
                    .padding(.horizontal, 15 * OfficialMetrics.scale)
            }
        }
        .task(id: loadsMoreAutomatically && isActive && isEndVisible && feed.error == nil ? feed.comics.last?.id : nil) {
            guard loadsMoreAutomatically, isActive, isEndVisible, feed.error == nil else { return }
            await loadMore()
        }
    }
}
