import SwiftUI

struct ReaderSettingsRequest: Identifiable {
    let id = UUID()
    var onDismiss: () -> Void = {}
}

/// ビューアの親から設定画面を提示する。
struct ReaderSettingsHost<Content: View, Settings: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var settings: (ReaderSettingsRequest) -> Settings
    @State private var request: ReaderSettingsRequest?
    @State private var didDismiss: () -> Void = {}

    var body: some View {
        content()
            .environment(\.openReaderSettings) { newRequest in
                guard request == nil else { return }
                didDismiss = newRequest.onDismiss
                request = newRequest
            }
            .fullScreenCover(item: $request, onDismiss: {
                let callback = didDismiss
                didDismiss = {}
                callback()
            }) { request in
                settings(request)
            }
    }
}

private struct OpenReaderSettingsKey: EnvironmentKey {
    static let defaultValue: (ReaderSettingsRequest) -> Void = { _ in }
}

extension EnvironmentValues {
    var openReaderSettings: (ReaderSettingsRequest) -> Void {
        get { self[OpenReaderSettingsKey.self] }
        set { self[OpenReaderSettingsKey.self] = newValue }
    }
}
