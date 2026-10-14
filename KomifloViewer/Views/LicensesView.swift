import SwiftUI

/// アプリ本体と、移植元の第三者のコードの利用条件を全文表示する。
struct LicensesView: View {
    @State private var notices = ""

    var body: some View {
        ScrollView {
            Text(notices)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("ライセンス")
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        .task {
            notices = await Task.detached(priority: .utility) {
                ["AppLicense", "ThirdPartyNotices"].compactMap { name in
                    guard let url = AppResources.bundle.url(forResource: name, withExtension: "txt") else { return nil }
                    return try? String(contentsOf: url, encoding: .utf8)
                }.joined(separator: "\n\n────────────────\n\n")
            }.value
        }
    }
}
