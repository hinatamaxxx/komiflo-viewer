import SwiftUI
import UIKit

/// 公式サイトのメニューのページ（下のタブの「メニュー」）。アプリ設定もここから開く。公式と同じ項目・同じ順番。
/// アプリにある画面はアプリで、ストア・アカウント設定などは公式のページをそのまま開く
struct OfficialMenuView: View {
    enum Item: CaseIterable, Identifiable {
        case notifications, artists, magazines, bookmarks, history, store, missions, account, appSettings, logout
        var id: Self { self }

        var title: String {
            switch self {
            case .notifications: return "お知らせ"
            case .artists: return "作家ギャラリー"
            case .magazines: return "マガジンラック"
            case .bookmarks: return "ブックマーク"
            case .history: return "閲覧履歴"
            case .store: return "ストア"
            case .missions: return "ミッション"
            case .account: return "アカウント設定"
            case .appSettings: return "アプリ設定"
            case .logout: return "ログアウト"
            }
        }

        var systemImage: String {
            switch self {
            case .notifications: return "bell"
            case .artists: return "person.2"
            case .magazines: return "books.vertical"
            case .bookmarks: return "star"
            case .history: return "clock.arrow.circlepath"
            case .store: return "bag"
            case .missions: return "flag"
            case .account: return "gearshape"
            case .appSettings: return "slider.horizontal.3"
            case .logout: return "rectangle.portrait.and.arrow.right"
            }
        }

        /// 公式のページをそのまま開く項目（公式メニューと同じリンク先）
        var officialURL: URL? {
            switch self {
            case .store: return URL(string: "https://store.komiflo.com")
            case .missions: return URL(string: "https://komiflo.com/#!/missions")
            case .account: return URL(string: "https://auth.komiflo.com/settings?from=subscription&bs=/#!/")
            default: return nil
            }
        }
    }

    @Environment(\.openRoute) private var openRoute
    @Environment(\.openOfficialPage) private var openOfficialPage
    @Environment(\.logout) private var logout
    @State private var isConfirmingLogout = false
    @State private var showsLicenses = false

    /// メニューのページ（全画面）。ここから開いた画面は、戻るでこのメニューに戻れる
    var body: some View {
        List {
            ForEach(Item.allCases) { item in
                Button {
                    select(item)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        Text(item.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if item.officialURL != nil {
                            // 公式のページが開く項目
                            Image(systemName: "safari")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else if item != .logout {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("KomifloViewer") {
                Link(destination: URL(string: "https://github.com/hinatamaxxx/komiflo-viewer")!) {
                    Label("GitHubリポジトリ", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { showsLicenses = true } label: {
                    Label("ライセンス", systemImage: "doc.text")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("メニュー")
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        .navigationDestination(isPresented: $showsLicenses) { LicensesView() }
        .confirmationDialog("ログアウトしますか？", isPresented: $isConfirmingLogout, titleVisibility: .visible) {
            Button("ログアウト", role: .destructive) { logout() }
        }
    }

    private func select(_ item: Item) {
        switch item {
        case .notifications: openRoute(.notifications)
        case .artists: openRoute(.artistGallery)
        case .magazines: openRoute(.magazineRack)
        case .bookmarks: openRoute(.bookmarks)
        case .history: openRoute(.history)
        case .appSettings: openRoute(.appSettings)
        case .store, .missions, .account:
            if let url = item.officialURL { openOfficialPage(url) }
        case .logout:
            isConfirmingLogout = true
        }
    }
}
/// キーボードを自動で出す動き（アプリ設定で変えられる）
enum KeyboardFocus {
    static let onOpenSearchKey = "keyboard.focusOnOpenSearch"
    static let onReselectKey = "keyboard.focusOnReselect"

    static func isEnabled(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}

/// メニューの「アプリ設定」。アプリ独自の表示設定だけを置く
struct AppSettingsView: View {
    var body: some View {
        ReaderSettingsHost {
            AppSettingsList()
        } settings: { _ in
            ReaderSettingsSheet()
        }
    }
}

private struct AppSettingsList: View {
    @AppStorage(ShelfDirection.storageKey) private var shelfRightToLeft = true
    @AppStorage(ShelfDirection.snapStorageKey) private var shelfSnapsOneByOne = true
    @AppStorage(MagazineShelfLayout.twoColumnsKey) private var magazineCoversTwoColumns = false
    @AppStorage(MagazineLogoBackground.transparencyKey) private var magazineLogoTransparency = MagazineLogoBackground.defaultTransparency
    @AppStorage(TabBarStyle.styleKey) private var tabBarStyle = TabBarStyle.glass
    @AppStorage(TabBarStyle.iPadBottomKey) private var iPadTabsAtBottom = false
    @AppStorage(ControlsPosition.key) private var controlsAtBottom = false
    @Environment(\.openReaderSettings) private var openReaderSettings
    @AppStorage(KeyboardFocus.onOpenSearchKey) private var focusOnOpenSearch = false
    @AppStorage(KeyboardFocus.onReselectKey) private var focusOnReselect = false
    /// 端末内に保存している画像の大きさ（表示用）
    @State private var diskUsage: Int64?
    @State private var isConfirmingCacheDeletion = false
    @State private var isDeletingCache = false
    @State private var showsCacheDeletionComplete = false

    var body: some View {
        List {
            Section {
                Toggle("表紙を右から左に並べる", isOn: $shelfRightToLeft)
                Toggle("表紙の横スクロールを見えている分ずつ止める", isOn: $shelfSnapsOneByOne)
                Toggle("マガジンラックの表紙を2列で表示する", isOn: $magazineCoversTwoColumns)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("掲載誌ロゴの背景の透明度")
                        Spacer()
                        Text("\(Int((magazineLogoTransparency * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $magazineLogoTransparency, in: 0...1, step: 0.05)
                        .accessibilityLabel("掲載誌ロゴの背景の透明度")
                }
                Button("ロゴ背景を標準に戻す") {
                    magazineLogoTransparency = MagazineLogoBackground.defaultTransparency
                }
                .disabled(magazineLogoTransparency == MagazineLogoBackground.defaultTransparency)
            } header: {
                Text("表紙の棚")
            } footer: {
                Text("向きの設定はオフで左から右へ並べます。横スクロールの設定はオフで自由にスクロールします。標準はどちらもオンです。")
            }

            Section {
                Toggle("検索バーを下にする", isOn: $controlsAtBottom)
            } header: {
                Text("さがす・マガジン・ライブラリ")
            } footer: {
                Text("「さがす」の検索バーと、各画面の切り替え（雑誌一覧 / 新作 / 26.9 …、閲覧履歴 / ブックマーク / …）の位置です。下にすると、タブバーのすぐ上に出ます。")
            }

            Section {
                Toggle("タブバーのガラスをオンに", isOn: Binding(
                    get: { tabBarStyle == TabBarStyle.glass },
                    set: { tabBarStyle = $0 ? TabBarStyle.glass : TabBarStyle.dark }
                ))
                Toggle("iPadの画面切り替えタブを下に表示", isOn: $iPadTabsAtBottom)
                    .disabled(UIDevice.current.userInterfaceIdiom != .pad)
            } header: {
                Text("タブバー")
            }

            Section {
                Button {
                    openReaderSettings(ReaderSettingsRequest())
                } label: {
                    HStack {
                        Text("コミックビューア設定")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            } header: {
                Text("ビューア")
            }

            Section {
                Toggle("「さがす」を開いたらキーボードを出す", isOn: $focusOnOpenSearch)
                Toggle("「さがす」タブを2回タップしたらキーボードを出す", isOn: $focusOnReselect)
            } header: {
                Text("キーボード")
            } footer: {
                Text("「さがす」を表示中に、もう一度タブを押すとキーボードを出します。別の画面に進んでいるときは、これまでどおり最初の画面に戻ります。")
            }

            Section {
                CommentPostButtonSettingsControls()
            } header: {
                Text("実験的な表示・コメント投稿")
            } footer: {
                Text("一覧・作品情報・ビューアのコメント欄に共通です。丸い投稿ボタンを右側に表示し、オンにすると左側へ移します。")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("メモリに置く画像")
                    Picker("メモリに置く画像", selection: .constant(ImageCache.defaultMemoryMB)) {
                        Text("\(ImageCache.defaultMemoryMB) MB（標準）").tag(ImageCache.defaultMemoryMB)
                    }
                    .pickerStyle(.menu).labelsHidden().tint(.secondary)
                    .disabled(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("キャッシュする画像")
                    Picker("キャッシュする画像", selection: .constant(ImageCache.defaultDiskMB)) {
                        Text("\(ImageCache.defaultDiskMB) MB（標準）").tag(ImageCache.defaultDiskMB)
                    }
                    .pickerStyle(.menu).labelsHidden().tint(.secondary)
                    .disabled(true)
                }
                HStack {
                    Text("いま、キャッシュしている画像")
                    Spacer()
                    Text(diskUsage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "計算中…")
                        .foregroundStyle(.secondary)
                }
                Button("キャッシュした画像を消す", role: .destructive) {
                    isConfirmingCacheDeletion = true
                }
                .disabled(isDeletingCache)
            } header: {
                Text("画像のキャッシュ")
            } footer: {
                Text("表紙・バナーの画像だけを保存します（漫画のページは保存しません）。上限は標準値で固定しています。足りなくなったときはiOSが自動で古いものから外します。")
            }
            Section {
                SettingsResetControls(scope: .application)
            }
            Section {
                NavigationLink("ライセンス") { LicensesView() }
                    .foregroundStyle(.primary)
            }
        }
        .task { await updateUsage() }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("アプリ設定")
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        .alert("キャッシュした画像を消しますか？", isPresented: $isConfirmingCacheDeletion) {
            Button("キャンセル", role: .cancel) { }
            Button("消す", role: .destructive) {
                isDeletingCache = true
                Task {
                    await Task.detached(priority: .utility) { ImageCache.shared.clearAll() }.value
                    await updateUsage()
                    isDeletingCache = false
                    showsCacheDeletionComplete = true
                }
            }
        }
        .alert("キャッシュを削除しました", isPresented: $showsCacheDeletionComplete) {
            Button("OK", role: .cancel) { }
        }
    }

    /// 端末内に保存している画像の大きさを数える（ファイルを数えるので裏で）
    private func updateUsage() async {
        diskUsage = await Task.detached(priority: .utility) { ImageCache.shared.diskUsage() }.value
    }

}

extension View {
    /// タブの先頭とメニューの遷移先で共用する48ptの帯。遷移先では戻るボタンを付ける。
    func appHeader(_ title: String, showsLogo: Bool = false, showsBack: Bool = false,
                   titleFont: Font = .system(size: 17, weight: .bold)) -> some View {
        modifier(AppHeader(title: title, showsLogo: showsLogo, showsBack: showsBack, titleFont: titleFont))
    }
}

private struct AppHeader: ViewModifier {
    let title: String
    let showsLogo: Bool
    let showsBack: Bool
    let titleFont: Font
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                // ホームのピンクの「K」も、各画面の見出しも、帯の真ん中に置く
                HStack(spacing: 10) {
                    Spacer()
                    if showsLogo {
                        // 公式サイトのアイコン画像をその場で読み込む
                        CachedImage(url: URL(string: "https://komiflo.com/assets/img/favicon/favicon_64.png")) {
                            Color.clear
                        }
                        .frame(width: 28, height: 28)
                        .accessibilityLabel("Komiflo")
                    } else {
                        Text(title)
                            .font(titleFont)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, showsBack ? 52 : 16)
                .frame(height: 48)
                .overlay(alignment: .leading) {
                    if showsBack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("戻る")
                        .padding(.leading, 4)
                    }
                }
                .background(Theme.bar.ignoresSafeArea(edges: .top))
            }
    }
}
