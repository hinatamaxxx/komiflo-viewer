import Foundation

/// アプリの切り替えをまたぐ取得は通信速度の判定から外す。通信そのものは止めない。
@MainActor
final class ReaderImageLoadTiming {
    struct Sample {
        let started: ContinuousClock.Instant
        let revision: Int
    }
    enum LimitReached: Error { case slow }

    private var isActive = true
    private var revision = 0
    private var pending: [UUID: (CheckedContinuation<Void, Error>, Task<Void, Never>?)] = [:]

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if !active {
            revision += 1
            for (_, timer) in pending.values { timer?.cancel() }
        }
    }

    func sample(at now: ContinuousClock.Instant = ContinuousClock().now) -> Sample? {
        isActive ? Sample(started: now, revision: revision) : nil
    }

    func elapsed(_ sample: Sample?, at now: ContinuousClock.Instant = ContinuousClock().now) -> Double? {
        guard isActive, let sample, sample.revision == revision else { return nil }
        let elapsed = sample.started.duration(to: now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    func waitForLimit(_ sample: Sample?, seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timer: Task<Void, Never>?
                if let elapsed = elapsed(sample) {
                    timer = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(max(0, seconds - elapsed))) }
                        catch { return }
                        guard let self, self.elapsed(sample) != nil else { return }
                        self.pending.removeValue(forKey: id)?.0.resume(throwing: LimitReached.slow)
                    }
                } else {
                    timer = nil
                }
                // 判定対象外になっても、通信完了によるTaskGroupの取り消しまでは待つ。
                pending[id] = (continuation, timer)
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        })
    }

    func cancelAll() {
        for id in Array(pending.keys) { cancel(id) }
    }

    private func cancel(_ id: UUID) {
        guard let (continuation, timer) = pending.removeValue(forKey: id) else { return }
        timer?.cancel()
        continuation.resume(throwing: CancellationError())
    }
}
