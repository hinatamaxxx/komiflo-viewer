import SwiftUI

/// アプリ設定とビュアー設定で共用する設定。
enum ReaderAppSetting {
    /// ビューアでiPhoneの時計など（ステータスバー）を出すか
    static let showsStatusBarKey = "reader.showsStatusBar"
}

/// ネイティブのコミックビューア設定。変更した値はアプリ内へ保存する。
struct ReaderSettingsSheet: View {
    @AppStorage(ReaderImageQuality.key) private var imageQuality = ReaderImageQuality.high.rawValue
    @AppStorage(NativeReaderSettings.autoplayKey) private var autoplaySeconds = 6.0
    @AppStorage(NativeReaderSettings.endPageKey) private var showsEndPage = true
    @AppStorage(ReaderTapMode.key) private var tapMode = ReaderTapMode.leftForward.rawValue
    @AppStorage(ReaderTapMode.animationKey) private var animatesTap = true
    @AppStorage(ReaderGlassStyle.key) private var glassButtons = true
    @AppStorage(NativeReaderSettings.hideBarsOnTurnKey) private var hideBarsOnTurn = true
    @AppStorage(NativeReaderSettings.showsBarsOnOpenKey) private var showsBarsOnOpen = false
    @AppStorage(NativeReaderSettings.magazineLogoKey) private var showsMagazineLogo = true
    @AppStorage(NativeReaderSettings.indexAnimationKey) private var indexAnimation = true
    @AppStorage(NativeReaderSettings.swipeUpIndexKey) private var swipeUpOpensIndex = false
    @AppStorage(NativeReaderSettings.entranceAnimationKey) private var entranceAnimation = true
    @AppStorage(NativeReaderSettings.autoplayStyleKey) private var autoplayStyle = "bar"
    @AppStorage(NativeReaderSettings.autoplayBelowImageKey) private var autoplayBelowImage = true
    @AppStorage(NativeReaderSettings.autoplayStopsOnNavigationKey) private var stopAutoplayOnNavigation = true
    @AppStorage(NativeReaderSettings.autoplayResumesAfterNavigationKey) private var resumeAutoplayAfterNavigation = true
    @AppStorage(NativeReaderSettings.autoplayContinuesOnLayoutChangeKey) private var continueAutoplayOnLayoutChange = true
    @AppStorage(NativeReaderSettings.pageProgressKey) private var showsPageProgress = true
    @AppStorage(NativeReaderSettings.verticalPageProgressKey) private var showsVerticalPageProgress = false
    @AppStorage(NativeReaderSettings.verticalNavigationHorizontalProgressKey) private var verticalNavigationHorizontalProgress = true
    @AppStorage(NativeReadingLayout.verticalSwipeKey) private var verticalSwipe = false
    @AppStorage(NativeReaderSettings.progressOnLeftKey) private var progressOnLeft = false
    @AppStorage(NativeReadingLayout.key) private var readingLayout = NativeReadingLayout.horizontal.rawValue
    @AppStorage(ReaderSpreadMode.key) private var spreadMode = ReaderSpreadMode.initial.rawValue
    @AppStorage(ReaderSpreadOrientation.key) private var spreadOrientation = ReaderSpreadOrientation.landscape.rawValue
    @AppStorage(ReaderSpreadOrientation.phoneKey) private var spreadOnPhone = false

    @Environment(\.dismiss) private var dismiss
    /// アプリの設定：ビューアでiPhoneの時計など（ステータスバー）を出すか
    @AppStorage(ReaderAppSetting.showsStatusBarKey) private var showsStatusBar = true
    /// アプリの設定：インデックスのスワイプで止まるか
    @AppStorage(ReaderMode.indexSnapsKey) private var indexSnaps = true

    var body: some View {
        NavigationStack {
            List {
                displaySection
                pageSection
                spreadSection
                menuSection
                commentsSection
                autoplaySection
                otherSection
                experimentalSection
                Section {
                    SettingsResetControls(scope: .reader)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("コミックビューア設定")
            .navigationBarTitleDisplayMode(.inline)
            .darkNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { finish() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .modifier(SettingsSwipeDismiss())
        .presentationBackground(.clear)
    }

    private var supportsGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private func finish() { dismiss() }

    /// 「オフにする」設定は、保存している有効／無効と逆向きにする。
    private func inverted(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { !binding.wrappedValue }, set: { binding.wrappedValue = !$0 })
    }

    private var displaySection: some View {
        Section {
            Picker("作品画質モード", selection: $imageQuality) {
                ForEach(ReaderImageQuality.allCases) { quality in
                    Text(quality.title).tag(quality.rawValue)
                }
            }
            Toggle(isOn: $showsStatusBar) {
                Text("時計などのステータスバーを表示")
                    .font(.system(size: 17))
            }
            .tint(Theme.accent)
            Toggle("ガラスのボタン", isOn: $glassButtons)
                .disabled(!supportsGlass)
            Toggle("ナビ表示中に漫画の左上へ掲載誌ロゴを表示", isOn: $showsMagazineLogo)
            SettingsGroup("ページ進捗バー表示") {
                Toggle("横読みのページ数と進捗を非表示", isOn: inverted($showsPageProgress))
                Toggle("縦スクロール表示中に常時進捗バーを表示", isOn: $showsVerticalPageProgress)
                Toggle("縦スクロール表示の進捗バーを縦のバーにする", isOn: inverted($verticalNavigationHorizontalProgress))
                Toggle("縦の進捗バーを左側に表示", isOn: $progressOnLeft)
                    .disabled(verticalNavigationHorizontalProgress)
            }
        } header: {
            Text("画面表示")
        }
    }

    private var pageSection: some View {
        Section {
            Toggle("画面右側タップでページ送り", isOn: Binding(
                get: { tapMode == ReaderTapMode.rightForward.rawValue },
                set: { tapMode = ($0 ? ReaderTapMode.rightForward : .leftForward).rawValue }
            ))
            Toggle("タップ送りアニメーションをオフにする", isOn: inverted($animatesTap))
            Toggle("ページめくりのスワイプ方向を縦にする", isOn: $verticalSwipe)
        } header: {
            Text("ページ操作")
        }
    }

    /// 見開きは公式Webのページ表示モードを参考にする。縦スクロールでは使えないのでグレーアウトする。
    private var spreadSection: some View {
        let available = readingLayout != NativeReadingLayout.verticalScroll.rawValue
        let enabled = available && spreadMode != ReaderSpreadMode.single.rawValue
        return Section {
            Picker("ページ表示モード", selection: $spreadMode) {
                ForEach(ReaderSpreadMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .disabled(!available)
            Picker("iPadで見開きにする画面", selection: $spreadOrientation) {
                ForEach(ReaderSpreadOrientation.allCases) { orientation in
                    Text(orientation.title).tag(orientation.rawValue)
                }
            }
            .disabled(!enabled)
            Toggle("iPhoneの横向きでも見開きにする", isOn: $spreadOnPhone)
                .disabled(!enabled)
        } header: {
            Text("見開き")
        } footer: {
            Text("公式Webと同じく右から左へ読み、作品に指定がなければ1ページ目は1ページで表示します。縦スクロール表示では使えません。")
        }
    }

    private var menuSection: some View {
        Section {
            Toggle("漫画を開いた直後にナビバーを表示", isOn: $showsBarsOnOpen)
            Toggle("ページをめくってもナビを表示", isOn: inverted($hideBarsOnTurn))
            Toggle("上スワイプでインデックスを表示（横読みのみ）", isOn: $swipeUpOpensIndex)
            Toggle("インデックスを開閉するときのアニメーションをオフにする", isOn: inverted($indexAnimation))
            Toggle("インデックスのスワイプを1つずつ止める", isOn: $indexSnaps)
        } header: {
            Text("メニュー操作")
        }
    }

    private var commentsSection: some View {
        Section {
            CommentPostButtonSettingsControls()
        } header: {
            Text("コメント")
        }
    }

    private var autoplaySection: some View {
        Section {
            Picker("自動再生の進捗表示", selection: $autoplayStyle) {
                Text("バー（公式を参考）").tag("bar")
                Text("円形の再生アイコン").tag("ring")
            }
            Toggle("自動再生の表示を漫画画像の下に配置", isOn: $autoplayBelowImage)
            Toggle("ナビメニューを表示したら自動再生を止める", isOn: $stopAutoplayOnNavigation)
            Toggle("画面タップで漫画に戻ったら自動再生を再開", isOn: $resumeAutoplayAfterNavigation)
                .disabled(!stopAutoplayOnNavigation)
            Toggle("縦読み・横読みの変更時に自動再生を継続", isOn: $continueAutoplayOnLayoutChange)
            HStack {
                Text("自動再生速度")
                Spacer()
                Text("\(Int(NativeReaderSettings.autoplayDuration(autoplaySeconds)))秒").foregroundStyle(Theme.accent)
            }
            Slider(value: Binding(get: { NativeReaderSettings.autoplayDuration(autoplaySeconds) },
                                  set: { autoplaySeconds = $0 }), in: 4...30, step: 1)
        } header: {
            Text("自動再生")
        }
    }

    private var otherSection: some View {
        Section {
            Toggle("読み終わりの次の作品ページを非表示", isOn: inverted($showsEndPage))
        } header: {
            Text("その他")
        }
    }

    private var experimentalSection: some View {
        Section {
            Toggle("ビュアーを画面中央から開閉する演出をオフにする", isOn: inverted($entranceAnimation))
        } header: {
            Text("実験的機能")
        }
    }

}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Group {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content().listRowInsets(EdgeInsets(top: 8, leading: 32, bottom: 8, trailing: 20))
        }
    }
}
