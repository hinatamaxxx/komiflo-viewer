import Foundation

/// 並び順ごとの一覧と続きを保持し、タブ移動で取得済みの作品を失わない。
struct ChronologicalComicFeed {
    var comics: [ComicSummary] = []
    var nextPage = 0
    var totalPages: Int?
    var total: Int?
    var isLoading = false
    var hasLoaded = false
    var error: String?
    let token = UUID()

    /// ホームの先頭作品は表示だけに使い、取得済みページや次ページの番号を進めない。
    func previewing(_ incoming: [ComicSummary]) -> Self {
        guard !hasLoaded, comics.isEmpty, !incoming.contains(where: \.isCoverExpired) else { return self }
        var preview = self
        preview.comics = incoming
        preview.hasLoaded = !incoming.isEmpty
        return preview
    }

    mutating func beginLoad(continuing: Bool) -> Int? {
        guard !isLoading, !hasLoaded || continuing,
              totalPages.map({ nextPage < $0 }) ?? true else { return nil }
        isLoading = true
        error = nil
        return nextPage
    }

    mutating func append(_ incoming: [ComicSummary], requestedPage: Int, returnedPage: Int?,
                         pages: Int?, count: Int?) {
        // 指定と違うページは混ぜない。同じIDも一度だけ追加する。
        if returnedPage == nil || returnedPage == requestedPage {
            var known = Set(comics.map(\.id))
            let unique = incoming.filter { known.insert($0.id).inserted }
            comics += unique
            nextPage = requestedPage + 1
            totalPages = unique.isEmpty ? nextPage : (pages ?? nextPage)
        } else {
            totalPages = nextPage
        }
        if let count { total = count }
        hasLoaded = true
        isLoading = false
    }

    /// 番号付きページのキャッシュを新しい応答へ置き換える。別ページや古い作品を混ぜない。
    @discardableResult
    mutating func replacePage(_ incoming: [ComicSummary], requestedPage: Int, returnedPage: Int?,
                             pages: Int?, count: Int?) -> Bool {
        guard returnedPage == nil || returnedPage == requestedPage else { return false }
        comics = []
        error = nil
        append(incoming, requestedPage: requestedPage, returnedPage: returnedPage, pages: pages, count: count)
        return true
    }
}
