import SwiftUI
import UIKit
import WebKit

/// アプリ全体（ホーム / マガジン / さがす / ライブラリ / メニュー のタブ。アプリ設定はメニューの中）
struct RootView: View {
    var startsLoggedOut = false
    var onLoggedOut: () -> Void = {}
    @State private var logoutError: String?
    @State private var isLoggingOut = false
    enum AppTab: Hashable {
        case home, rack, search, library, menu
    }

    private enum LoginState {
        case checking, loggedIn, loggedOut, unavailable
        /// ログイン中だが読み放題の期間が切れている（公式の購読の案内を出す）
        case subscriptionRequired
    }

    @StateObject private var library = LibraryStore(api: KomifloAPI())

    @State private var selectedTab: AppTab = .home
    @State private var homePath: [Route] = []
    @State private var rackPath: [Route] = []
    @State private var searchPath: [Route] = []
    /// 「さがす」タブを開くたびに増やし、検索欄にカーソルを入れる合図にする
    @State private var searchFocusToken = 0
    /// タブバーのデザイン（変えたらタブバーを作り直して、すぐ反映させる）
    @AppStorage(TabBarStyle.styleKey) private var tabBarStyle = TabBarStyle.glass
    @AppStorage(TabBarStyle.iPadBottomKey) private var iPadTabsAtBottom = false
    @State private var readerRequest: ReaderRequest?
    @State private var comicInfoRequest: ComicInfoRequest?
    @AppStorage(NativeReaderSettings.entranceAnimationKey) private var readerEntranceAnimation = true
    /// iOSのタブバーが占める高さ（画面の下端から。ダークのときに重ねるタブバーの高さに使う）
    @State private var tabBarHeight: CGFloat = 0
    @State private var libraryPath: [Route] = []
    @State private var menuPath: [Route] = []

    @State private var webPage: WebPage?
    @State private var loginState: LoginState = .checking
    @State private var loginError: String?

    var body: some View {
        ZStack {
            switch loginState {
            case .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background.ignoresSafeArea())
            case .loggedOut:
                // ログインが必要なら、最初からアプリ内のブラウザで公式のログインページを出す。
                // 戻る先が無いので閉じるボタンは出さない
                WebSheet(url: URL(string: "https://komiflo.com/#!/login")!, title: "ログイン", closable: false) {
                    guard loginState == .loggedOut else { return }
                    // 読み放題の期間が切れていないかも、起動時と同じ確認で決める
                    loginState = .checking
                    Task { await checkLogin() }
                }
            case .unavailable:
                connectionPrompt
            case .loggedIn:
                tabs
            case .subscriptionRequired:
                SubscriptionRequiredView(api: library.api)
            }
        }

        .sheet(item: $webPage, onDismiss: {
            Task { await checkLogin() }
        }) { page in
            WebSheet(url: page.url, requiresSubscription: true, onLoggedIn: page.returnsOnSubscription ? {
                // 決済が済んだらブラウザを閉じる。閉じたときの確認（checkLogin）で通常のタブへ戻る
                if webPage?.id == page.id { webPage = nil }
            } : nil)
        }
        // 漫画は全画面で開く（ビューアの「戻る」で閉じてアプリに戻る）
        .fullScreenCover(item: $readerRequest) { request in
            ReaderEntrance(enabled: readerEntranceAnimation, onClose: { readerRequest = nil }) {
                ReaderView(request: request, library: library, onHome: {
                    homePath = []
                    selectedTab = .home
                })
            }
            .presentationBackground(.clear)
        }
        .environment(\.openReader) { request in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { readerRequest = request }
        }
        // 公式メニューのストア・ミッション・アカウント設定は、公式のページをそのまま開く
        .environment(\.openOfficialPage) { url in
            webPage = WebPage(url: url, returnsOnSubscription: loginState == .subscriptionRequired)
        }
        .environment(\.logout) {
            guard !isLoggingOut else { return }
            isLoggingOut = true
            Task {
                defer { isLoggingOut = false }
                do {
                    try await library.api.logout()
                    endSession()
                } catch {
                    logoutError = "ログアウトできませんでした。通信状態を確認して、もう一度お試しください。"
                }
            }
        }
        .alert("ログアウト", isPresented: Binding(get: { logoutError != nil }, set: { if !$0 { logoutError = nil } })) {
            Button("OK", role: .cancel) { logoutError = nil }
        } message: { Text(logoutError ?? "") }
        .onReceive(library.api.$requiresLogin) { required in
            if required, loginState == .loggedIn || loginState == .subscriptionRequired { endSession() }
        }
        // 使っている途中で期間が切れたと分かったら、公式と同じく購読の案内へ切り替える
        .onReceive(library.api.$requiresSubscription) { required in
            if required, loginState == .loggedIn { loginState = .subscriptionRequired }
        }
        .task {
            if startsLoggedOut { loginState = .loggedOut }
            else { await checkLogin() }
        }
    }

    private var usesIPadBottomTabs: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && iPadTabsAtBottom
    }

    private func selectTab(_ tab: AppTab) {
        if tab == selectedTab { reselect(tab) }
        else { selectedTab = tab }
    }

    private var tabs: some View {
        // 選択中のタブをもう一度押したことも分かるように、選択の書き換えを受け取る
        TabView(selection: Binding(
            get: { selectedTab },
            set: selectTab
        )) {
            stack(path: $homePath) {
                HomeView(library: library) { url in webPage = WebPage(url: url) }
                    .appHeader("ホーム", showsLogo: true)
            }
            .tabItem { Label("ホーム", systemImage: "house.fill") }
            .tag(AppTab.home)

            // 雑誌一覧と、マガジンラック（公式の /magazines）の新作・月ごと
            stack(path: $rackPath) {
                MagazineTabView(library: library)
                    .appHeader("マガジンラック", titleFont: .headline)
            }
            .tabItem { Label("マガジン", systemImage: "books.vertical") }
            .tag(AppTab.rack)

            // さがす（タグ・作家）。開いたらすぐ検索欄に入力できる
            stack(path: $searchPath) {
                SearchView(library: library, focusToken: searchFocusToken)
                    .appHeader("さがす", titleFont: .headline)
            }
            .tabItem { Label("さがす", systemImage: "magnifyingglass") }
            .tag(AppTab.search)

            stack(path: $libraryPath) {
                LibraryView(library: library)
                    .appHeader("ライブラリ", titleFont: .headline)
            }
            .tabItem { Label("ライブラリ", systemImage: "star.square.on.square.fill") }
            .tag(AppTab.library)

            // 公式のメニュー（お知らせ・作家ギャラリー・ストア…）。アプリ設定もこの中から開く
            stack(path: $menuPath) {
                OfficialMenuView()
                    .appHeader("メニュー", titleFont: .headline)
            }
            .tabItem { Label("メニュー", systemImage: "line.3.horizontal") }
            .tag(AppTab.menu)
        }
        .modifier(GlassTabBar())
        // iPadの画面幅の判定は変えず、標準タブを隠した分を下の操作領域として確保する。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if usesIPadBottomTabs {
                IPadBottomTabBar(selection: selectedTab, usesGlass: tabBarStyle == TabBarStyle.glass,
                                 onSelect: selectTab)
            }
        }
        // キーボードが出ているときだけ、キーボードのすぐ上の右端に「キーボードを閉じる」ボタンを出す（帯は出さない）
        .overlay(alignment: .bottomTrailing) { KeyboardDismissButton() }
        // ダーク（塗りつぶし）のときは、iOSのタブバーを隠してアプリで描いたタブバーを出す。
        // iOS 26のタブバーは常にガラスで描かれ、背景色の指定が効かないため
        // ダーク（塗りつぶし）のときは、iOSのタブバーはそのまま置いておき、同じ場所・同じ高さに
        // アプリで描いた塗りつぶしのタブバーを重ねる。iOSのタブバーを隠すと各画面の下の余白が変わって
        // 切り替えの瞬間に表示がずれるので、余白は一切変えない（重ねる絵だけを切り替える）
        .overlay(alignment: .bottom) {
            if !usesIPadBottomTabs, tabBarStyle == TabBarStyle.dark, tabBarHeight > 0 {
                DarkTabBar(selection: selectedTab, height: tabBarHeight, onSelect: selectTab)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .search, KeyboardFocus.isEnabled(KeyboardFocus.onOpenSearchKey) { searchFocusToken += 1 }
        }
        .comicInfoPresentation(library: library, request: $comicInfoRequest, onReaderHome: {
            homePath = []
            selectedTab = .home
        }) { route in
            switch selectedTab {
            case .home: homePath.append(route)
            case .rack: rackPath.append(route)
            case .search: searchPath.append(route)
            case .library: libraryPath.append(route)
            case .menu: menuPath.append(route)
            }
        }
    }

    /// タブごとの画面遷移
    private func stack<Content: View>(
        path: Binding<[Route]>,
        @ViewBuilder root: () -> Content
    ) -> some View {
        NavigationStack(path: path) {
            root()
                // iOSのタブバーの高さを測る（各タブの最初の画面の下の余白＝タブバー＋ホームバー）。
                // キーボードの分は含めない
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { updateTabBarHeight(geometry.safeAreaInsets.bottom) }
                            .onChange(of: geometry.safeAreaInsets.bottom) { _, value in updateTabBarHeight(value) }
                    }
                    .ignoresSafeArea(.keyboard)
                }
                // タブバーの見た目（ダークのときはiOSのタブバーを隠す）は、重ねて開いた画面にも付けないと、
                // その画面ではiOSのタブバーが出たままになり、アプリのタブバーと重なって表示がずれる
                .modifier(TabBarBackground())
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route, library: library)
                        .modifier(TabBarBackground())
                }
        }
        .toolbar(usesIPadBottomTabs ? .hidden : .automatic, for: .tabBar)
        // タブバーの色の指定は、タブバー全体ではなく各タブの画面に付けないと効かない
        .modifier(TabBarBackground())
    }

    private func updateTabBarHeight(_ value: CGFloat) {
        guard value > 0, abs(value - tabBarHeight) > 0.5 else { return }
        tabBarHeight = value
    }


    /// 選択中のタブをもう一度押したとき：別の画面を開いていれば最初の画面に戻る（iOS標準と同じ）。
    /// 「さがす」の最初の画面なら、検索欄にカーソルを入れてキーボードを出す
    private func reselect(_ tab: AppTab) {
        let focuses = KeyboardFocus.isEnabled(KeyboardFocus.onReselectKey)
        if tab == .search, searchPath.isEmpty {
            if focuses { searchFocusToken += 1 }

        } else {
            popToRoot(tab)
        }
    }

    private func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: homePath = []
        case .rack: rackPath = []
        case .search: searchPath = []
        case .library: libraryPath = []
        case .menu: menuPath = []
        }
    }

    /// 読む画面から作品・作者に移るときは、今のタブに積む
    private func append(_ route: Route) {
        switch selectedTab {
        case .home: homePath.append(route)
        case .rack: rackPath.append(route)
        case .search: searchPath.append(route)
        case .library: libraryPath.append(route)
        case .menu: menuPath.append(route)
        }
    }

    private var connectionPrompt: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("接続できませんでした").font(.headline)
            Text(loginError ?? "通信状態を確認してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("接続を再試行") {
                Task { await checkLogin() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    private func checkLogin() async {
        loginError = nil
        do {
            let user = try await library.api.currentUser()
            loginState = user.canViewContents == false ? .subscriptionRequired : .loggedIn
        } catch KomifloAPIError.notLoggedIn {
            endSession()
        } catch is CancellationError {
        } catch {
            loginError = error.localizedDescription
            // 通信失敗だけで、確認済みのログインや表示中の画面を捨てない。
            if loginState != .loggedIn, loginState != .subscriptionRequired { loginState = .unavailable }
        }
    }

    private func endSession() {
        library.api.invalidate()
        APICache.clear()
        loginState = .loggedOut
        onLoggedOut()
    }
}

private extension View {
    /// メニューから重ねて開いた画面の見た目（タイトル・背景・ナビゲーションバー）
    func menuPage(_ title: String) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(false)
            .toolbar(.visible, for: .navigationBar)
            .darkNavigationBar()
            .tint(Theme.accent)
    }
}

/// タブバーの見た目（アプリ設定で選べる）
enum TabBarStyle {
    static let styleKey = "layout.tabBarStyle"
    static let iPadBottomKey = "layout.ipadTabsAtBottom"
    static let glass = "glass"
    static let dark = "dark"
}

/// ガラス：iOS標準（iOS 26ではLiquid Glass）。ダーク：これまでの塗りつぶし。
/// iOS 26では、下へスクロールしたときに小さくするかも選べる
/// 各タブの画面に付ける、タブバーの色（ダークのときだけ塗りつぶす）
private struct TabBarBackground: ViewModifier {
    @AppStorage(TabBarStyle.styleKey) private var style = TabBarStyle.glass

    func body(content: Content) -> some View {
        // ダークのときも、iOSのタブバーは隠さない（上にアプリのタブバーを重ねる）。
        // 隠すと画面の下の余白が変わり、切り替えたときに表示がずれる
        content
            .toolbarBackground(.automatic, for: .tabBar)
    }
}

/// タブバーはスクロールしても同じ大きさを保つ。
private struct GlassTabBar: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// ダーク（塗りつぶし）のタブバー。アプリで描くので、iOS 26でもガラスにならない
private struct DarkTabBar: View {
    let selection: RootView.AppTab
    /// 画面の下端からの高さ（iOSのタブバーと同じ）
    let height: CGFloat
    let onSelect: (RootView.AppTab) -> Void

    var body: some View {
        AppTabButtons(selection: selection, onSelect: onSelect)
            // ボタンは上に寄せ、下はホームバーの分まで塗りつぶす。
            .frame(height: height, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(Theme.bar)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { Divider().opacity(0.4) }
    }
}

/// iPadの下部タブ。画面の中身を隠さないよう、外側のsafeAreaInsetで場所を確保する。
private struct IPadBottomTabBar: View {
    let selection: RootView.AppTab
    let usesGlass: Bool
    let onSelect: (RootView.AppTab) -> Void

    var body: some View {
        AppTabButtons(selection: selection, onSelect: onSelect)
            .padding(.horizontal, 8)
            .frame(maxWidth: 560, minHeight: 56)
            .modifier(ReaderGlassStyle(enabled: usesGlass, originalFill: Theme.bar))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("ipad-bottom-tabs")
    }
}

/// タブのアイコン・名前・選択操作を、既存のダーク表示とiPadの下部表示で共用する。
private struct AppTabButtons: View {
    let selection: RootView.AppTab
    let onSelect: (RootView.AppTab) -> Void

    private let items: [(tab: RootView.AppTab, title: String, systemImage: String)] = [
        (.home, "ホーム", "house.fill"),
        (.rack, "マガジン", "books.vertical"),
        (.search, "さがす", "magnifyingglass"),
        (.library, "ライブラリ", "star.square.on.square.fill"),
        (.menu, "メニュー", "line.3.horizontal"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                Button {
                    onSelect(item.tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 24)
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selection == item.tab ? Theme.accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selection == item.tab ? .isSelected : [])
            }
        }
    }
}

/// 遷移先の画面
struct RouteView: View {
    let route: Route
    @ObservedObject var library: LibraryStore
    var headerImageURL: URL?


    var body: some View {
        switch route {
        case .comic(let id):
            ComicDetailView(comicID: id, library: library)
        case .homeShelf(let id, let kind, let name, let homeComics):
            HomeShelfPageView(attributeID: id, kind: kind, title: name, homeComics: homeComics, library: library)
        case .artist(let slug, let name):
            ArtistPageView(slug: slug, title: name, library: library)
        case .tag(let id, let name, let options, let homeComics):
            TagPageView(source: .id(id), title: name, library: library, headerImageURL: headerImageURL,
                        options: options, homeComics: homeComics)
        case .magazine(let magazine):
            MagazineIssuesView(magazine: magazine, library: library, headerImageURL: headerImageURL)
        case .issue(let id, let title):
            IssueView(issueID: id, title: title, library: library)
        case .collection(let id, let title):
            CollectionView(collectionID: id, title: title, library: library, headerImageURL: headerImageURL)
        case .banner(let destination, let imageURL):
            AnyView(RouteView(route: destination, library: library, headerImageURL: imageURL))
        case .tagSlug(let slug, let name, let options):
            TagPageView(source: .slug(slug), title: name, library: library, headerImageURL: headerImageURL, options: options)
        case .notifications:
            NotificationsView(library: library)
                .menuPage("お知らせ")
        case .officialMenu:
            OfficialMenuView()
        case .search:
            SearchView(library: library)
        case .follows:
            FollowList(library: library)
                .menuPage("フォローリスト")
        case .artistGallery:
            ArtistGalleryView(library: library)
                .menuPage("作家ギャラリー")
        case .magazineRack:
            MagazineTabView(library: library)
                .menuPage("マガジンラック")
        case .appSettings:
            AppSettingsView()
                .menuPage("アプリ設定")
        case .bookmarks:
            RemoteComicList(kind: .bookmarks, library: library, isActive: true, refreshLoaded: false)
                .menuPage("ブックマーク")

        case .history:
            RemoteComicList(kind: .history, library: library, isActive: true, refreshLoaded: false)
                .menuPage("閲覧履歴")
        case .deliveryCalendar(let slug):
            DeliveryCalendarView(initialSlug: slug, library: library, headerImageURL: headerImageURL)
        }
    }
}

struct WebPage: Identifiable {
    let id = UUID()
    let url: URL
    /// 期間切れの案内から開いたページ。決済などで読み放題が使えるようになったら閉じてアプリへ戻る
    var returnsOnSubscription = false
}

/// ログイン・アカウント設定など、アプリにしていない画面をブラウザ表示で開く
struct WebSheet: View {
    let url: URL
    var title: String = "Komiflo"
    var initialFocusSelector: String?
    /// ログインが必要なときに画面全体へ出す場合は、戻る先が無いので閉じるボタンを出さない
    var closable = true
    /// trueなら、ログインしただけでなく読み放題が使えるようになったときにonLoggedInを呼ぶ
    var requiresSubscription = false
    var onLoggedIn: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SimpleWebView(url: url, initialFocusSelector: initialFocusSelector, requiresSubscription: requiresSubscription,
                          onLoggedIn: onLoggedIn)
                .ignoresSafeArea(initialFocusSelector == nil ? .all : .container, edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .darkNavigationBar()
                .toolbar {
                    if closable {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("閉じる") { dismiss() }
                        }
                    }
                }
        }
    }
}

private struct SimpleWebView: UIViewControllerRepresentable {
    let url: URL
    let initialFocusSelector: String?
    let requiresSubscription: Bool
    let onLoggedIn: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> WebViewController {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if let initialFocusSelector, ReaderURLPolicy.isKomifloSite(url),
           let selectors = try? JSONSerialization.data(withJSONObject: [initialFocusSelector]),
           let selectorJSON = String(data: selectors, encoding: .utf8),
           let fragments = try? JSONSerialization.data(withJSONObject: [url.fragment ?? ""]),
           let fragmentsJSON = String(data: fragments, encoding: .utf8) {
            // 入力欄の準備だけを通知し、フォーカスはアプリから一度渡す。
            let script = """
            (() => {
                const selector = \(selectorJSON)[0];
                const path = \(fragmentsJSON)[0].replace(/^!/, '');
                let notifiedField = null;
                const observer = new MutationObserver(checkInput);
                function isTargetPage() {
                    const current = location.hash.startsWith('#!') ? location.hash.slice(2) : location.pathname;
                    return current.split('?')[0] === path;
                }
                function checkInput() {
                    if (!isTargetPage()) return;
                    const field = document.querySelector(selector);
                    if (field instanceof HTMLTextAreaElement && !field.disabled && !field.readOnly && field.getClientRects().length > 0) {
                        if (notifiedField !== field) {
                            notifiedField = field;
                            window.webkit.messageHandlers.commentInputReady.postMessage('ready');
                        }
                    }
                }
                document.addEventListener('focusin', function focused(event) {
                    if (isTargetPage() && event.target.matches(selector)) {
                        observer.disconnect();
                        document.removeEventListener('focusin', focused);
                    }
                });
                observer.observe(document.documentElement, {childList: true, subtree: true, attributes: true,
                    attributeFilter: ['disabled', 'readonly', 'hidden', 'class', 'style']});
                checkInput();
            })();
            """
            context.coordinator.focusHost = url.host
            context.coordinator.focusScript = """
            (() => {
                const path = \(fragmentsJSON)[0].replace(/^!/, '');
                const current = location.hash.startsWith('#!') ? location.hash.slice(2) : location.pathname;
                if (current.split('?')[0] !== path) return false;
                const field = document.querySelector(\(selectorJSON)[0]);
                if (!(field instanceof HTMLTextAreaElement) || field.disabled || field.readOnly || !field.getClientRects().length) return false;
                field.focus({preventScroll: true});
                return document.activeElement === field;
            })();
            """
            configuration.userContentController.add(context.coordinator, name: "commentInputReady")
            context.coordinator.positionInputScript = """
            (() => {
                const path = \(fragmentsJSON)[0].replace(/^!/, '');
                const current = location.hash.startsWith('#!') ? location.hash.slice(2) : location.pathname;
                if (current.split('?')[0] !== path) return false;
                const field = document.querySelector(\(selectorJSON)[0]);
                if (!(field instanceof HTMLTextAreaElement) || document.activeElement !== field) return false;
                const viewport = window.visualViewport;
                const top = (viewport ? viewport.offsetTop : 0) + Math.min(64, (viewport ? viewport.height : innerHeight) * 0.2);
                window.scrollBy({top: field.getBoundingClientRect().top - top, left: 0, behavior: 'instant'});
                return true;
            })();
            """
            configuration.userContentController.addUserScript(WKUserScript(source: script,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if let onLoggedIn {
            context.coordinator.observeLogin(webView, requiresSubscription: requiresSubscription, onLoggedIn: onLoggedIn)
        }
        let controller = WebViewController(webView: webView)
        controller.onVisibilityChanged = { [weak coordinator = context.coordinator, weak webView] visible in
            coordinator?.isVisible = visible
            if visible, let webView { coordinator?.focusIfReady(webView) }
        }
        if initialFocusSelector != nil {
            controller.onKeyboardVisibilityChanged = { [weak coordinator = context.coordinator, weak webView] visible in
                coordinator?.keyboardIsVisible = visible
                if visible, let webView { coordinator?.positionFocusedInput(webView) }
            }
        }
        let host = url.host?.lowercased() ?? ""
        if host == "komiflo.com" || host == "www.komiflo.com" {
            // komiflo.com のページはもともと暗い背景なので、アプリの暗い画面になじませる
            webView.isOpaque = false
            webView.backgroundColor = Theme.uiBackground
            webView.underPageBackgroundColor = Theme.uiBackground
        } else {
            // ストア・ログインなどのページは背景色を指定せず白に任せている作りなので、
            // 普通のブラウザと同じ白い背景にする（透けるとアプリの暗い背景が見えて黒くなる）
            webView.isOpaque = true
            webView.backgroundColor = .white
            webView.underPageBackgroundColor = .white
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return controller
    }

    func updateUIViewController(_ controller: WebViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: WebViewController, coordinator: Coordinator) {
        coordinator.stopObservingLogin()
    }

    // 画面が表示し終わったことを、入力欄の準備とは別に受け取る。
    final class WebViewController: UIViewController {
        let webView: WKWebView
        var onVisibilityChanged: ((Bool) -> Void)?
        var onKeyboardVisibilityChanged: ((Bool) -> Void)?

        init(webView: WKWebView) {
            self.webView = webView
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() { view = webView }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if onKeyboardVisibilityChanged != nil {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow(_:)),
                    name: UIResponder.keyboardDidShowNotification, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide),
                    name: UIResponder.keyboardDidHideNotification, object: nil)
            }
            onVisibilityChanged?(true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            onVisibilityChanged?(false)
            onKeyboardVisibilityChanged?(false)
            NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardDidShowNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardDidHideNotification, object: nil)
            super.viewWillDisappear(animated)
        }

        @objc private func keyboardDidShow(_ notification: Notification) {
            guard view.window != nil else { return }
            if let screen = notification.object as? UIScreen, screen !== view.window?.screen { return }
            onKeyboardVisibilityChanged?(true)
        }

        @objc private func keyboardDidHide() { onKeyboardVisibilityChanged?(false) }

        deinit { NotificationCenter.default.removeObserver(self) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver {
        private var loginCompletion: LoginCompletion?
        private var loginTransport: NativeReaderService?
        private var loginCookieStore: WKHTTPCookieStore?
        private var loginURLObservation: NSKeyValueObservation?
        var focusScript: String?
        var positionInputScript: String?
        var focusHost: String?
        var isVisible = false
        var keyboardIsVisible = false {
            didSet { if !keyboardIsVisible { hasPositionedInput = false } }
        }
        private var hasPositionedInput = false
        private var inputIsReady = false
        private var hasFocused = false
        private var focusIsPending = false
        private var inputGeneration = 0

        func observeLogin(_ webView: WKWebView, requiresSubscription: Bool, onLoggedIn: @escaping () -> Void) {
            let transport = NativeReaderService()
            loginTransport = transport
            loginCompletion = LoginCompletion(check: {
                do {
                    let data = try await transport.apiData(url: URL(string: "https://api.komiflo.com/session/user")!,
                                                          method: "GET", withCredentials: true, body: nil)
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    guard let user = try decoder.decode(KFSessionResponse.self, from: data).loggedInUser else { return false }
                    // 決済の完了は、公式Webと同じく can_view_contents が true になったことで判断する
                    return !requiresSubscription || user.canViewContents == true
                } catch { return false }
            }, onCompleted: onLoggedIn)
            let store = webView.configuration.websiteDataStore.httpCookieStore
            loginCookieStore = store
            store.add(self)
            loginURLObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.loginCompletion?.changed() }
            }
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            loginCompletion?.changed()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loginCompletion?.changed()
        }

        func stopObservingLogin() {
            loginCookieStore?.remove(self)
            loginCookieStore = nil
            loginURLObservation?.invalidate()
            loginURLObservation = nil
            loginCompletion?.stop()
            loginCompletion = nil
            loginTransport?.close()
            loginTransport = nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "commentInputReady", message.frameInfo.isMainFrame,
                  let webView = message.webView else { return }
            inputIsReady = true
            inputGeneration += 1
            focusIfReady(webView)
        }

        func focusIfReady(_ webView: WKWebView) {
            guard inputIsReady, isVisible, !hasFocused, !focusIsPending, webView.window != nil,
                  let url = webView.url, ReaderURLPolicy.isKomifloSite(url),
                  url.host?.replacingOccurrences(of: "www.", with: "") == focusHost?.replacingOccurrences(of: "www.", with: ""),
                  let focusScript else { return }
            let generation = inputGeneration
            focusIsPending = true
            webView.becomeFirstResponder()
            // iOSがキーボードと入力欄の見える位置を調整する。値や投稿には触れない。
            webView.evaluateJavaScript(focusScript) { [weak self, weak webView] result, _ in
                guard let self else { return }
                self.focusIsPending = false
                self.hasFocused = result as? Bool == true
                if self.hasFocused, let webView { self.positionFocusedInput(webView) }
                // 評価中に入力部品が作り直された場合だけ、新しい部品へ渡す。
                if !self.hasFocused, self.inputGeneration != generation, let webView {
                    self.focusIfReady(webView)
                }
            }
        }

        func positionFocusedInput(_ webView: WKWebView) {
            guard isVisible, keyboardIsVisible, hasFocused, !hasPositionedInput,
                  let url = webView.url, ReaderURLPolicy.isKomifloSite(url),
                  let positionInputScript else { return }
            // キーボードが出た後の見える領域に、入力欄を一度だけ合わせる。
            hasPositionedInput = true
            webView.evaluateJavaScript(positionInputScript, completionHandler: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let isKomiflo = ReaderURLPolicy.isKomifloSite(url)
            if isKomiflo || navigationAction.targetFrame?.isMainFrame == false
                || ["about", "blob", "data"].contains(url.scheme ?? "") {
                decisionHandler(.allow)
            } else {
                // 決済ページなどはSafariで開く
                if ReaderURLPolicy.canOpenExternally(url) { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            }
        }
    }
}
