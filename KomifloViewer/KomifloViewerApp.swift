import SwiftUI
import UIKit

@main
struct KomifloViewerApp: App {
    @State private var accountGeneration = UUID()
    @State private var startsLoggedOut = false
    init() {
        SettingsDefaults.shared.register()
        // 作家ギャラリーの行（ア・カ・…）の選択は、アプリを起動し直したら最初の状態（すべて）に戻す
        UserDefaults.standard.removeObject(forKey: "artists.kana")
        // キーボードが出ているかの見張りを始める（スクロールでキーボードを閉じるときに使う）
        _ = KeyboardState.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(startsLoggedOut: startsLoggedOut, onLoggedOut: {
                startsLoggedOut = true
                accountGeneration = UUID()
            })
                .id(accountGeneration)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
