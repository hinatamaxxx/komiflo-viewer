import SwiftUI

/// 雑誌の配信カレンダー。公式は月ごとの記事に画像のカレンダーを載せているが、
/// 同じ記事の箇条書き（日付と雑誌）を読み、公式の画像と同じ形の月のカレンダーをアプリで描く
struct DeliveryCalendarView: View {
    let initialSlug: String?
    @ObservedObject var library: LibraryStore
    /// ホームのバナーから開いたときは、そのバナー画像を帯に使う（特集と同じ）
    var headerImageURL: URL?
    @Environment(\.openRoute) private var openRoute
    @Environment(\.dismiss) private var dismiss

    @State private var schedules: [DeliverySchedule] = []
    @State private var selection: String?
    @State private var loadError: String?
    @State private var progress = PagerProgress()
    /// スワイプの途中で、半分を越えた月（帯の日付に使う）。月が変わったときだけ書き換える
    @State private var visibleSlug: String?
    /// マガジンラックと同じ雑誌の情報（表紙＝雑誌のページのヘッダー画像）。slugで引く
    @State private var magazines: [String: MagazineTitle] = [:]

    private var current: Binding<String> {
        Binding(get: { selection ?? schedules.first?.slug ?? "" }, set: { selection = $0 })
    }

    var body: some View {
        // 作家・特集・タグと同じ、縮む画像の帯の画面。月の切り替えは帯の下に付ける（タグのページ番号と同じ）
        Group {
            if schedules.isEmpty {
                ImageHeaderPage { width, layout, scroll in
                    header(width: width, layout: layout, scroll: scroll, picker: nil)
                } content: { _, width, minimumHeight in
                    status
                        .frame(width: width)
                        .frame(minHeight: minimumHeight)
                }
            } else {
                ImageHeaderPagedPage(items: schedules.map(\.slug), selection: current, footerHeight: 44,
                                     progress: progress) { width, layout, scroll in
                    header(width: width, layout: layout, scroll: scroll,
                           picker: AnyView(monthPicker.background(Theme.background)))
                } content: { slug, width, minimumHeight in
                    Group {
                        if let index = schedules.firstIndex(where: { $0.slug == slug }) {
                            DeliveryMonthPage(schedule: schedules[index],
                                              previous: neighbor(of: schedules[index], by: -1),
                                              next: neighbor(of: schedules[index], by: 1),
                                              onOpen: open)
                        }
                    }
                    .frame(width: width)
                    .frame(minHeight: minimumHeight, alignment: .top)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        // 帯の日付は、指を離して止まるのを待たず、ページが半分を越えたところで切り替える
        .onReceive(progress.$position) { position in
            guard let position, !schedules.isEmpty else { return }
            let index = min(schedules.count - 1, max(0, Int(position.rounded())))
            let slug = schedules[index].slug
            if visibleSlug != slug { visibleSlug = slug }
        }
        .task { await load() }
        .task { await loadMagazines() }
    }

    private func header(width: CGFloat, layout: ArtistHeaderLayout, scroll: ArtistHeaderScroll,
                        picker: AnyView?) -> some View {
        ImagePageHeader(artist: nil, title: "配信カレンダー", total: nil, width: width, layout: layout, scroll: scroll,
                        isFollowing: false, followAnimated: false, onFollow: nil, onBack: { dismiss() },
                        // バナーから開いていなければ、いちばん新しい月の公式のカレンダー画像を使う
                        bannerURL: headerImageURL ?? schedules.first?.imageURL,
                        // 表示中の月を名前の下に出し、帯が縮んだら「配信カレンダー 2026年10月」と横に並べる
                        countText: displayedMonth, compactCountInline: true,
                        sectionPicker: picker)
    }

    private var displayedMonth: String? {
        schedules.first { $0.slug == (visibleSlug ?? current.wrappedValue) }.map { "\($0.year)年\($0.month)月" }
    }

    /// 月の切り替え（マガジンラックの「26.10」と同じ形、タグのページ番号と同じ高さ）
    private var monthPicker: some View {
        PagerTabs(items: schedules.map(\.slug), selection: current, progress: progress, scrolls: true,
                  font: .footnote.weight(.semibold)) { slug in
            schedules.first { $0.slug == slug }.map { "\($0.year % 100).\($0.month)" } ?? slug
        }
        .frame(height: 32)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var status: some View {
        if let loadError {
            VStack(spacing: 12) {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("再読み込み") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
        } else {
            ProgressView()
                .padding(.top, 40)
        }
    }

    /// 前後の月の記事（カレンダーの端に見える前後の月の日に、その月の配信を薄く出す）
    private func neighbor(of schedule: DeliverySchedule, by months: Int) -> DeliverySchedule? {
        let total = schedule.year * 12 + schedule.month - 1 + months
        return schedules.first { $0.year == total / 12 && $0.month == total % 12 + 1 }
    }

    /// マガジンラックから開くときと同じ雑誌の情報で開く（ヘッダーの表紙が出る）。
    /// ラックに無い雑誌だけ、リンクと同じ扱いで開く
    private func open(_ entry: DeliverySchedule.Entry) {
        if let magazine = magazines[entry.slug] {
            openRoute(.magazine(magazine))
        } else if let route = Route(sitePath: "/magazines/\(entry.slug)", title: entry.name) {
            openRoute(route)
        }
    }

    /// 前回保存した一覧ですぐ表示し、公式から取り直して、変わっていれば差し替える
    private func load() async {
        loadError = nil
        let api = library.api
        if schedules.isEmpty, let saved = try? await APICache.fromCache({ try await api.specialContents() }) {
            apply(saved)
        }
        do {
            apply(try await api.specialContents())
        } catch {
            guard !(error is CancellationError) else { return }
            if schedules.isEmpty { loadError = error.localizedDescription }
        }
        if schedules.isEmpty, loadError == nil { loadError = "配信カレンダーの記事が見つかりませんでした。" }
    }

    private func loadMagazines() async {
        let api = library.api
        if let saved = try? await APICache.fromCache({ try await api.magazineRack() }) { applyMagazines(saved) }
        if let fresh = try? await api.magazineRack() { applyMagazines(fresh) }
    }

    private func applyMagazines(_ titles: [MagazineTitle]) {
        magazines = Dictionary(titles.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func apply(_ articles: [KFArticle]) {
        let parsed = articles.compactMap { article -> DeliverySchedule? in
            guard let slug = article.slug, slug.hasPrefix(DeliverySchedule.slugPrefix), let body = article.body else { return nil }
            return DeliverySchedule.parse(slug: slug, title: article.data?.title, body: body)
        }
        // 左が新しい月（マガジンラックの月と同じ並び）
        .sorted { ($0.year, $0.month) > ($1.year, $1.month) }
        guard !parsed.isEmpty, parsed != schedules else { return }
        if selection == nil {
            // 開いた記事の月 → 今月 → いちばん新しい月の順で選ぶ
            let now = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
            selection = parsed.first { $0.slug == initialSlug }?.slug
                ?? parsed.first { $0.year == now.year && $0.month == now.month }?.slug
                ?? parsed.first?.slug
        }
        schedules = parsed
    }
}

/// 1か月分：公式の画像と同じ形のカレンダーと、記事と同じ日付の一覧
private struct DeliveryMonthPage: View {
    let schedule: DeliverySchedule
    let previous: DeliverySchedule?
    let next: DeliverySchedule?
    let onOpen: (DeliverySchedule.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
                DeliveryCalendarCard(schedule: schedule, previous: previous, next: next, onOpen: onOpen)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(schedule.lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(line.label)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 72, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(line.entries, id: \.self) { entry in
                                    Button(entry.name) { onOpen(entry) }
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: 640)
        .padding(16)
        .frame(maxWidth: .infinity)
    }
}

/// カレンダーの色。明るい表示は公式の画像と同じ。暗い表示（アプリの標準）は同じ配色を暗い台紙に合わせる
private struct CalendarPalette {
    let card: Color
    let cell: Color
    let border: Color
    let saturday: Color
    let saturdayText: Color
    let sunday: Color
    let sundayText: Color
    let number: Color
    let weekday: Color
    let weekdayText: Color
    /// 前後の月の日の数字とロゴ
    let faded: Color

    static func make(_ scheme: ColorScheme) -> Self {
        if scheme == .dark {
            return .init(card: Color(red: 0.11, green: 0.11, blue: 0.13), cell: Color(red: 0.17, green: 0.17, blue: 0.2),
                         border: Color(white: 0.25), saturday: Color(red: 0.12, green: 0.21, blue: 0.3),
                         saturdayText: Color(red: 0.47, green: 0.74, blue: 0.96), sunday: Color(red: 0.29, green: 0.13, blue: 0.19),
                         sundayText: Color(red: 0.98, green: 0.47, blue: 0.62), number: Color(white: 0.82),
                         weekday: Color(white: 0.2), weekdayText: Color(white: 0.65), faded: Color(white: 0.4))
        }
        return .init(card: .white, cell: .white, border: Color(white: 0.88),
                     saturday: Color(red: 0.84, green: 0.92, blue: 0.98), saturdayText: Color(red: 0.23, green: 0.6, blue: 0.85),
                     sunday: Color(red: 0.99, green: 0.89, blue: 0.92), sundayText: Theme.accent, number: Color(white: 0.3),
                     weekday: Color(white: 0.95), weekdayText: Color(white: 0.45), faded: Color(white: 0.78))
    }
}

/// 公式の画像と同じ配色のカレンダー：上に大きな月と月名・年、下に月曜始まりの7列。
/// 配信日はピンクに雑誌のロゴ、土曜は水色、日曜・祝日は薄いピンク。
/// 前後の月の日は台紙の色のまま、数字とロゴを薄く出す（公式と同じ）
private struct DeliveryCalendarCard: View {
    let schedule: DeliverySchedule
    let previous: DeliverySchedule?
    let next: DeliverySchedule?
    let onOpen: (DeliverySchedule.Entry) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private static let weekdays = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]

    private var palette: CalendarPalette { .make(colorScheme) }

    private struct Day: Hashable {
        let year: Int
        let month: Int
        let day: Int
        let weekday: Int
        let inMonth: Bool
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }

    /// 月曜から日曜までの週ごとの日（前後の月の日も含める）
    private var weeks: [[Day]] {
        guard let first = calendar.date(from: DateComponents(year: schedule.year, month: schedule.month, day: 1)),
              let count = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: first) + 5) % 7
        let cells = Int((Double(leading + count) / 7).rounded(.up)) * 7
        let days = (0..<cells).compactMap { index -> Day? in
            guard let date = calendar.date(byAdding: .day, value: index - leading, to: first) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day, let weekday = parts.weekday else { return nil }
            return Day(year: year, month: month, day: day, weekday: weekday, inMonth: month == schedule.month)
        }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(spacing: 4) {
                ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { index, name in
                    Text(name)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(index == 5 ? palette.saturdayText : index == 6 ? palette.sundayText : palette.weekdayText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(index == 5 ? palette.saturday : index == 6 ? palette.sunday : palette.weekday,
                                    in: RoundedRectangle(cornerRadius: 3))
                }
            }
            VStack(spacing: 4) {
                ForEach(weeks, id: \.self) { week in
                    HStack(spacing: 4) {
                        ForEach(week, id: \.self) { day in cell(day) }
                    }
                }
            }
        }
        .padding(12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(schedule.month)")
                .font(.system(size: 52, weight: .heavy))
                .foregroundStyle(Theme.accent)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(monthName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(String(schedule.year))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.weekdayText)
            }
            Spacer()
            Text("配信カレンダー")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.number)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var monthName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.monthSymbols[schedule.month - 1].uppercased()
    }

    private func deliveries(on day: Day) -> [DeliverySchedule.Entry] {
        let source = day.inMonth ? schedule : (previous?.month == day.month ? previous : next?.month == day.month ? next : nil)
        return source?.entries(day: day.day, weekday: day.weekday) ?? []
    }

    @ViewBuilder
    private func cell(_ day: Day) -> some View {
        let entries = deliveries(on: day)
        let content = cellContent(day, entries: entries)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(day.month)月\(day.day)日 " + entries.map(\.name).joined(separator: "、"))
        if entries.count == 1, let entry = entries.first {
            Button { onOpen(entry) } label: { content }
                .buttonStyle(.plain)
        } else if entries.count > 1 {
            // 同じ日に複数あるときは、どの雑誌を開くか選ぶ
            Menu {
                ForEach(entries, id: \.self) { entry in
                    Button(entry.name) { onOpen(entry) }
                }
            } label: { content }
        } else {
            content
        }
    }

    private func cellContent(_ day: Day, entries: [DeliverySchedule.Entry]) -> some View {
        let holiday = day.weekday == 1 || JapaneseHoliday.contains(year: day.year, month: day.month, day: day.day)
        let saturday = day.weekday == 7
        // 配信日のピンクはその月の日だけ。前後の月の日は台紙の色に薄い数字とロゴ（公式と同じ）
        let delivered = day.inMonth && !entries.isEmpty
        let tint: Color? = holiday ? palette.sunday : saturday ? palette.saturday : nil
        let fill: Color = delivered ? Theme.accent
            : tint.map { day.inMonth ? $0 : $0.opacity(0.5) } ?? palette.cell
        let number: Color = delivered ? .white : !day.inMonth ? palette.faded
            : holiday ? palette.sundayText : saturday ? palette.saturdayText : palette.number
        let logo: Color = delivered ? .white : palette.faded
        return RoundedRectangle(cornerRadius: 3)
            .fill(fill)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(delivered || tint != nil ? .clear : palette.border, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                Text("\(day.day)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(number)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
            .overlay {
                if !entries.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(entries, id: \.self) { entry in
                            DeliveryMagazineLogo(entry: entry)
                        }
                    }
                    .foregroundStyle(logo)
                    .padding(.horizontal, 3)
                    .padding(.top, 13)
                    .padding(.bottom, 3)
                }
            }
            .aspectRatio(1.2, contentMode: .fit)
            .frame(maxWidth: .infinity)
    }
}

/// 公式のロゴを一色で描く（色は呼び出し側。ロゴが無い雑誌は名前）
private struct DeliveryMagazineLogo: View {
    let entry: DeliverySchedule.Entry
    @State private var image: UIImage?

    private var row: Int? { MagazineIdentity.rows[entry.slug] }

    init(entry: DeliverySchedule.Entry) {
        self.entry = entry
        _image = State(initialValue: MagazineIdentity.rows[entry.slug].flatMap { ImageCache.shared.memoryMagazineLogo(row: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(entry.name)
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: row) {
            guard image == nil, let row else { return }
            image = await ImageCache.shared.magazineLogo(row: row)
        }
    }
}
