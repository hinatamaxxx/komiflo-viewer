import Foundation

/// 公式Webの「ページ表示モード」（twoPageMode）。値と標準値は公式と同じ。
enum ReaderSpreadMode: Int, CaseIterable, Identifiable {
    case single = 0, spreadsOnly = 1, whenPossible = 2

    static let key = "reader.native.twoPageMode"
    static let initial = ReaderSpreadMode.spreadsOnly
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .single: return "1ページずつ表示"
        case .spreadsOnly: return "1ページずつ表示（見開き時は2ページ表示）"
        case .whenPossible: return "2ページずつ表示（可能な限り）"
        }
    }
}

/// 見開きを使う画面の向き。公式Webには向き別の設定がないため、アプリ独自の設定。
enum ReaderSpreadOrientation: String, CaseIterable, Identifiable {
    case landscape, always

    static let key = "reader.native.spreadOrientation"
    static let phoneKey = "reader.native.spreadOnPhone"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .landscape: return "横長の画面のときだけ"
        case .always: return "縦長の画面でも"
        }
    }

    /// iPadは通常幅の画面、iPhoneは設定したときの横向きだけで見開きを使う。
    static func allows(_ orientation: ReaderSpreadOrientation, size: CGSize, isPad: Bool,
                       regularWidth: Bool, phoneEnabled: Bool) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let landscape = size.width > size.height
        if isPad { return regularWidth && (landscape || orientation == .always) }
        return phoneEnabled && landscape
    }
}

/// 画像そのものは変えず、どのページを左右に並べるかだけを決める。
/// 公式Webと同じく右から左へ読み、組の小さい番号を右側に置く。
struct ReaderSpreadLayout: Equatable {
    let count: Int
    /// 次のページと組む先頭のページ番号。
    let pairStarts: Set<Int>

    static func single(count: Int) -> Self { Self(count: count, pairStarts: []) }

    /// 公式のmoveToと同じ規則。先頭は表紙として1ページ（rightStart指定時を除く）、
    /// 以降は2ページずつ組み、組めない最後のページと読み終わり画面は1ページで出す。
    /// 「見開き時」は公式のlabel-firstdoublepageで指定された組だけを並べる。
    init(count: Int, mode: ReaderSpreadMode, rightStart: Bool, labeledStarts: Set<Int>) {
        self.count = max(0, count)
        guard mode != .single, count > 1 else { pairStarts = []; return }
        let candidates = stride(from: rightStart ? 1 : 2, to: count, by: 2)
        pairStarts = Set(candidates.filter { mode == .whenPossible || labeledStarts.contains($0) })
    }

    init(count: Int, pairStarts: Set<Int>) {
        self.count = max(0, count)
        self.pairStarts = pairStarts
    }

    var isSingle: Bool { pairStarts.isEmpty }

    /// そのページを含む組の先頭。読み終わり画面（count+1）はそのまま。
    func start(of page: Int) -> Int {
        if page > 1, page <= count, pairStarts.contains(page - 1) { return page - 1 }
        return page
    }

    /// 組のページ番号を読む順に返す。
    func pages(startingAt start: Int) -> [Int] {
        pairStarts.contains(start) && start + 1 <= count ? [start, start + 1] : [start]
    }

    func next(after page: Int) -> Int {
        let first = start(of: page)
        return first + pages(startingAt: first).count
    }

    func previous(before page: Int) -> Int {
        start(of: start(of: page) - 1)
    }
}
