import SwiftUI

/// 作品情報は標準シート、縮むヘッダーを持つ一覧は全画面で下から開く。
struct ComicInfoRequest: Identifiable {
    let route: Route
    let id = UUID()

    init(comicID: Int) { route = .comic(id: comicID) }
    init(route: Route) { self.route = route }
}

private struct ComicInfoPresentation: ViewModifier {
    @ObservedObject var library: LibraryStore
    @Binding var request: ComicInfoRequest?
    let onReaderHome: () -> Void
    let onRoute: (Route) -> Void
    @State private var artistRequest: ComicInfoRequest?

    func body(content: Content) -> some View {
        content
            .environment(\.openRoute) { route in
                if route.opensFullScreen {
                    artistRequest = ComicInfoRequest(route: route)
                } else if case .comic = route {
                    request = ComicInfoRequest(route: route)
                } else {
                    onRoute(route)
                }
            }
            .fullScreenCover(item: $artistRequest) { item in
                ComicInfoSheet(route: item.route, library: library, onReaderHome: {
                    artistRequest = nil
                    onReaderHome()
                })
                .presentationBackground(.clear)
            }
            .sheet(item: $request) { item in
                ComicInfoSheet(route: item.route, library: library, onReaderHome: {
                    request = nil
                    onReaderHome()
                })
                    .presentationBackground(.clear)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationContentInteraction(.resizes)
                    .interactiveDismissDisabled(false)
            }
    }
}

private struct ComicInfoSheet: View {
    let route: Route
    @ObservedObject var library: LibraryStore
    let onReaderHome: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NativeReaderSettings.entranceAnimationKey) private var readerEntranceAnimation = true
    @State private var path: [Route] = []
    @State private var request: ComicInfoRequest?
    @State private var readerRequest: ReaderRequest?

    private var closePlacement: ToolbarItemPlacement {
        switch route {
        case .artist, .tag, .tagSlug: return .topBarLeading
        default: return .topBarTrailing
        }
    }

    /// 全画面で開いた画面は、閉じるボタンの代わりに各画面の戻るボタンと下への引っ張りで閉じる
    private var isImageHeader: Bool { route.opensFullScreen }

    var body: some View {
        NavigationStack(path: $path) {
            RouteView(route: route, library: library)
                .toolbar {
                    if !isImageHeader {
                        ToolbarItem(placement: closePlacement) {
                            Button("閉じる") { dismiss() }
                        }
                    }
                }
                .navigationDestination(for: Route.self) { RouteView(route: $0, library: library) }
        }
        .comicInfoPresentation(library: library, request: $request, onReaderHome: onReaderHome) { path.append($0) }
        .environment(\.openReader) { next in
            // 元のシートと一覧の位置を残したまま、その上にビューアを開く。
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { readerRequest = next }
        }
        .fullScreenCover(item: $readerRequest) { next in
            ReaderEntrance(enabled: readerEntranceAnimation, onClose: { readerRequest = nil }) {
                ReaderView(request: next, library: library, onHome: onReaderHome)
            }
            .presentationBackground(.clear)
        }
        .modifier(ArtistSheetDismiss(enabled: isImageHeader, atRoot: path.isEmpty))
        .statusBarHidden(false)
        .persistentSystemOverlays(.automatic)
    }
}

extension View {
    func comicInfoPresentation(library: LibraryStore, request: Binding<ComicInfoRequest?>,
                               onReaderHome: @escaping () -> Void = {},
                               onRoute: @escaping (Route) -> Void) -> some View {
        modifier(ComicInfoPresentation(library: library, request: request,
                                       onReaderHome: onReaderHome, onRoute: onRoute))
    }
}

private struct ArtistSheetDismiss: ViewModifier {
    let enabled: Bool
    let atRoot: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.modifier(ArtistSwipeDismiss(enabled: atRoot))
        } else {
            content.background(.regularMaterial)
        }
    }
}
