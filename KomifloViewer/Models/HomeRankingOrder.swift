import Foundation

/// ホームで確定したランキング全体を反転する。元の順位は変えない。
enum HomeRankingOrder: CaseIterable, Hashable {
    case ranked, reverse

    var label: String { self == .ranked ? "ランキング順" : "逆順" }

    func ordered(_ comics: [ComicSummary]) -> [ComicSummary] {
        self == .ranked ? comics : Array(comics.reversed())
    }

    static func ranks(for comics: [ComicSummary]) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: comics.enumerated().map { ($0.element.id, $0.offset + 1) })
    }
}
