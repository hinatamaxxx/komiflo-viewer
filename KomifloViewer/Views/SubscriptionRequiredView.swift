import SwiftUI

/// 読み放題の期間が切れているときの画面。公式Webのスマホ表示（ログイン中で can_view_contents が false のときの購読の案内）と同じ構成：
/// 雑誌の表紙を斜めに並べた背景・見出し・こみみ・下に固定した「決済方法を選択する」。決済は公式のページで行う
struct SubscriptionRequiredView: View {
    let api: KomifloAPI
    @Environment(\.openOfficialPage) private var openOfficialPage
    @Environment(\.logout) private var logout
    @State private var covers: [URL] = []
    /// 以前に契約していたか。確かめ終わるまで下の帯は出さない（公式も読み込み中は出さない）
    @State private var hadSubscription: Bool?
    @State private var isConfirmingLogout = false

    /// 公式の文字色（rgb 221）
    private static let text = Color(white: 221 / 255)
    /// 公式の lander 画像の縦横比（376×531）
    private static let coverAspect: CGFloat = 531 / 376

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 6.4) {
                        Text("いつでも、どこでも")
                        Text("Komifloで読み放題")
                    }
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(Theme.sectionTitle)
                    .padding(.top, 44)
                    Text("エロマンガ読み放題サービス\n快楽天・BAVELなど多数の雑誌を配信！")
                        .font(.system(size: 16))
                        .lineSpacing(8)
                        .foregroundStyle(Self.text)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                    // 公式のこみみ（komimi）。画面の高さの38%
                    CachedImage(url: URL(string: "https://komiflo.com/assets/img/mascot/chanco/komiflo_about@2x.png"),
                                fitsHeight: true) { Color.clear }
                        .frame(height: geometry.size.height * 0.38)
                        .padding(.top, geometry.size.height * 0.02)
                        .accessibilityHidden(true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .padding(.horizontal, 23)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { coverBackground(size: geometry.size) }
        }
        .background(Theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let hadSubscription { paymentBar(showsResumeText: hadSubscription) }
        }
        // 確認には「戻る」も必ず出す。iOS 26のconfirmationDialogはボタンから出る形になり、
        // cancelのボタンを表示しないため、両方を常に並べるalertにする
        .alert("ログアウトしますか？", isPresented: $isConfirmingLogout) {
            Button("戻る", role: .cancel) { }
            Button("ログアウト", role: .destructive) { logout() }
        }
        .task {
            async let history = api.hadSubscription()
            async let rack = api.magazineRack()
            covers = (try? await rack)?.compactMap(\.coverURL) ?? []
            hadSubscription = (try? await history) ?? false
        }
    }

    /// 公式と同じ48ptの帯。真ん中にロゴ、右に公式メニュー（ストア・アカウント設定・サポート・ログアウト）
    private var header: some View {
        CachedImage(url: URL(string: "https://komiflo.com/assets/img/favicon/favicon_64.png")) { Color.clear }
            .frame(width: 28, height: 28)
            .accessibilityLabel("Komiflo")
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .overlay(alignment: .trailing) {
                Menu {
                    Button { open("https://store.komiflo.com") } label: { Label("ストア", systemImage: "bag") }
                    Button { open("https://auth.komiflo.com/settings?from=subscription&bs=/#!/") } label: {
                        Label("アカウント設定", systemImage: "gearshape")
                    }
                    Button { open("https://komiflo.com/#!/support") } label: {
                        Label("サポート", systemImage: "questionmark.circle")
                    }
                    Button(role: .destructive) { isConfirmingLogout = true } label: {
                        Label("ログアウト", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("メニュー")
                .padding(.trailing, 4)
            }
            .background(Theme.bar.ignoresSafeArea(edges: .top))
    }

    /// 下に固定した帯。以前に契約していた場合だけ、再開の文言を添える（公式と同じ条件）
    private func paymentBar(showsResumeText: Bool) -> some View {
        VStack(spacing: 6.4) {
            if showsResumeText {
                Text("Komifloを再開するには、決済を行う必要があります。")
                    .font(.system(size: 12.8))
                    .foregroundStyle(Self.text)
                    .multilineTextAlignment(.center)
            }
            Button { open("https://komiflo.com/#!/payment_select") } label: {
                Text("決済方法を選択する")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8.8)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .padding(.vertical, 19.2)
        .frame(maxWidth: .infinity)
        .background(Theme.bar.opacity(0.9).ignoresSafeArea(edges: .bottom))
        .shadow(color: .black.opacity(0.15), radius: 7, y: -2)
    }

    /// 公式の背景：雑誌の表紙を3列に分けて斜めに並べ、薄くして周りを背景色へなじませる
    private func coverBackground(size: CGSize) -> some View {
        let gap: CGFloat = 11.2
        let width = max(0, (size.width - gap * 2) / 3)
        let height = width * Self.coverAspect
        let columnHeight = (height + 6.4) * 6
        return HStack(alignment: .top, spacing: gap) {
            ForEach(0..<3, id: \.self) { column in
                VStack(spacing: 6.4) {
                    ForEach(Array(columnCovers(column).enumerated()), id: \.offset) { _, url in
                        CachedImage(url: url) { Color.clear }
                            .frame(width: width, height: height)
                            .clipped()
                    }
                }
                // 真ん中の列は表紙半分だけ上へずらす
                .offset(y: column == 1 ? -height / 2 : 0)
                .offset(x: -width * 0.05, y: -columnHeight * 0.1)
                .rotationEffect(.degrees(10))
                .opacity(0.15)
            }
        }
        .scaleEffect(1.25, anchor: .top)
        .offset(x: -size.width * 0.04)
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .overlay {
            ZStack {
                LinearGradient(stops: [.init(color: Theme.background, location: 0),
                                       .init(color: Theme.background.opacity(0), location: 0.2),
                                       .init(color: Theme.background.opacity(0), location: 0.8),
                                       .init(color: Theme.background, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                RadialGradient(stops: [.init(color: Theme.background.opacity(0), location: 0.6),
                                       .init(color: Theme.background, location: 1)],
                               center: .center, startRadius: 0,
                               endRadius: hypot(size.width, size.height) / 2)
                LinearGradient(stops: [.init(color: Theme.background, location: 0),
                                       .init(color: Theme.background.opacity(0), location: 0.2)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 公式と同じく、表紙を3つおきに列へ分け、6枚に満たなければ繰り返す
    private func columnCovers(_ column: Int) -> [URL] {
        let urls = covers.enumerated().filter { $0.offset % 3 == column }.map(\.element)
        guard !urls.isEmpty else { return [] }
        var repeated = urls
        while repeated.count < 6 { repeated += urls }
        return Array(repeated.prefix(6))
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { openOfficialPage(url) }
    }
}
