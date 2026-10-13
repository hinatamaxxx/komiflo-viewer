import Foundation

struct MagazineIdentity: Hashable, Codable, Sendable {
    let slug: String
    let name: String

    static let names = [
        "kairakuten": "快楽天", "shitsurakuten": "失楽天", "x-eros": "X-EROS",
        "beast": "快楽天ビースト", "hotmilk": "HOTMILK", "hotmilk-koime": "HOTMILK濃いめ",
        "megastore": "メガストア", "bavel": "BAVEL", "dascomi": "ダスコミ", "gaira": "外楽",
        "isekairakuten": "異世界快楽天", "weekly-kairakuten": "WEEKLY快楽天",
        "dungeon-koryaku": "ダンジョン攻略はSEXで!!", "plus": "Komiflo Plus",
        "original": "Komifloオリジナル", "wani-anthology": "WANI ANTHOLOGY"
    ]
    static let rows = [
        "kairakuten": 0, "shitsurakuten": 1, "x-eros": 2, "beast": 3, "hotmilk": 4,
        "hotmilk-koime": 5, "megastore": 6, "bavel": 7, "dascomi": 8, "gaira": 9,
        "isekairakuten": 10, "weekly-kairakuten": 11, "dungeon-koryaku": 12,
        "plus": 13, "original": 14, "wani-anthology": 15
    ]
    private static let issueNames = (names.map { (slug: $0.key, name: $0.value) }
        + [(slug: "x-eros", name: "ゼロス"), (slug: "beast", name: "BEAST")])
        .sorted { $0.name.count > $1.name.count }

    static func resolve(slug: String?, issue: String?) -> MagazineIdentity? {
        if let slug, rows[slug] != nil {
            return .init(slug: slug, name: names[slug] ?? issue ?? slug)
        }
        guard let issue else { return nil }
        let normalized = normalize(issue)
        return issueNames.first { normalized.contains(normalize($0.name)) }
            .map { .init(slug: $0.slug, name: names[$0.slug] ?? $0.name) }
    }

    private static func normalize(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace }
    }

    /// ロゴ未対応の掲載名も表示する。情報のない作品をオリジナルと推測しない。
    static func display(slug: String?, issue: String?) -> MagazineIdentity? {
        if let known = resolve(slug: slug, issue: issue) { return known }
        if let issue = issue?.trimmingCharacters(in: .whitespacesAndNewlines), !issue.isEmpty {
            return .init(slug: slug ?? "", name: issue)
        }
        if let slug, !slug.isEmpty { return .init(slug: slug, name: "掲載誌：\(slug)") }
        return nil
    }

    static func display(comic: ComicSummary, in magazine: MagazineIdentity? = nil) -> MagazineIdentity? {
        if comic.isKomifloOriginal == true { return .original }
        return display(slug: comic.magazineSlug, issue: comic.magazine) ?? magazine
    }

    /// 収録号の雑誌が分かる棚は、その情報を使って個別の取得を省く。
    static func needsLookup(comic: ComicSummary, in magazine: MagazineIdentity? = nil) -> Bool {
        magazine == nil && (comic.isKomifloOriginal == nil || display(comic: comic) == nil)
    }

    static let original = MagazineIdentity(slug: "original", name: "Komifloオリジナル")
    static let unavailable = MagazineIdentity(slug: "", name: "掲載情報なし")
}

/// ロゴ本体の範囲だけを求める。段の境界と小さな余白は画像の大きさに合わせる。
enum MagazineLogoBounds {
    static func rows(rgba: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
                     count: Int) -> [Int: CGRect] {
        guard width > 0, height > 0, count > 0, count <= height,
              rgba.count >= width * height * 4 else { return [:] }
        let padding = max(1, width / 200)
        var result: [Int: CGRect] = [:]
        for row in 0..<count {
            let start = row * height / count
            let end = (row + 1) * height / count
            var minX = width, minY = end, maxX = -1, maxY = -1
            for y in start..<end {
                for x in 0..<width where rgba[(y * width + x) * 4 + 3] >= 24 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX else { continue }
            if row == 14 || row == 15,
               let end = firstWordEnd(rgba: rgba, width: width, x: minX...maxX, y: minY...maxY) {
                maxX = end
            }
            let left = max(0, minX - padding), top = max(start, minY - padding)
            result[row] = CGRect(x: left, y: top,
                width: min(width, maxX + 1 + padding) - left,
                height: min(end, maxY + 1 + padding) - top)
        }
        return result
    }

    /// Komiflo Originalsの単語間の透明な空白で切り、Komifloだけを残す。
    private static func firstWordEnd(rgba: UnsafeBufferPointer<UInt8>, width: Int,
                                     x: ClosedRange<Int>, y: ClosedRange<Int>) -> Int? {
        var start: Int?
        var longest = 0
        var end: Int?
        for column in x {
            let hasInk = y.contains { rgba[($0 * width + column) * 4 + 3] >= 24 }
            if !hasInk, start == nil { start = column }
            if hasInk, let gapStart = start {
                if column - gapStart > longest {
                    longest = column - gapStart
                    end = gapStart - 1
                }
                start = nil
            }
        }
        return longest >= max(2, Int(ceil(Double(x.count) * 0.025))) ? end : nil
    }
}
