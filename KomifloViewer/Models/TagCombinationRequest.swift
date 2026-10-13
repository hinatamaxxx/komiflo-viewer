import Foundation

/// 決定した組み合わせだけを取得し、シートを閉じる間にも読み込みを進める。
@MainActor
struct TagCombinationRequest {
    struct Result {
        let response: KFContentListResponse
        let fromCache: Bool
    }

    let id = UUID()
    let cacheGeneration = APICache.generation
    let task: Task<Result, Error>
    let thumbnails: Task<Void, Never>

    init(api: KomifloAPI, ids: [Int], options: TagListingOptions) {
        task = Task {
            if let cached = try? await APICache.fromCache({
                try await api.attributeContents(attributeIDs: ids, page: 0, options: options)
            }), (cached.page == nil || cached.page == 0),
               !(cached.results ?? []).contains(where: { $0.summary.isCoverExpired }) {
                try Task.checkCancellation()
                return Result(response: cached, fromCache: true)
            }
            let response = try await api.attributeContents(attributeIDs: ids, page: 0, options: options)
            try Task.checkCancellation()
            guard response.page == nil || response.page == 0 else { throw KomifloAPIError.invalidResponse }
            return Result(response: response, fromCache: false)
        }
        let resultTask = task
        let generation = cacheGeneration
        thumbnails = Task {
            guard let result = try? await resultTask.value, !Task.isCancelled,
                  generation == APICache.generation else { return }
            // 表示を画像の完了待ちにせず、最初に見える表紙だけ既存キャッシュへ先読みする。
            var seen = Set<URL>()
            let urls = (result.response.results ?? []).prefix(6).compactMap { content -> URL? in
                guard let url = content.summary.coverURL, seen.insert(url).inserted else { return nil }
                return url
            }
            await withTaskGroup(of: Void.self) { group in
                var remaining = urls.makeIterator()
                for _ in 0..<3 {
                    guard !Task.isCancelled, generation == APICache.generation,
                          let url = remaining.next() else { break }
                    group.addTask { _ = await ImageCache.shared.image(for: url) }
                }
                for await _ in group {
                    guard !Task.isCancelled, generation == APICache.generation,
                          let url = remaining.next() else { continue }
                    group.addTask { _ = await ImageCache.shared.image(for: url) }
                }
            }
        }
    }

    func cancel() {
        task.cancel()
        thumbnails.cancel()
    }
}
