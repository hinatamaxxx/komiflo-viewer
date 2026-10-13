import Foundation

/// 公式Webの雑誌ラインアップ順。発売日や月ごとの取得順には依存しない。
enum MagazineLineup {
    private static let slugs = [
        "kairakuten", "beast", "x-eros", "shitsurakuten", "bavel", "weekly-kairakuten",
        "hotmilk", "megastore", "hotmilk-koime", "isekairakuten", "dascomi", "dungeon-koryaku", "gaira",
        "special_contents", "xtc", "wani-anthology", "wani-special-issue", "core-special-issue",
        "bunendo-special-issue", "special", "megastorealpha", "comichappining",
    ]
    private static let ranks = Dictionary(uniqueKeysWithValues: slugs.enumerated().map { ($0.element, $0.offset) })

    static func ordered<T>(_ items: [T], slug: (T) -> String?) -> [T] {
        items.enumerated().sorted { a, b in
            let left = slug(a.element)
            let right = slug(b.element)
            let leftRank = left.flatMap { ranks[$0] } ?? Int.max
            let rightRank = right.flatMap { ranks[$0] } ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            // 未登録の雑誌も月ごとに入れ替わらず、同じ雑誌の号は元の順番を保つ。
            if leftRank == Int.max, left != right {
                return (left ?? "\u{10FFFF}") < (right ?? "\u{10FFFF}")
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}
