import Foundation

/// ホームに既にある候補だけを一つずつ準備する。表示要求中は次の先読みを始めない。
actor HeaderPreparationQueue {
    private let prepare: @Sendable (URL) async -> Void
    private var pending: [URL] = []
    private var known: Set<String> = []
    private var foreground = 0
    private var running = false

    init(prepare: @escaping @Sendable (URL) async -> Void) { self.prepare = prepare }

    func enqueue(_ urls: [URL]) {
        for url in urls {
            let key = (url.host ?? "") + url.path
            if known.insert(key).inserted { pending.append(url) }
        }
        startNext()
    }

    func beginDisplay() { foreground += 1 }

    func endDisplay() {
        foreground = max(0, foreground - 1)
        startNext()
    }

    private func startNext() {
        guard !running, foreground == 0, !pending.isEmpty else { return }
        let url = pending.removeFirst()
        running = true
        Task(priority: .utility) {
            await prepare(url)
            finished()
        }
    }

    private func finished() {
        running = false
        startNext()
    }
}
