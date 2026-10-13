import Foundation

/// 再生・一時停止の時刻だけを保存し、ページ送りと進捗表示で同じ残り時間を使う。
struct ReaderAutoplayClock: Equatable {
    enum Status: Equatable { case inactive, playing, paused }
    enum PauseReason: Equatable { case user, navigation }
    private(set) var status: Status = .inactive
    private(set) var pauseReason: PauseReason?
    private(set) var duration: TimeInterval = 6
    private(set) var elapsed: TimeInterval = 0
    private(set) var startedAt: TimeInterval?

    var isPlaying: Bool { status == .playing }
    var isVisible: Bool { status != .inactive }

    func shouldResumeAfterNavigation(enabled: Bool) -> Bool {
        enabled && status == .paused && pauseReason == .navigation
    }

    func remaining(at now: TimeInterval) -> TimeInterval {
        let running = startedAt.map { max(0, now - $0) } ?? 0
        return max(0, duration - elapsed - running)
    }

    func fraction(at now: TimeInterval) -> Double {
        isVisible ? min(1, max(0, 1 - remaining(at: now) / duration)) : 0
    }

    mutating func start(duration: TimeInterval, at now: TimeInterval) {
        self.duration = duration.isFinite && duration > 0 ? duration : 6
        elapsed = 0
        startedAt = now
        status = .playing
        pauseReason = nil
    }

    mutating func pause(at now: TimeInterval, reason: PauseReason = .user) {
        guard isPlaying else { return }
        elapsed = duration - remaining(at: now)
        startedAt = nil
        status = .paused
        pauseReason = reason
    }

    mutating func resume(at now: TimeInterval) {
        guard status == .paused else { return }
        startedAt = now
        status = .playing
        pauseReason = nil
    }

    mutating func clear() {
        status = .inactive
        pauseReason = nil
        startedAt = nil
        elapsed = 0
    }
}
