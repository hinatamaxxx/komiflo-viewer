import SwiftUI

/// 両方の表示方式で共用する、読み終わりの部品の位置と中身。
struct ReaderEndSnapshot: Decodable, Equatable {
    struct Rect: Decodable, Equatable {
        let x: CGFloat
        let y: CGFloat
        let w: CGFloat
        let h: CGFloat

        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    struct Thumb: Decodable, Equatable {
        let r: Rect
        let img: String
        let title: String
        /// 作品ID（☆・♡ボタンに使う）
        var id: Int?
    }

    /// おすすめの表紙を、並びの位置ではなく作品ごとに区別するための目印
    var keyedThumbs: [(key: String, thumb: Thumb)] {
        (thumbs ?? []).enumerated().map { offset, thumb in
            if let id = thumb.id, id > 0 { return ("comic-\(id)", thumb) }
            return ("slot-\(offset)", thumb)
        }
    }

    /// 次の作品の文字の1行（公式と同じ位置・大きさ・太さで描く）
    struct Line: Decodable, Equatable {
        let r: Rect
        let t: String
        let fs: CGFloat
        let fw: Int
    }

    /// 読み終わりのページを表示中か
    let on: Bool
    var top: Rect?
    var btm: Rect?
    var topArea: Rect?
    var bg: String?
    var msg: Rect?
    var lines: [Line]?
    var topButton: Rect?
    var topButtonText: String?
    var topButtonOutlined: Bool?
    var topButtonSize: CGFloat?
    var follow: Rect?
    var followText: String?
    var followOn: Bool?
    var artist: Rect?
    var artistText: String?
    /// 作家名のリンク先（/#!/artists/<slug>）
    var artistHref: String?
    /// 今読んでいる作品のID
    var comic: Int?
    var tweet: Rect?
    var like: Rect?
    var likeOn: Bool?
    /// いいねボタンの文字（公式の表示のまま）
    var likeText: String?
    /// 最後に自分でフォロー・いいねを押した時刻（1970年からのミリ秒、押していなければ 0）
    var toggledAt: Double?
    var count: Rect?
    var countText: String?
    var header: Rect?
    var shuffle: Rect?
    var thumbs: [Thumb]?

    static let off = ReaderEndSnapshot(on: false)
}

/// 読み終わりの共通の見た目。主なボタン操作はNativeReaderEndViewが受け持つ。
struct ReaderEndSkin: View {
    let snapshot: ReaderEndSnapshot
    /// おすすめの表紙の☆・♡ボタン用
    @ObservedObject var library: LibraryStore
    var messageOffset: CGFloat = 0
    var messageHorizontalOffset: CGFloat = 0
    /// 作家名を押したとき（ビューアの上にアプリの作家ページを開く）
    var onArtist: () -> Void = {}

    /// おすすめの表紙を、全部読み込み終えてから一度に出すための目印（表紙を出してよい作品の並び）
    @State private var preparedIDsKey = ""

    /// 今のおすすめの作品の並び（表示の切り替えはこれだけで判断する）
    private var idsKey: String {
        (snapshot.thumbs ?? []).map { String($0.id ?? 0) }.joined(separator: ",")
    }

    /// 読み込みをやり直す目印（作品の並びと、公式の画像の住所が届いているか）
    private var thumbsKey: String {
        (snapshot.thumbs ?? []).map { "\($0.id ?? 0):\($0.img.contains("/contents/") ? 1 : 0)" }.joined(separator: ",")
    }

    /// 公式の色
    private static let pink = Color(red: 239 / 255, green: 66 / 255, blue: 116 / 255)
    private static let likeRed = Color(red: 229 / 255, green: 22 / 255, blue: 81 / 255)
    private static let gray = Color(red: 170 / 255, green: 170 / 255, blue: 170 / 255)
    private static let background = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Self.background

                // 次の作品の表紙（強くぼかして、上の部分にだけ敷く）
                if let area = snapshot.topArea, let bg = snapshot.bg, let url = URL(string: bg) {
                    ZStack {
                        CachedImage(url: url) { Color.clear }
                            .frame(width: area.w, height: area.h)
                            .blur(radius: 24, opaque: true)
                            .clipped()
                        LinearGradient(
                            colors: [.black.opacity(0.35), .black.opacity(0.55), Self.background],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .place(area)
                }

                // 次の作品の文字（作家名・題名・「スワイプで次の作品へ」など）。
                // 公式CSSと同じく、折り返さず枠内の1行に収め、長い場合は末尾を省略する。
                ReaderEndMessage(lines: snapshot.lines ?? [], offset: messageOffset, horizontalOffset: messageHorizontalOffset)

                // 今すぐ読む / 前のページに戻る / スワイプの案内
                if let rect = snapshot.topButton, let text = snapshot.topButtonText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: snapshot.topButtonSize ?? 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: rect.w, height: rect.h)
                        .overlay {
                            if snapshot.topButtonOutlined ?? true {
                                Capsule().strokeBorder(Color.white, lineWidth: 2)
                            }
                        }
                        .place(rect)
                        .offset(x: messageHorizontalOffset, y: messageOffset)
                }

                // フォロー / ポスト / いいね
                if let rect = snapshot.follow {
                    pill(
                        snapshot.followText?.isEmpty == false ? snapshot.followText! : "フォロー",
                        color: Self.pink,
                        filled: snapshot.followOn ?? false,
                        animated: justToggled,
                        rect: rect
                    )
                }
                if let rect = snapshot.artist, let name = snapshot.artistText {
                    Text("\(name) ▸")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Self.pink)
                        .lineLimit(1)
                        .fixedSize()
                        .position(x: rect.rect.midX, y: rect.rect.midY + 2)
                }
                if let rect = snapshot.tweet {
                    pill("𝕏 ポスト", color: .white, filled: false, rect: rect)
                }
                if let rect = snapshot.like {
                    // 公式と同じく、♥のアイコンの後に公式の文言（押しても♥のアイコン自体は変わらない）
                    let text = snapshot.likeText?.isEmpty == false ? snapshot.likeText! : "いいね"
                    pill("♥ \(text)", color: Self.likeRed, filled: snapshot.likeOn ?? false, animated: justToggled, rect: rect)
                }
                if let rect = snapshot.count, let count = snapshot.countText {
                    Text(count)
                        .font(.system(size: 14))
                        .foregroundStyle(Self.gray)
                        .fixedSize()
                        .position(x: rect.rect.midX, y: rect.rect.midY)
                }

                // こちらもおすすめ（見出しと線、右にシャッフル）
                if let rect = snapshot.header {
                    let right = snapshot.shuffle.map { $0.x - 8 } ?? (rect.x + rect.w)
                    let width = max(0, right - rect.x)
                    HStack(spacing: 10) {
                        Text("こちらもおすすめ")
                            .font(.system(size: 14.4))
                            .foregroundStyle(Self.gray)
                            .fixedSize()
                        Rectangle()
                            .fill(Self.gray.opacity(0.5))
                            .frame(height: 1)
                    }
                    .frame(width: width, alignment: .leading)
                    .position(x: rect.x + width / 2, y: rect.rect.midY)
                }
                if let rect = snapshot.shuffle {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Self.pink)
                        .position(x: rect.rect.midX, y: rect.rect.midY)
                }
                // 作品ごとに部品を分ける（並びの位置で使い回すと、戻る操作でおすすめが入れ替わったときに
                // 前の作品の表紙が残ってしまう）
                ForEach(snapshot.keyedThumbs, id: \.key) { item in
                    let thumb = item.thumb
                    Group {
                        if preparedIDsKey == idsKey {
                            RecommendationThumb(thumb: thumb, library: library)
                        } else {
                            // 全部の表紙がそろうまでは、同じ色の仮の枠を並べておく（1枚ずつぽつぽつ出ないように）
                            Theme.bar
                        }
                    }
                    .frame(width: thumb.r.w, height: thumb.r.h)
                    .clipped()
                    .place(thumb.r)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            // 公式の上のバーと下の丸いバーの場所はくり抜く（公式のバーがそのまま見え、隠れない）
            .mask {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    if let top = snapshot.top { path.addRect(top.rect) }
                    if let btm = snapshot.btm {
                        path.addRoundedRect(in: btm.rect, cornerSize: CGSize(width: btm.h / 2, height: btm.h / 2))
                    }
                }
                .fill(style: FillStyle(eoFill: true))
            }
        }
        // 主なボタン・スワイプは親のネイティブ画面が受け取る。
        .allowsHitTesting(false)
        // おすすめの表紙を先にまとめて読み込み、全部そろってから一度に出す（遅いものがあっても2.5秒で出す）
        .task(id: thumbsKey) {
            let key = idsKey
            let urls = (snapshot.thumbs ?? []).compactMap { thumb -> URL? in
                guard thumb.img.contains("/contents/") else { return nil }
                return URL(string: thumb.img)
            }
            if !urls.isEmpty {
                // 全部読み終えるか、2.5秒たつか、どちらか早い方で出す
                await withTaskGroup(of: Bool.self) { group in
                    for url in urls {
                        group.addTask {
                            _ = await ImageCache.shared.image(for: url)
                            return false
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        return true
                    }
                    var loaded = 0
                    for await isTimeout in group {
                        if isTimeout { break }
                        loaded += 1
                        if loaded == urls.count { break }
                    }
                    group.cancelAll()
                }
            }
            guard !Task.isCancelled else { return }
            // 一度出した並びは、住所があとから届いても仮の枠に戻さない
            if preparedIDsKey != key {
                withAnimation(.easeOut(duration: 0.15)) { preparedIDsKey = key }
            }
        }
        // 表紙の☆・♡と作家名も、両方式で同じ操作を使う。
        .overlay(alignment: .topLeading) { thumbButtons }
        .overlay(alignment: .topLeading) { artistButton }
    }

    /// 作家名（押すとビューアの上にアプリの作家ページを開く。戻るとビューアに戻る）
    @ViewBuilder
    private var artistButton: some View {
        if let rect = snapshot.artist, !isUnderBars(rect.rect) {
            Button(action: onArtist) {
                Color.clear
                    .frame(width: max(rect.w + 40, 120), height: max(rect.h + 16, 36))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(snapshot.artistText ?? "作家")のページ")
            .position(x: rect.rect.midX, y: rect.rect.midY)
        }
    }

    /// おすすめの表紙の右上の☆（ブックマーク）・♡（いいね）。上下のバーにかかる表紙には付けない
    private var thumbButtons: some View {
        ZStack(alignment: .topLeading) {
            ForEach(snapshot.keyedThumbs, id: \.key) { item in
                let thumb = item.thumb
                if let id = thumb.id, id > 0, !isUnderBars(thumb.r.rect) {
                    let bookmarked = library.bookmarkedIDs.contains(id)
                    let liked = library.likedIDs.contains(id)
                    HStack(spacing: 0) {
                        Button {
                            Task { await library.toggleBookmark(id) }
                        } label: {
                            markIcon(bookmarked ? "star.fill" : "star", color: bookmarked ? Theme.star : .white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(bookmarked ? "ブックマークを外す" : "ブックマークする")
                        Button {
                            Task { await library.toggleLike(id) }
                        } label: {
                            markIcon(liked ? "heart.fill" : "heart", color: liked ? Self.pink : .white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(liked ? "いいねを取り消す" : "いいねする")
                    }
                    .fixedSize()
                    .position(x: thumb.r.x + thumb.r.w - 46, y: thumb.r.y + 24)
                }
            }
        }
    }

    private func markIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(.black.opacity(0.55), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// 上のバー・下の丸いバーにかかっているか（かかっている表紙のボタンは出さない）
    private func isUnderBars(_ rect: CGRect) -> Bool {
        let buttons = CGRect(x: rect.maxX - 92, y: rect.minY, width: 92, height: 48)
        if let top = snapshot.top, buttons.intersects(top.rect) { return true }
        if let btm = snapshot.btm, buttons.intersects(btm.rect) { return true }
        return false
    }

    fileprivate static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<350: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }

    /// 自分でフォロー・いいねを押した直後か。ページを開いたとき（戻るで出したときなど）に公式が
    /// 状態を読み込んで切り替わる分は、動きを付けずにそのまま出す
    private var justToggled: Bool {
        guard let at = snapshot.toggledAt, at > 0 else { return false }
        return Date().timeIntervalSince1970 * 1000 - at < 3000
    }

    /// 丸い枠のボタン（公式のボタンの位置に、少し大きめに描く）。
    /// 公式と同じく、文言はすぐ切り替え、塗りと文字色は0.2秒かけて変える
    private func pill(_ title: String, color: Color, filled: Bool, animated: Bool = false, rect: ReaderEndSnapshot.Rect) -> some View {
        let height = rect.h + 6
        return ReaderAnimatedPill(
            title: title,
            color: color,
            // 公式の影の広がり（2rem = 32px）を、描く大きさに合わせる
            maxSpread: 32 * height / max(rect.h, 1),
            filled: filled,
            animated: animated
        )
        .frame(width: rect.w + 4, height: height)
        .position(x: rect.rect.midX, y: rect.rect.midY)
    }
}

/// 前後作品の案内で同じ文字の描画・折り返し・指追従を使う。
struct ReaderEndMessage: View {
    let lines: [ReaderEndSnapshot.Line]
    let offset: CGFloat
    var horizontalOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line.t)
                .font(.system(size: line.fs, weight: ReaderEndSkin.weight(line.fw)))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .frame(width: max(line.r.w, 1), height: line.r.h)
                .position(x: line.r.rect.midX, y: line.r.rect.midY)
                .offset(x: horizontalOffset, y: offset)
        }
        }
    }
}

/// 次作品案内と作家ページで、塗りと文字色の演出を共用する。
struct ReaderAnimatedPill: View {
    let title: String
    let color: Color
    let maxSpread: CGFloat
    let filled: Bool
    let animated: Bool

    var body: some View {
        ReaderPillFill(title: title, color: color, maxSpread: maxSpread, progress: filled ? 1 : 0)
            // 公式と同じ動き：0.2秒、CSSの標準の速さの変化（ease）。
            .animation(animated ? .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2) : nil, value: filled)
    }
}

/// 丸い枠のボタンの中身。公式の `box-shadow: inset 0 0 0 2rem` の変化と同じく、
/// 塗りは透明から濃くなりながら枠から内側へ広がり、文字色は枠の色から白へ少しずつ変わる
struct ReaderPillFill: View, Animatable {
    static let borderWidth: CGFloat = 2
    let title: String
    let color: Color
    let maxSpread: CGFloat
    /// 0 = 塗りなし、1 = 塗りつぶし
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let p = CGFloat(min(max(progress, 0), 1))
            let half: CGFloat = proxy.size.height / 2 + 1
            let width: CGFloat = min(maxSpread * p, half)
            ZStack {
                if width > 0 {
                    Capsule().strokeBorder(color.opacity(p), lineWidth: width)
                }
                Capsule().strokeBorder(color, lineWidth: Self.borderWidth)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Self.mix(color, .white, Double(p)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// 2つの色の間の色（p = 0 で a、1 で b）
    private static func mix(_ a: Color, _ b: Color, _ p: Double) -> Color {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        UIColor(a).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(b).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(p)
        let red: CGFloat = r1 + (r2 - r1) * t
        let green: CGFloat = g1 + (g2 - g1) * t
        let blue: CGFloat = b1 + (b2 - b1) * t
        return Color(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

/// おすすめの表紙。公式のページの表紙の画像を基本にし、取れなかったとき（または公式側がまだ読み込み待ちのとき）は、
/// 作品の情報から取った表紙（アプリのほかの画面と同じ取り方）に切り替える
private struct RecommendationThumb: View {
    let thumb: ReaderEndSnapshot.Thumb
    @ObservedObject var library: LibraryStore

    /// 作品の情報から取った表紙（期限の切れていないものだけ）
    @State private var ownURL: URL?
    @State private var ownComic: ComicSummary?
    /// 公式のページの表紙の画像が取れなかった
    @State private var officialFailed = false

    init(thumb: ReaderEndSnapshot.Thumb, library: LibraryStore) {
        self.thumb = thumb
        self.library = library
        // 一度取ったことのある作品で、表紙の住所の期限が切れていなければ、それも予備として最初から持っておく
        _ownURL = State(initialValue: thumb.id.flatMap { library.cachedComic(id: $0) }?.coverURL)
        _ownComic = State(initialValue: thumb.id.flatMap { library.cachedComic(id: $0) })
    }

    /// 公式のページの表紙の画像（作品の画像を指しているときだけ）
    private var officialURL: URL? {
        guard thumb.img.contains("/contents/"), let url = URL(string: thumb.img) else { return nil }
        return url
    }

    /// 表示に使うと決めた表紙の住所。一度決めたら、画像が取れなかったとき以外は切り替えない
    /// （公式のページは描き直しの途中で一瞬住所が空になることがあり、そのたびに切り替えるとちらつくため）
    @State private var lockedURL: URL?

    /// 出すべき表紙の候補：公式の画像 → 取れなければ作品の情報から取った表紙
    private var candidateURL: URL? {
        if let officialURL, !officialFailed { return officialURL }
        return ownURL
    }

    var body: some View {
        CachedImage(url: lockedURL ?? candidateURL, onFailure: {
            // 公式の画像が取れなかったら、作品の情報から取った表紙に切り替える
            if (lockedURL ?? candidateURL) == officialURL {
                officialFailed = true
                lockedURL = ownURL
            }
        }) {
            ZStack {
                LinearGradient(colors: [Theme.placeholder, Theme.bar], startPoint: .top, endPoint: .bottom)
                Text(thumb.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(6)
            }
        }
        .overlay {
            if let ownComic {
                Color.clear.modifier(HomeMagazineArtwork(comic: ownComic, enabled: true, library: library, atBottom: true))
            }
        }
        .allowsHitTesting(false)
        // 最初に使える表紙が決まったら固定する
        .onAppear { if lockedURL == nil { lockedURL = candidateURL } }
        .onChange(of: candidateURL) { _, url in
            if lockedURL == nil { lockedURL = url }
        }
        .task(id: thumb.id) {
            // 予備の表紙を用意しておく（公式の画像が無い・取れないときに使う）
            guard ownComic == nil, let id = thumb.id, id > 0 else { return }
            let comic = await library.comic(id: id)
            guard !Task.isCancelled else { return }
            ownComic = comic
            if ownURL == nil { ownURL = comic?.coverURL }
            // 公式の画像が取れなかったあとで予備の表紙が届いたら、それに切り替える
            if officialFailed { lockedURL = ownURL }
        }
    }
}

private extension View {
    /// 公式の部品と同じ位置・大きさに置く
    func place(_ rect: ReaderEndSnapshot.Rect) -> some View {
        frame(width: rect.w, height: rect.h)
            .position(x: rect.rect.midX, y: rect.rect.midY)
    }
}
