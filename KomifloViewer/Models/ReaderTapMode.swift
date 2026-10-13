import Foundation

/// 漫画ページの左右だけをめくりに使い、中央は操作バー用に残す。
enum ReaderTapMode: String, CaseIterable {
    case leftForward, rightForward, disabled

    static let key = "reader.tapMode"
    static let animationKey = "reader.tapAnimation"

    static func isCenter(_ fraction: Double) -> Bool {
        fraction.isFinite && fraction >= 1.0 / 3 && fraction <= 2.0 / 3
    }

    var title: String {
        switch self {
        case .leftForward: return "左タップで進む"
        case .rightForward: return "右タップで進む"
        case .disabled: return "タップめくりなし"
        }
    }

    func pageOffset(at fraction: Double) -> Int {
        guard self != .disabled, fraction.isFinite, (0...1).contains(fraction) else { return 0 }
        let direction = fraction < 1.0 / 3 ? 1 : (fraction > 2.0 / 3 ? -1 : 0)
        return self == .rightForward ? -direction : direction
    }
}
