import Foundation

/// ページ遷移・Cookie変更があったときだけ確認し、ログイン後に一度だけ戻る。
@MainActor
final class LoginCompletion {
    private let check: () async -> Bool
    private let onCompleted: () -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var stopped = false

    init(check: @escaping () async -> Bool, onCompleted: @escaping () -> Void) {
        self.check = check
        self.onCompleted = onCompleted
    }

    func changed() {
        guard !stopped else { return }
        generation += 1
        if task == nil { start() }
    }

    private func start() {
        let ticket = generation
        task = Task { [weak self] in
            guard let self else { return }
            let loggedIn = await check()
            guard !stopped, !Task.isCancelled else { return }
            task = nil
            if loggedIn {
                stopped = true
                onCompleted()
            } else if generation != ticket {
                start()
            }
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
    }
}
