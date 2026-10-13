import SwiftUI
import UIKit

/// 漫画はネイティブ表示に統一し、設定画面はビューアの親から提示する。
struct ReaderView: View {
    let request: ReaderRequest
    @ObservedObject var library: LibraryStore
    var onHome: () -> Void = {}

    var body: some View {
        ReaderSettingsHost {
            NativeReaderScene(request: request, library: library, onHome: onHome)
        } settings: { _ in
            ReaderSettingsSheet()
        }
    }
}

struct NativeReaderScene: View {
    let request: ReaderRequest
    @ObservedObject var library: LibraryStore
    var onHome: () -> Void = {}
    @StateObject private var session: NativeReaderSession
    @Environment(\.closeReader) private var closeReader
    @Environment(\.openReaderSettings) private var openReaderSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var comicID: Int
    @State private var title: String
    @State private var page = 1
    @State private var swipeTargetPage: Int?
    @State private var pageSelectedFromProgress: Int?
    @State private var path: [Route] = []
    @State private var comicInfoRequest: ComicInfoRequest?
    @State private var showsComments = false
    @State private var showsBars = false
    // 色の通知はナビだけが受け、漫画側の配置処理を呼び直さない。
    @State private var headerAppearance = ReaderHeaderAppearance()
    @State private var imageGeometry = ReaderImageGeometry()
    @State private var progressFooterHeight: CGFloat = 0
    @StateObject private var indexMotion: ReaderIndexMotion
    // 追従の通知は読み終わり画面だけが受け、漫画の表示全体を更新しない。
    @State private var endSwipeMotion = ReaderEndSwipeMotion()
    @State private var startSwipeMotion = ReaderEndSwipeMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chapters: [ComicSummary] = []
    @State private var readingCollection: [ComicSummary]
    @State private var recommendations: [ComicSummary] = []
    @State private var issueTitle: String?
    @State private var autoplayTask: Task<Void, Never>?
    @State private var autoplayClock = ReaderAutoplayClock()
    @AppStorage(ReaderAppSetting.showsStatusBarKey) private var showsStatusBar = true
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
    @AppStorage(NativeReaderSettings.autoplayStyleKey) private var autoplayStyle = "bar"
    @AppStorage(NativeReaderSettings.autoplayBelowImageKey) private var autoplayBelowImage = true
    @AppStorage(NativeReaderSettings.autoplayStopsOnNavigationKey) private var stopAutoplayOnNavigation = true
    @AppStorage(NativeReaderSettings.autoplayResumesAfterNavigationKey) private var resumeAutoplayAfterNavigation = true
    @AppStorage(NativeReaderSettings.autoplayContinuesOnLayoutChangeKey) private var continueAutoplayOnLayoutChange = true
    @AppStorage(NativeReaderSettings.pageProgressKey) private var showsPageProgress = true
    @AppStorage(NativeReaderSettings.verticalPageProgressKey) private var showsVerticalPageProgress = false
    @AppStorage(NativeReaderSettings.verticalNavigationHorizontalProgressKey) private var verticalNavigationHorizontalProgress = true
    @AppStorage(NativeReadingLayout.key) private var readingLayout = NativeReadingLayout.horizontal.rawValue
    @AppStorage(NativeReadingLayout.verticalSwipeKey) private var verticalSwipe = false
    @AppStorage(NativeReaderSettings.progressOnLeftKey) private var progressOnLeft = false
    @AppStorage(NativeReaderSettings.previousHintPositionKey) private var previousHintPosition = 0.0
    @AppStorage(NativeReaderSettings.previousHintTravelKey) private var previousHintTravel = 48.0
    @AppStorage(ReaderSpreadMode.key) private var spreadMode = ReaderSpreadMode.initial.rawValue
    @AppStorage(ReaderSpreadOrientation.key) private var spreadOrientation = ReaderSpreadOrientation.landscape.rawValue
    @AppStorage(ReaderSpreadOrientation.phoneKey) private var spreadOnPhone = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // 見開きの判定だけに使う。大きさが変わったときだけ更新する。
    @State private var readerSize: CGSize = .zero

    init(request: ReaderRequest, library: LibraryStore, session: NativeReaderSession? = nil,
         indexMotion: ReaderIndexMotion? = nil, onHome: @escaping () -> Void = {}) {
        self.request = request
        self.library = library
        self.onHome = onHome
        _session = StateObject(wrappedValue: session ?? NativeReaderSession(onAuthenticationRequired: {
            library.api.requireLogin()
        }))
        _indexMotion = StateObject(wrappedValue: indexMotion ?? ReaderIndexMotion())
        _comicID = State(initialValue: request.comicID)
        _title = State(initialValue: request.title)
        _readingCollection = State(initialValue: request.collection)
        _showsBars = State(initialValue: UserDefaults.standard.bool(forKey: NativeReaderSettings.showsBarsOnOpenKey))
    }

    private var document: NativeReaderDocument? {
        guard session.document?.comicID == comicID else { return nil }
        if let expiry = session.document?.expiresAt, expiry <= Date() { return nil }
        return session.document
    }
    private var atEnd: Bool { document.map { page > $0.pages.count } ?? false }
    private var showsIndex: Bool { indexMotion.isPresented }
    private var barsVisible: Bool { showsBars || showsIndex || atEnd || session.error != nil }
    private var isAutoplaying: Bool { autoplayClock.isPlaying }
    private var hintPosition: CGFloat { CGFloat(NativeReaderSettings.previousHintPosition(previousHintPosition)) }
    private var hintTravel: CGFloat { CGFloat(NativeReaderSettings.previousHintTravel(previousHintTravel)) }
    private var hintExtension: CGFloat { hintTravel + max(0, hintPosition) + NativeReaderEndLayout.messageHeight }
    private var previous: ComicSummary? { neighboringChapter(offset: -1) }
    /// 見開きは縦スクロール以外で、端末と画面の向きの条件を満たすときだけ使う。
    private var spreadLayout: ReaderSpreadLayout? {
        guard let document else { return nil }
        let allowed = resolvedReadingLayout != .verticalScroll && ReaderSpreadOrientation.allows(
            ReaderSpreadOrientation(rawValue: spreadOrientation) ?? .landscape, size: readerSize,
            isPad: UIDevice.current.userInterfaceIdiom == .pad, regularWidth: horizontalSizeClass == .regular,
            phoneEnabled: spreadOnPhone)
        return ReaderSpreadLayout(count: document.pages.count,
                                  mode: allowed ? ReaderSpreadMode(rawValue: spreadMode) ?? .initial : .single,
                                  rightStart: document.rightStart, labeledStarts: document.spreadStarts)
    }
    private var next: ComicSummary? { neighboringChapter(offset: 1) }

    var body: some View {
        NavigationStack(path: $path) {
            viewer
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { RouteView(route: $0, library: library) }
        }
        .comicInfoPresentation(library: library, request: $comicInfoRequest, onReaderHome: returnHome) { path.append($0) }
        .environment(\.openReader) { requested in
            path = []
            readingCollection = requested.collection
            open(comicID: requested.comicID, title: requested.title)
        }
        .commentsPanel(isPresented: $showsComments) {
            CommentsSheet(contentID: comicID, library: library, title: title, showsDetails: true)
        }
        .statusBarHidden(path.isEmpty && !showsStatusBar && !showsBars && !showsIndex && !atEnd)
        .persistentSystemOverlays(path.isEmpty ? .hidden : .automatic)
        .defersSystemGestures(on: path.isEmpty ? .bottom : [])
        // アプリの切り替えでは作品を開き直さない。画像はビューアの寿命に合わせて保持する。
        .task(id: comicID) {
            let openedID = comicID
            let resumePage = page
            chapters = []
            recommendations = []
            issueTitle = nil
            session.setActive(scenePhase == .active)
            session.setImageQuality(ReaderImageQuality(rawValue: imageQuality) ?? .high)
            session.setContinuousScrolling(resolvedReadingLayout == .verticalScroll)
            await session.open(comicID: openedID, page: resumePage)
            guard !Task.isCancelled, comicID == openedID, let content = session.content else { return }
            if let document { page = min(resumePage, document.pages.count + (showsEndPage ? 1 : 0)) }
            title = content.title ?? title
            await loadRelated(content: content, openedID: openedID)
        }
        .onChange(of: page) { _, newPage in
            let selectedFromProgress = pageSelectedFromProgress == newPage
            pageSelectedFromProgress = nil
            if hideBarsOnTurn, document != nil, !selectedFromProgress { showsBars = false }
            session.select(page: newPage)
            if atEnd { stopAutoplay() }
        }
        .onChange(of: showsEndPage) { _, enabled in
            if !enabled, let document, page > document.pages.count { page = document.pages.count }
        }
        .onChange(of: showsBars) { _, visible in
            if visible { startSwipeMotion.reset() }
        }
        .onChange(of: autoplaySeconds) { _, _ in stopAutoplay() }
        .onChange(of: imageQuality) { _, value in
            session.setImageQuality(ReaderImageQuality(rawValue: value) ?? .high)
        }
        .onChange(of: resolvedReadingLayout) { _, layout in
            swipeTargetPage = nil
            if !continueAutoplayOnLayoutChange { stopAutoplay() }
            closeIndex(animated: false)
            session.setContinuousScrolling(layout == .verticalScroll)
        }
        .onDisappear {
            stopAutoplay()
            closeIndex(animated: false)
            // 一時的な表示・非表示を閉じた扱いにしない。戻る操作で破棄する。
        }
        .onChange(of: scenePhase) { _, phase in
            session.setActive(phase == .active)
            if phase != .active { stopAutoplay() }
            if phase == .active { session.resume(page: page) }
        }
    }

    private var viewer: some View {
        // 時計・ホームの余白は、漫画を全画面へ広げる前の領域で測る。
        GeometryReader { safeGeometry in
        GeometryReader { geometry in
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { if document == nil { toggleNavigation() } }
            if let document {
                Group {
                if resolvedReadingLayout == .verticalScroll {
                    NativeVerticalReader(document: document, includesEndPage: showsEndPage,
                        images: session.previews.merging(session.images) { _, full in full }, errors: session.errors,
                        previewPages: Set(session.previews.keys).subtracting(session.images.keys), page: $page,
                        navigationBlocked: showsIndex, tapMode: ReaderTapMode(rawValue: tapMode) ?? .leftForward,
                        onVisiblePages: { session.setVisiblePages($0) },
                        onTap: { toggleNavigation() }, onUserTurn: { stopAutoplay() },
                        onBeforeFirst: { pullBeforeFirst() },
                        onAfterLast: { if let next { open(comicID: next.id, title: next.title) } },
                        canMoveBefore: !barsVisible, canMoveAfter: next != nil,
                        endPage: AnyView(NativeReaderEndView(content: session.content, next: next, recommendations: recommendations,
                            library: library, onRead: { open(comicID: $0.id, title: $0.title) },
                            onPreviousPage: { page = document.pages.count }, onNavigate: { path.append($0) },
                            swipeMotion: endSwipeMotion)), endSwipeMotion: endSwipeMotion,
                        endContentInsets: UIEdgeInsets(top: safeGeometry.safeAreaInsets.top, left: safeGeometry.safeAreaInsets.leading,
                            bottom: safeGeometry.safeAreaInsets.bottom, right: safeGeometry.safeAreaInsets.trailing),
                        startPage: AnyView(NativePreviousWorkHint(previous: previous, swipeMotion: startSwipeMotion,
                            extensionHeight: hintExtension, positionOffset: hintPosition, maximumTravel: hintTravel)),
                        startSwipeMotion: startSwipeMotion, startHintExtension: hintExtension,
                        headerAppearance: headerAppearance, headerCenterY: safeGeometry.safeAreaInsets.top + (glassButtons ? 8 : 0) + 24,
                        imageGeometry: showsMagazineLogo || (autoplayClock.isVisible && autoplayBelowImage) ? imageGeometry : nil)
                } else {
                NativeImagePager(
                    comicID: comicID, pageCount: document.pages.count, includesEndPage: showsEndPage,
                    images: session.previews.merging(session.images) { _, full in full }, errors: session.errors, page: $page,
                    onTap: { toggleNavigation() }, onUserTurn: { stopAutoplay() },
                    onBeforeFirst: {
                        if let previous { openPreviousEnd(previous) }
                    },
                    onAfterLast: { if let next { open(comicID: next.id, title: next.title) } },
                    endPage: AnyView(NativeReaderEndView(content: session.content, next: next, recommendations: recommendations,
                                                       library: library, onRead: { open(comicID: $0.id, title: $0.title) },
                                                       onPreviousPage: { page = document.pages.count },
                                                       onNavigate: { path.append($0) }, swipeMotion: endSwipeMotion)),
                    previewPages: Set(session.previews.keys).subtracting(session.images.keys),
                    tapMode: ReaderTapMode(rawValue: tapMode) ?? .leftForward, animatesTap: animatesTap,
                    swipeUpOpensIndex: swipeUpOpensIndex, onOpenIndex: { openIndex() },
                    navigationBlocked: showsIndex,
                    onIndexDragChanged: { indexMotion.pullOpen(distance: $0) },
                    onIndexDragEnded: { distance, predicted, cancelled in
                        indexMotion.finishOpening(distance: distance, predicted: predicted, cancelled: cancelled,
                                                  animated: indexAnimation && !reduceMotion)
                    }, verticalPaging: resolvedReadingLayout == .verticalPages,
                    canMoveBefore: previous != nil, canMoveAfter: next != nil, endSwipeMotion: endSwipeMotion,
                    endContentInsets: UIEdgeInsets(top: safeGeometry.safeAreaInsets.top, left: safeGeometry.safeAreaInsets.leading,
                        bottom: safeGeometry.safeAreaInsets.bottom, right: safeGeometry.safeAreaInsets.trailing),
                    headerAppearance: headerAppearance,
                    headerCenterY: safeGeometry.safeAreaInsets.top + (glassButtons ? 8 : 0) + 24,
                    startPage: AnyView(NativePreviousWorkHint(previous: previous, swipeMotion: startSwipeMotion,
                        extensionHeight: hintExtension, positionOffset: hintPosition, maximumTravel: hintTravel)),
                    startSwipeMotion: startSwipeMotion,
                    startHintExtension: hintExtension, onBeforeFirstPull: { pullBeforeFirst() }, previousPullEnabled: !barsVisible,
                    imageGeometry: showsMagazineLogo || (autoplayClock.isVisible && autoplayBelowImage) ? imageGeometry : nil,
                    onSwipeTarget: { swipeTargetPage = $0 },
                    spreads: spreadLayout
                )
                .id(resolvedReadingLayout)
                }
                }
                .ignoresSafeArea(.container)

                if showsMagazineLogo, let content = session.content {
                    let top = safeGeometry.safeAreaInsets.top + (glassButtons ? 8 : 0) + 48 + 8
                    NativeReaderMagazineLogo(imageGeometry: imageGeometry,
                        identity: MagazineIdentity.display(comic: content.summary) ?? .unavailable,
                        available: CGRect(x: 0, y: top, width: geometry.size.width,
                            height: max(0, geometry.size.height - top - safeGeometry.safeAreaInsets.bottom)),
                        visible: showsBars && !atEnd && !showsIndex)
                }

                VStack {
                    Spacer()
                    if !atEnd, !showsIndex, autoplayClock.isVisible || showsHorizontalProgress {
                        VStack(spacing: 8) {
                        if showsHorizontalProgress {
                            NativePageProgress(page: page, count: document.pages.count,
                                               transitionPage: swipeTargetPage,
                                               usesGlass: glassButtons,
                                               navigationVisible: showsBars,
                                               onSelect: { selectFromProgress($0) })
                                .readerFooterHeight { height in
                                    if progressFooterHeight != height { progressFooterHeight = height }
                                }
                        }
                        if autoplayClock.isVisible, !autoplayBelowImage {
                        NativeAutoplayControls(clock: autoplayClock, style: autoplayStyle,
                            showsStopButton: showsBars, usesGlass: glassButtons, onStop: { stopAutoplay() })
                        }
                        }
                            .padding(.horizontal, 20)
                            .padding(.bottom, footerBottomPadding)
                            .transition(.opacity)
                    }
                }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: showsBars)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: showsIndex)
                if autoplayClock.isVisible, autoplayBelowImage, !atEnd, !showsIndex {
                    let bottomReserved = max(safeGeometry.safeAreaInsets.bottom + 12,
                        footerBottomPadding + (showsHorizontalProgress ? progressFooterHeight + 8 : 0))
                    let available = CGRect(x: 20, y: safeGeometry.safeAreaInsets.top,
                        width: max(0, geometry.size.width - 40),
                        height: max(0, geometry.size.height - safeGeometry.safeAreaInsets.top - bottomReserved))
                    NativeAutoplayBelowImage(imageGeometry: imageGeometry,
                        available: available,
                        clock: autoplayClock, style: autoplayStyle,
                        showsStopButton: showsBars, usesGlass: glassButtons, onStop: { stopAutoplay() })
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: showsBars)
                }
                Group {
                if showsVerticalProgress, !atEnd, !showsIndex {
                    HStack {
                        let left = resolvedReadingLayout == .verticalScroll && progressOnLeft
                        if !left { Spacer() }
                        NativeVerticalPageProgress(page: page, count: document.pages.count,
                            usesGlass: glassButtons, navigationVisible: showsBars,
                            onSelect: { selectFromProgress($0) })
                            .frame(width: 64, height: max(80, geometry.size.height - safeGeometry.safeAreaInsets.top - safeGeometry.safeAreaInsets.bottom - 220))
                            .padding(left ? .leading : .trailing, 8)
                        if left { Spacer() }
                    }
                    .zIndex(3)
                    .transition(.opacity)
                }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: barsVisible)
                if showsIndex {
                    NativeIndexView(issueTitle: issueTitle, chapters: chapters, currentComic: comicID,
                                    comicTitle: title, pageThumbs: document.pages.compactMap(\.previewURL), pageCount: document.pages.count,
                                    currentPage: min(page, document.pages.count),
                                    onSelectPage: { page = $0; if hideBarsOnTurn { showsBars = false }; closeIndex() },
                                    onSelectChapter: { id in
                                        let selected = chapters.first { $0.id == id }
                                        readingCollection = chapters
                                        open(comicID: id, title: selected?.title ?? "")
                                    }, onClose: { closeIndex() },
                                    loadedImages: session.images.merging(session.previews) { _, preview in preview },
                                    onDragChanged: { indexMotion.pullClosed(distance: $0) },
                                    onDragEnded: { distance, predicted in
                                        indexMotion.finishClosing(distance: distance, predicted: predicted,
                                                                  animated: indexAnimation && !reduceMotion)
                                    }, onDragCancelled: {
                                        indexMotion.finishClosing(distance: 0, predicted: 0,
                                                                  animated: indexAnimation && !reduceMotion)
                                    })
                        .offset(y: indexMotion.offset)
                        .transition(.identity)
                        .allowsHitTesting(indexMotion.acceptsTouches)
                        .onAppear { indexMotion.appeared(animated: indexAnimation && !reduceMotion) }
                        .zIndex(1)
                }

            } else if let error = session.error {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
            if resolvedReadingLayout != .horizontal {
                VStack(spacing: 0) {
                    Color.black.frame(height: safeGeometry.safeAreaInsets.top)
                        .opacity(showsStatusBar || barsVisible ? 1 : 0)
                        .animation(.linear(duration: 0.15), value: barsVisible)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            NativeReaderBars(
                visible: barsVisible,
                isBookmarked: library.bookmarkedIDs.contains(comicID), isLiked: library.likedIDs.contains(comicID),
                isAutoplaying: isAutoplaying, isIndexOpen: showsIndex, usesGlass: glassButtons, adaptiveGlassControls: true,
                headerAppearance: headerAppearance,
                topInset: safeGeometry.safeAreaInsets.top, transparentHeader: true,
                readingLayout: resolvedReadingLayout, onToggleReadingMode: { readingLayout = resolvedReadingLayout.next.rawValue },
                indexIconIsOpen: indexMotion.isIndexMode,
                indexExitOffset: !showsBars && showsIndex && indexMotion.phase != .preparing && indexMotion.phase != .openingDrag
                    ? indexMotion.offset : nil,
                indexExitBoundary: geometry.size.height / 3,
                shareURL: URL(string: "https://komiflo.com")!
                    .appendingPathComponent("comics").appendingPathComponent(String(comicID)),
                onBack: returnToPreviousScreen, onSettings: {
                    stopAutoplay()
                    openReaderSettings(ReaderSettingsRequest())
                },
                onInfo: {
                    stopAutoplay()
                    closeIndex(animated: false)
                    showsComments = true
                },
                onBookmark: { Task { await library.toggleBookmark(comicID) } },
                onIndex: {
                    if showsIndex { closeIndex() } else if document != nil { openIndex() }
                }, onLike: { Task { await library.toggleLike(comicID) } },
                onAutoplay: { toggleAutoplay() }
            )
            .padding(.bottom, glassButtons ? safeGeometry.safeAreaInsets.bottom : 0)
            .zIndex(2)
        }
        .onAppear {
            indexMotion.resize(height: geometry.size.height)
            readerSize = geometry.size
        }
        .onChange(of: geometry.size) { _, size in
            indexMotion.resize(height: size.height)
            readerSize = size
        }
        }
        .ignoresSafeArea(.container)
        }
    }

    private var showsHorizontalProgress: Bool {
        if resolvedReadingLayout == .verticalScroll {
            return verticalNavigationHorizontalProgress && (barsVisible || showsVerticalPageProgress)
        }
        return showsPageProgress
    }

    private var showsVerticalProgress: Bool {
        resolvedReadingLayout == .verticalScroll && !verticalNavigationHorizontalProgress
            && (barsVisible || showsVerticalPageProgress)
    }

    private var footerBottomPadding: CGFloat {
        (showsBars ? 96 : 12) + (showsHorizontalProgress ? 16 : 0)
    }

    private func open(comicID: Int, title: String) {
        swipeTargetPage = nil
        if !readingCollection.contains(where: { $0.id == comicID }) { readingCollection = [] }
        stopAutoplay()
        closeIndex(animated: false)
        session.close()
        self.title = title
        self.comicID = comicID
        page = 1
        showsBars = showsBarsOnOpen
    }

    private func openPreviousEnd(_ previous: ComicSummary) {
        open(comicID: previous.id, title: previous.title)
        // 移動先のページ数は読み込んでから確定するので、末尾へ収まる値を渡す。
        page = Int.max
    }

    private func pullBeforeFirst() {
        guard !barsVisible else { return }
        if let previous { openPreviousEnd(previous) } else { returnToPreviousScreen() }
    }

    private func returnToPreviousScreen() {
        stopAutoplay()
        closeReader { session.close() }
    }

    private func returnHome() {
        stopAutoplay()
        closeIndex(animated: false)
        closeReader {
            session.close()
            onHome()
        }
    }

    private func neighboringChapter(offset: Int) -> ComicSummary? {
        guard let index = readingCollection.firstIndex(where: { $0.id == comicID }), readingCollection.indices.contains(index + offset) else { return nil }
        return readingCollection[index + offset]
    }

    private func loadRelated(content: KFContent, openedID: Int) async {
        if let parent = content.parentID {
            let contents = await library.issueComics(issueID: parent) ?? []
            guard !Task.isCancelled, comicID == openedID else { return }
            chapters = contents
            issueTitle = content.magazine
        }
        let recommended = (try? await library.api.recommends(contentID: openedID)) ?? []
        guard !Task.isCancelled, comicID == openedID else { return }
        recommendations = recommended.map(\.summary)
    }

    private func openIndex() {
        stopAutoplay()
        indexMotion.open(animated: indexAnimation && !reduceMotion)
    }
    private var resolvedReadingLayout: NativeReadingLayout {
        readingLayout == NativeReadingLayout.verticalScroll.rawValue ? .verticalScroll : (verticalSwipe ? .verticalPages : .horizontal)
    }

    private func selectFromProgress(_ selected: Int) {
        guard !showsIndex, let document else { return }
        stopAutoplay()
        let target = min(max(1, selected), document.pages.count)
        guard page != target else { return }
        pageSelectedFromProgress = target
        page = target
    }

    private func closeIndex(animated: Bool = true) {
        indexMotion.close(animated: animated && indexAnimation && !reduceMotion)
    }

    private func toggleNavigation() {
        if showsBars {
            // ナビを開いたために止めた再生だけを戻す。手動停止・解除は対象にしない。
            let resumes = autoplayClock.shouldResumeAfterNavigation(
                enabled: stopAutoplayOnNavigation && resumeAutoplayAfterNavigation)
            showsBars = false
            if resumes { toggleAutoplay() }
        } else {
            if stopAutoplayOnNavigation { pauseAutoplay(reason: .navigation) }
            showsBars = true
        }
    }

    private func toggleAutoplay() {
        if isAutoplaying { pauseAutoplay(); return }
        guard let document, !atEnd, session.images[page] != nil else { return }
        let last = document.pages.count + (showsEndPage ? 1 : 0)
        let now = ProcessInfo.processInfo.systemUptime
        if autoplayClock.isVisible { autoplayClock.resume(at: now) }
        else { autoplayClock.start(duration: NativeReaderSettings.autoplayDuration(autoplaySeconds), at: now) }
        showsBars = false
        closeIndex()
        autoplayTask = Task {
            while !Task.isCancelled {
                let remaining = autoplayClock.remaining(at: ProcessInfo.processInfo.systemUptime)
                try? await Task.sleep(for: .seconds(remaining))
                // 古い待機のキャンセルでは、再開した新しい再生状態を消さない。
                guard !Task.isCancelled else { return }
                guard isAutoplaying, page < last else { stopAutoplay(); return }
                // 見開きでは次の組の先頭へ進む。
                let target = spreadLayout?.next(after: page) ?? page + 1
                // 読み込みが追いついていないページへは進まない。自動で再試行・監視せず止める。
                guard target > document.pages.count || session.images[target] != nil else { stopAutoplay(); return }
                autoplayClock.start(duration: NativeReaderSettings.autoplayDuration(autoplaySeconds),
                                    at: ProcessInfo.processInfo.systemUptime)
                page = target
                if page == last { stopAutoplay(); return }
            }
        }
    }

    private func stopAutoplay() {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayClock.clear()
    }

    private func pauseAutoplay(reason: ReaderAutoplayClock.PauseReason = .user) {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayClock.pause(at: ProcessInfo.processInfo.systemUptime, reason: reason)
    }
}

enum NativeReaderSettings {
    static func previousHintPosition(_ value: Double) -> Double {
        value.isFinite ? min(96, max(-48, value)) : 0
    }
    static func previousHintTravel(_ value: Double) -> Double {
        value.isFinite ? min(128, max(16, value)) : 48
    }
    static func autoplayDuration(_ value: Double) -> Double {
        value.isFinite ? min(30, max(4, value)) : 6
    }
    static let autoplayKey = "reader.native.autoplaySeconds"
    static let endPageKey = "reader.native.showsEndPage"
    static let hideBarsOnTurnKey = "reader.native.hideBarsOnTurn"
    static let showsBarsOnOpenKey = "reader.native.showsBarsOnOpen"
    static let magazineLogoKey = "reader.native.magazineLogo"
    static let indexAnimationKey = "reader.native.indexAnimation"
    static let swipeUpIndexKey = "reader.native.swipeUpIndex"
    static let entranceAnimationKey = "reader.entranceAnimation"
    static let autoplayStyleKey = "reader.native.autoplayStyle"
    static let autoplayBelowImageKey = "reader.native.autoplayBelowImage"
    static let autoplayStopsOnNavigationKey = "reader.native.autoplayStopsOnNavigation"
    static let autoplayResumesAfterNavigationKey = "reader.native.autoplayResumesAfterNavigation"
    static let autoplayContinuesOnLayoutChangeKey = "reader.native.autoplayContinuesOnLayoutChange"
    static let pageProgressKey = "reader.native.pageProgress"
    static let verticalPageProgressKey = "reader.native.verticalPageProgress"
    static let verticalNavigationHorizontalProgressKey = "reader.native.verticalNavigationHorizontalProgress"
    static let progressOnLeftKey = "reader.native.progressOnLeft"
    static let previousHintPositionKey = "reader.native.previousHintPosition"
    static let previousHintTravelKey = "reader.native.previousHintTravel"
    static let missingPreviousHeading = "前の作品：Not Found"
    static let missingPreviousTitle = "No Title"
    static let missingPreviousInstruction = "前の画面にもどるけどいい？"
}
