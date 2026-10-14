import Foundation

/// 公式の「配信カレンダー」記事（/articles/magazine-schedule-YYMM）から読んだ、その月の雑誌の配信予定。
/// 公式は画像のカレンダーと同じ内容を本文の箇条書きにも載せているので、箇条書きだけを読む
struct DeliverySchedule: Equatable, Identifiable {
    struct Entry: Equatable, Hashable {
        let slug: String
        let name: String
    }

    /// 本文の箇条書き1行（「10月2日」「毎週日曜日」と、その日の雑誌）
    struct Line: Equatable, Hashable {
        let label: String
        let entries: [Entry]
    }

    /// 記事のslug（magazine-schedule-2610）
    let slug: String
    let year: Int
    let month: Int
    /// その月の日ごとの配信（記事の順）
    let days: [Int: [Entry]]
    /// 毎週の配信（キーはCalendarの曜日：1が日曜、7が土曜）
    let weekly: [Int: [Entry]]
    let lines: [Line]
    /// 記事の画像（公式のカレンダー）。左の帯（月・キャラクター）の絵だけを切り出して使う
    var imageURL: URL? = nil

    var id: String { slug }

    static let slugPrefix = "magazine-schedule-"

    /// その日の配信（日付の指定を先に、毎週の配信を後に並べる。公式の画像と同じ順）
    func entries(day: Int, weekday: Int) -> [Entry] {
        (days[day] ?? []) + (weekly[weekday] ?? [])
    }

    static func parse(slug: String, title: String?, body: String) -> DeliverySchedule? {
        guard let (year, month) = yearMonth(slug: slug, title: title) else { return nil }
        var days: [Int: [Entry]] = [:]
        var weekly: [Int: [Entry]] = [:]
        var lines: [Line] = []
        for item in matches(#"<li[^>]*>(.*?)</li>"#, in: body) {
            let html = item[1]
            let entries = matches(#"<a[^>]*href\s*=\s*"([^"]*)"[^>]*>(.*?)</a>"#, in: html).compactMap { anchor -> Entry? in
                guard let magazine = magazineSlug(anchor[1]) else { return nil }
                let name = plainText(anchor[2])
                return Entry(slug: magazine, name: name.isEmpty ? magazine : name)
            }
            guard !entries.isEmpty else { continue }
            let labelHTML = html.range(of: "<a").map { String(html[..<$0.lowerBound]) } ?? html
            let label = plainText(labelHTML)
            if let date = matches(#"(\d{1,2})月(\d{1,2})日"#, in: label).first,
               Int(date[1]) == month, let day = Int(date[2]), (1...31).contains(day) {
                days[day, default: []] += entries
            } else if let weekdayName = matches(#"毎週([日月火水木金土])曜"#, in: label).first?[1],
                      let weekday = ["日", "月", "火", "水", "木", "金", "土"].firstIndex(of: weekdayName) {
                weekly[weekday + 1, default: []] += entries
            }
            lines.append(Line(label: label, entries: entries))
        }
        guard !lines.isEmpty else { return nil }
        let image = matches(#"<img[^>]*src\s*=\s*"([^"]+)""#, in: body).first.flatMap { URL(string: $0[1]) }
        return DeliverySchedule(slug: slug, year: year, month: month, days: days, weekly: weekly, lines: lines,
                                imageURL: image)
    }

    /// slugの年月（2610 → 2026年10月）を使い、読めなければタイトルの「2026年10月」を使う
    private static func yearMonth(slug: String, title: String?) -> (Int, Int)? {
        if slug.hasPrefix(slugPrefix) {
            let digits = slug.dropFirst(slugPrefix.count)
            if digits.count == 4, let value = Int(digits), (1...12).contains(value % 100) {
                return (2000 + value / 100, value % 100)
            }
        }
        if let title, let found = matches(#"(\d{4})年(\d{1,2})月"#, in: title).first,
           let year = Int(found[1]), let month = Int(found[2]), (1...12).contains(month) {
            return (year, month)
        }
        return nil
    }

    /// /magazines/<slug> と /magazines/titles/<slug> の両方を受け付ける
    private static func magazineSlug(_ href: String) -> String? {
        let path = href.components(separatedBy: "#!").last ?? href
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "magazines"), index + 1 < parts.count else { return nil }
        let slug = parts[index + 1] == "titles" && index + 2 < parts.count ? parts[index + 2] : parts[index + 1]
        return slug.isEmpty ? nil : slug
    }

    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
}

/// 日本の祝日（現行の祝日法の決まり。カレンダーの日曜と同じ色で示すのに使う）
enum JapaneseHoliday {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }()

    static func contains(year: Int, month: Int, day: Int) -> Bool {
        holidays(year: year).contains(month * 100 + day)
    }

    /// 月×100＋日の集合
    static func holidays(year: Int) -> Set<Int> {
        var result: Set<Int> = [101, 211, 223, 429, 503, 504, 505, 811, 1103, 1123]
        // ハッピーマンデー（成人の日・海の日・敬老の日・スポーツの日）
        for (month, nth) in [(1, 2), (7, 3), (9, 3), (10, 2)] {
            if let day = nthMonday(year: year, month: month, nth: nth) { result.insert(month * 100 + day) }
        }
        // 春分の日・秋分の日（1980〜2099年の近似式）
        let elapsed = Double(year - 1980)
        let leap = (year - 1980) / 4
        result.insert(300 + Int(20.8431 + 0.242194 * elapsed) - leap)
        result.insert(900 + Int(23.2488 + 0.242194 * elapsed) - leap)
        // 国民の休日：前日と翌日が祝日の平日
        for key in result {
            guard let date = date(year: year, key: key), let next = calendar.date(byAdding: .day, value: 1, to: date),
                  let after = calendar.date(byAdding: .day, value: 2, to: date),
                  calendar.component(.year, from: after) == year, result.contains(self.key(after)),
                  !result.contains(self.key(next)), calendar.component(.weekday, from: next) != 1 else { continue }
            result.insert(self.key(next))
        }
        // 振替休日：日曜の祝日の後で、最初の祝日でない日
        for key in result.sorted() {
            guard let date = date(year: year, key: key), calendar.component(.weekday, from: date) == 1 else { continue }
            var substitute = calendar.date(byAdding: .day, value: 1, to: date)
            while let day = substitute, result.contains(self.key(day)) {
                substitute = calendar.date(byAdding: .day, value: 1, to: day)
            }
            if let substitute, calendar.component(.year, from: substitute) == year { result.insert(self.key(substitute)) }
        }
        return result
    }

    private static func nthMonday(year: Int, month: Int, nth: Int) -> Int? {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
        let weekday = calendar.component(.weekday, from: first)
        let firstMonday = 1 + (9 - weekday) % 7
        return firstMonday + (nth - 1) * 7
    }

    private static func date(year: Int, key: Int) -> Date? {
        calendar.date(from: DateComponents(year: year, month: key / 100, day: key % 100))
    }

    private static func key(_ date: Date) -> Int {
        calendar.component(.month, from: date) * 100 + calendar.component(.day, from: date)
    }
}
