import SwiftUI

/// 指の移動と、指を離した後の移動を同じ位置でつなぐ。
@MainActor
final class ReaderIndexMotion: ObservableObject {
    enum Phase { case hidden, preparing, openingDrag, opening, open, closingDrag, closing }
    @Published private(set) var phase: Phase = .hidden
    @Published private(set) var offset: CGFloat = 0
    private var height: CGFloat = 1
    private var ticket = UUID()
    var isPresented: Bool { phase != .hidden }
    /// 公式Webと同じく、操作が確定した時点でアイコンの向きを切り替える。
    var isIndexMode: Bool {
        switch phase {
        case .preparing, .opening, .open, .closingDrag: return true
        case .hidden, .openingDrag, .closing: return false
        }
    }
    var acceptsTouches: Bool { phase == .open || phase == .closingDrag }

    func resize(height: CGFloat) {
        let next = max(1, height)
        guard next != self.height else { return }
        let fraction = offset / self.height
        self.height = next
        withoutAnimation { offset = min(next, max(0, fraction * next)) }
    }

    func open(animated: Bool) {
        if isPresented { settle(open: true, animated: animated); return }
        ticket = UUID()
        withoutAnimation {
            offset = animated ? height : 0
            phase = animated ? .preparing : .open
        }
    }

    func appeared(animated: Bool) {
        if phase == .preparing { settle(open: true, animated: animated) }
    }

    func pullOpen(distance: CGFloat) {
        guard phase == .hidden || phase == .openingDrag else { return }
        ticket = UUID()
        withoutAnimation {
            phase = .openingDrag
            offset = height - min(height, max(0, distance))
        }
    }

    func finishOpening(distance: CGFloat, predicted: CGFloat, cancelled: Bool, animated: Bool) {
        guard phase == .openingDrag else { return }
        settle(open: !cancelled && (distance >= 64 || predicted >= 140), animated: animated)
    }

    func pullClosed(distance: CGFloat) {
        guard phase == .open || phase == .closingDrag else { return }
        ticket = UUID()
        withoutAnimation {
            phase = .closingDrag
            offset = min(height, max(0, distance))
        }
    }

    func finishClosing(distance: CGFloat, predicted: CGFloat, animated: Bool) {
        guard phase == .closingDrag else { return }
        settle(open: !(distance > 100 || predicted > 250), animated: animated)
    }

    func close(animated: Bool) {
        guard isPresented else { return }
        settle(open: false, animated: animated)
    }

    private func settle(open: Bool, animated: Bool) {
        let next = UUID()
        ticket = next
        let finish = { [weak self] in
            guard let self, self.ticket == next else { return }
            // パネルの位置は補間せず、ナビと進捗表示の既存の演出は許可する。
            withTransaction(Transaction(animation: nil)) { self.phase = open ? .open : .hidden }
        }
        guard animated else {
            withoutAnimation { offset = open ? 0 : height }
            finish()
            return
        }
        phase = open ? .opening : .closing
        withAnimation(.easeOut(duration: 0.22), completionCriteria: .logicallyComplete) {
            offset = open ? 0 : height
        } completion: {
            finish()
        }
    }

    private func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }
}
