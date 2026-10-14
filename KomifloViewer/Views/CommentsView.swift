import SwiftUI

enum CommentPostButtonSettings {
    static let onLeftKey = "comments.postButton.onLeft"
}

/// アプリ設定とビューアの実験設定で、同じ投稿ボタンを調整する。
struct CommentPostButtonSettingsControls: View {
    @AppStorage(CommentPostButtonSettings.onLeftKey) private var onLeft = false

    var body: some View {
        Toggle("投稿ボタンを左にする", isOn: $onLeft)
    }
}

/// 吹き出しから、作品ページを挟まずコメントを開く。
struct CommentsButton<Label: View>: View {
    let contentID: Int
    let title: String
    let library: LibraryStore
    var returnsToDetails = false
    @ViewBuilder var label: () -> Label

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { label() }
            .commentsPanel(isPresented: $isPresented) {
                CommentsSheet(contentID: contentID, library: library, title: title, showsDetails: true,
                              onDetails: returnsToDetails ? { isPresented = false } : nil)
            }
    }
}

/// コメント1件
struct CommentBubble: View {
    let comment: KFComment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
                Text(comment.author?.isEmpty == false ? comment.author! : "匿名")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let date = comment.createdDate {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(comment.body ?? "")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bar, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CommentPanelDrag {
    var changed: ((DragGesture.Value) -> Void)?
    var ended: ((DragGesture.Value) -> Void)?
}

private struct CommentPanelDragKey: EnvironmentKey {
    static let defaultValue = CommentPanelDrag()
}

private extension EnvironmentValues {
    var commentPanelDrag: CommentPanelDrag {
        get { self[CommentPanelDragKey.self] }
        set { self[CommentPanelDragKey.self] = newValue }
    }
}

/// 標準シートの外周余白を使わず、コメント欄を画面の下端につける。
private struct CommentsPanel<Content: View>: View {
    let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var dragTravel: CGFloat = 0

    var body: some View {
        GeometryReader { safeGeometry in
            GeometryReader { geometry in
                let maximumHeight = max(0, geometry.size.height - safeGeometry.safeAreaInsets.top)
                let expansion = maximumHeight * 0.25
                let collapse = isExpanded ? min(max(0, dragTravel), expansion) : 0
                let growth = isExpanded ? 0 : min(max(0, -dragTravel), expansion)
                let panelHeight = maximumHeight * (isExpanded ? 1 : 0.75) - collapse + growth
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.3)
                        .contentShape(Rectangle())
                        .onTapGesture { dismiss() }
                        .accessibilityHidden(true)
                    content
                        .safeAreaPadding(EdgeInsets(top: 0, leading: safeGeometry.safeAreaInsets.leading,
                            bottom: safeGeometry.safeAreaInsets.bottom, trailing: safeGeometry.safeAreaInsets.trailing))
                        .frame(width: geometry.size.width, height: panelHeight)
                        .background(Theme.background)
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(.white.opacity(0.3))
                                .frame(width: 36, height: 5)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                        .offset(y: max(0, dragTravel - (isExpanded ? expansion : 0)))
                        .environment(\.commentPanelDrag, CommentPanelDrag(changed: { value in
                            dragTravel = value.translation.height
                        }, ended: { value in
                            finishDrag(value, maximumHeight: maximumHeight)
                        }))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .ignoresSafeArea(.container)
        }
        .modifier(FullScreenSwipeDismiss(enabled: true, scrollOnly: true, allowsLeadingEdge: false))
    }

    private func finishDrag(_ value: DragGesture.Value, maximumHeight: CGFloat) {
        let travel = value.predictedEndTranslation.height
        if (!isExpanded && travel > 120) || (isExpanded && travel > maximumHeight * 0.6) {
            dismiss()
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            if travel < -60 { isExpanded = true }
            else if travel > 60 { isExpanded = false }
            dragTravel = 0
        }
    }
}

extension View {
    func commentsPanel<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            CommentsPanel(content: content())
                .presentationBackground(.clear)
        }
    }
}

/// すべてのコメント（下へスクロールすると続きを読み込む）
struct CommentsSheet: View {
    let contentID: Int
    @ObservedObject var library: LibraryStore
    let title: String
    let showsDetails: Bool
    let onReload: ((KFCommentsResponse) -> Void)?
    let onDetails: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.commentPanelDrag) private var panelDrag
    @State private var comments: [KFComment] = []
    @State private var total: Int?
    @State private var page = 0
    @State private var totalPages: Int?
    @State private var isLoading = false
    @State private var error: String?
    @Environment(\.openRoute) private var openRoute
    @State private var comicInfoRequest: ComicInfoRequest?
    @State private var showsPostBrowser = false
    @State private var reloadCount = 0
    @State private var loadGeneration = UUID()
    @State private var needsReload = false
    @AppStorage(CommentPostButtonSettings.onLeftKey) private var postButtonOnLeft = false

    init(contentID: Int, library: LibraryStore, title: String = "", firstPage: KFCommentsResponse? = nil, showsDetails: Bool = false, onReload: ((KFCommentsResponse) -> Void)? = nil, onDetails: (() -> Void)? = nil) {
        self.contentID = contentID
        self.library = library
        self.title = title
        self.showsDetails = showsDetails
        self.onReload = onReload
        self.onDetails = onDetails
        _comments = State(initialValue: firstPage?.results ?? [])
        _total = State(initialValue: firstPage?.total)
        _page = State(initialValue: firstPage == nil ? 0 : 1)
        _totalPages = State(initialValue: firstPage.map { $0.totalPages ?? 1 })
    }

    private var hasMore: Bool { totalPages.map { page < $0 } ?? true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(comments) { comment in
                                CommentBubble(comment: comment)
                                    .onAppear {
                                        if comment.id == comments.last?.id { Task { await loadMore() } }
                                    }
                            }
                            if isLoading {
                                LoadingFooter()
                            } else if let error {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(error).font(.footnote).foregroundStyle(.secondary)
                                    Button("再読み込み") { Task { await loadMore(replacing: needsReload) } }
                                }
                            } else if comments.isEmpty, page > 0 {
                                Text("まだコメントはありません")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 88 + geometry.safeAreaInsets.bottom)
                    }
                    // 一覧だけ下端まで広げ、投稿ボタンは安全領域内に残す。
                    .frame(width: geometry.size.width, height: geometry.size.height + geometry.safeAreaInsets.bottom)
                    .clipped()
                    .frame(height: geometry.size.height, alignment: .top)
                    .task(id: reloadCount) {
                        if reloadCount > 0 { await loadMore(replacing: true) }
                        else if page == 0 { await loadMore() }
                    }
                    postButton
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .comicInfoPresentation(library: library, request: $comicInfoRequest) { openRoute($0) }
        .sheet(isPresented: $showsPostBrowser, onDismiss: { reloadCount += 1 }) {
            WebSheet(url: URL(string: "https://komiflo.com/#!/comics/\(contentID)")!, title: "コメント投稿",
                initialFocusSelector: ".grid.comments textarea")
                .presentationDetents([.large])
        }
    }

    private var postButton: some View {
        HStack {
            if !postButtonOnLeft { Spacer(minLength: 0) }
            Button { showsPostBrowser = true } label: {
                composeIcon
                    .frame(width: 56, height: 56)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("コメントを書く")
            if postButtonOnLeft { Spacer(minLength: 0) }
        }
    }

    private var composeIcon: some View {
        // 四角の24ptの枠を中央に固定し、右上のペンは配置の基準に含めない。
        Path { path in
            path.move(to: CGPoint(x: 24, y: 12))
            path.addLine(to: CGPoint(x: 24, y: 21))
            path.addQuadCurve(to: CGPoint(x: 21, y: 24), control: CGPoint(x: 24, y: 24))
            path.addLine(to: CGPoint(x: 3, y: 24))
            path.addQuadCurve(to: CGPoint(x: 0, y: 21), control: CGPoint(x: 0, y: 24))
            path.addLine(to: CGPoint(x: 0, y: 3))
            path.addQuadCurve(to: CGPoint(x: 3, y: 0), control: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 12, y: 0))
        }
        .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .frame(width: 24, height: 24)
        .overlay {
            Image(systemName: "pencil")
                .font(.system(size: 21, weight: .medium))
                .offset(x: 6, y: -6)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("コメント").font(.title3.weight(.bold))
                    if let total {
                        Text("\(total)件").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if showsDetails {
                        Button("作品情報") {
                            if let onDetails {
                                onDetails()
                            } else {
                                comicInfoRequest = ComicInfoRequest(comicID: contentID)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.leading, 4)
                    }
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Theme.bar, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("コメントを閉じる")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        // 動くパネル内の座標で測ると追従量が揺れるので、画面全体で測る。
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { panelDrag.changed?($0) }
            .onEnded { panelDrag.ended?($0) })
    }

    private func loadMore(replacing: Bool = false) async {
        if replacing {
            // ブラウザを閉じた後の更新に、以前の続きの応答を混ぜない。
            loadGeneration = UUID()
            needsReload = true
        } else {
            guard !isLoading, !needsReload, hasMore else { return }
        }
        let generation = loadGeneration
        let requestedPage = replacing ? 0 : page
        isLoading = true
        error = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            // Komifloのページは0始まり
            let response = try await library.api.comments(contentID: contentID, page: requestedPage)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            let known = replacing ? Set<Int>() : Set(comments.map(\.id))
            let received = (response.results ?? []).filter { !known.contains($0.id) }
            if replacing { comments = received } else { comments += received }
            total = response.total
            page = requestedPage + 1
            totalPages = response.totalPages ?? page
            if response.results?.isEmpty ?? true { totalPages = page }
            if replacing {
                needsReload = false
                onReload?(response)
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
