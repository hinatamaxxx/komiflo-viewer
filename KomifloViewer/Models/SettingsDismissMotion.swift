import Foundation

/// 認識待ちの移動量を最初の表示位置へ加えず、指の追従を0から始める。
enum SettingsDismissMotion {
    static func canBegin(offset: CGFloat, top: CGFloat, velocity: CGPoint) -> Bool {
        offset <= top + 1 && velocity.y > 0 && velocity.y > abs(velocity.x)
    }

    static func canTrackScroll(velocity: CGPoint) -> Bool {
        abs(velocity.y) > abs(velocity.x)
    }

    static func handoffOrigin(translation: CGFloat, offset: CGFloat, top: CGFloat) -> CGFloat {
        translation - max(0, top - offset)
    }

    static func scrollReturnDistance(translation: CGFloat, origin: CGFloat, velocityY: CGFloat) -> CGFloat? {
        guard translation <= origin, velocityY < 0 else { return nil }
        return origin - translation
    }

    static func distance(translation: CGFloat, origin: CGFloat) -> CGFloat {
        max(0, translation - origin)
    }

    static func shouldClose(distance: CGFloat, velocity: CGFloat, cancelled: Bool) -> Bool {
        !cancelled && distance > 0 && (distance > 120 || distance + velocity * 0.2 > 300)
    }
}
