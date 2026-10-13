import Foundation
import QuartzCore

/// ナビの移動や枠の再配置と分け、再生状態が変わった時だけ進捗の演出を設定する。
final class ReaderAutoplayProgress {
    static let animationKey = "reader.autoplay.progress"
    private var appliedClock: ReaderAutoplayClock?

    func invalidate() { appliedClock = nil }

    func apply(_ clock: ReaderAutoplayClock, to layer: CALayer, keyPath: String, at now: TimeInterval) {
        guard appliedClock != clock else { return }
        appliedClock = clock
        let fraction = clock.fraction(at: now)
        let remaining = clock.remaining(at: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.setValue(clock.isPlaying ? 1 : fraction, forKeyPath: keyPath)
        if clock.isPlaying, remaining > 0 {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = fraction
            animation.toValue = 1
            animation.duration = remaining
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }
}
