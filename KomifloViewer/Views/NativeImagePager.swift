import SwiftUI
import UIKit

/// WebViewを使わず、ページの画像をUIKitで表示する。画面を閉じたら表示用の参照も捨てる。
struct NativeImagePager: UIViewControllerRepresentable {
    let comicID: Int
    let pageCount: Int
    let includesEndPage: Bool
    let images: [Int: UIImage]
    let errors: [Int: String]
    @Binding var page: Int
    let onTap: () -> Void
    let onUserTurn: () -> Void
    let onBeforeFirst: () -> Void
    var onAfterLast: () -> Void = {}
    var endPage: AnyView = AnyView(Color.clear)
    var previewPages: Set<Int> = []
    var tapMode: ReaderTapMode = .leftForward
    var animatesTap = true
    var swipeUpOpensIndex = false
    var onOpenIndex: () -> Void = {}
    var navigationBlocked = false
    var onIndexDragChanged: (CGFloat) -> Void = { _ in }
    var onIndexDragEnded: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
    var verticalPaging = false
    var canMoveBefore = true
    var canMoveAfter = true
    var endSwipeMotion: ReaderEndSwipeMotion?
    var endContentInsets: UIEdgeInsets?
    var headerAppearance: ReaderHeaderAppearance?
    var headerCenterY: CGFloat = 0
    var startPage: AnyView = AnyView(Color.clear)
    var startSwipeMotion: ReaderEndSwipeMotion?
    var startHintExtension: CGFloat = 0
    var onBeforeFirstPull: (() -> Void)?
    var previousPullEnabled = true
    var imageGeometry: ReaderImageGeometry?
    var onSwipeTarget: (Int?) -> Void = { _ in }
    var spreads: ReaderSpreadLayout?

    func makeUIViewController(context: Context) -> NativeImagePagingController {
        let controller = NativeImagePagingController(verticalPaging: verticalPaging)
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: NativeImagePagingController, context: Context) { update(controller) }

    private func update(_ controller: NativeImagePagingController) {
        controller.onPageChange = { value in
            if page != value { page = value }
        }
        controller.onSwipeTarget = onSwipeTarget
        controller.onTap = onTap
        controller.onUserTurn = onUserTurn
        controller.onBeforeFirst = onBeforeFirst
        controller.onAfterLast = onAfterLast
        controller.canMoveBefore = canMoveBefore
        controller.canMoveAfter = canMoveAfter
        controller.endSwipeMotion = endSwipeMotion
        controller.endContentInsets = endContentInsets
        controller.endPage = endPage
        controller.tapMode = tapMode
        controller.animatesTap = animatesTap
        controller.swipeUpOpensIndex = swipeUpOpensIndex
        controller.onOpenIndex = onOpenIndex
        controller.navigationBlocked = navigationBlocked
        controller.onIndexDragChanged = onIndexDragChanged
        controller.onIndexDragEnded = onIndexDragEnded
        controller.headerAppearance = headerAppearance
        controller.headerCenterY = headerCenterY
        controller.startPage = startPage
        controller.startSwipeMotion = startSwipeMotion
        controller.startHintExtension = startHintExtension
        controller.onBeforeFirstPull = onBeforeFirstPull
        controller.previousPullEnabled = previousPullEnabled
        controller.imageGeometry = imageGeometry
        controller.configure(comicID: comicID, count: pageCount, includesEndPage: includesEndPage, page: page, images: images, errors: errors,
                             previewPages: previewPages, spreads: spreads ?? .single(count: pageCount))
    }

    static func dismantleUIViewController(_ controller: NativeImagePagingController, coordinator: ()) {
        controller.clear()
    }
}

final class NativeImagePagingController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    var onPageChange: (Int) -> Void = { _ in }
    var onSwipeTarget: (Int?) -> Void = { _ in }
    var onTap: () -> Void = {}
    var onUserTurn: () -> Void = {}
    var onBeforeFirst: () -> Void = {}
    var onBeforeFirstPull: (() -> Void)?
    var onAfterLast: () -> Void = {}
    var canMoveBefore = true
    var canMoveAfter = true
    var endSwipeMotion: ReaderEndSwipeMotion?
    var endContentInsets: UIEdgeInsets?
    var headerAppearance: ReaderHeaderAppearance?
    var headerCenterY: CGFloat = 0
    var imageGeometry: ReaderImageGeometry?
    var startPage: AnyView = AnyView(Color.clear)
    var startSwipeMotion: ReaderEndSwipeMotion?
    var startHintExtension: CGFloat = 0
    var previousPullEnabled = true {
        didSet {
            if !previousPullEnabled && (pullingPrevious || pullingStartHorizontally) {
                verticalProgress = 0
                startSwipeMotion?.reset()
            }
            if isViewLoaded { layoutStartHint() }
        }
    }
    private var startController: UIHostingController<AnyView>?
    var endPage = AnyView(Color.clear)
    var tapMode: ReaderTapMode = .leftForward
    var animatesTap = true
    var swipeUpOpensIndex = false
    var onOpenIndex: () -> Void = {}
    var navigationBlocked = false
    var onIndexDragChanged: (CGFloat) -> Void = { _ in }
    var onIndexDragEnded: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
    private let pager: UIPageViewController
    private let verticalPaging: Bool
    private let verticalPan = UIPanGestureRecognizer()
    private let horizontalBoundaryPan = UIPanGestureRecognizer()
    private var pullingStartHorizontally = false
    private var pullingEndHorizontally = false
    private var endPullsForward = false
    private var comicID = 0
    private var count = 0
    private var includesEndPage = true
    private var lastPage: Int { count + (includesEndPage ? 1 : 0) }
    private var current = 1
    private var images: [Int: UIImage] = [:]
    private var errors: [Int: String] = [:]
    private var previewPages: Set<Int> = []
    // 見開きでは組の先頭ページの番号で部品を持つ。currentも表示中の組の先頭。
    private var spreads = ReaderSpreadLayout.single(count: 0)
    // iOSが再利用している部品も更新する。ここからは保持せず、実際の表示側に寿命を任せる。
    private final class PageReference {
        weak var value: NativeImagePageController?
        init(_ value: NativeImagePageController) { self.value = value }
    }
    private var pages: [Int: PageReference] = [:]
    private var transitioning = false
    private var animatingTap = false
    private var transitionID = UUID()
    private var requestedPage = 1
    private var verticalProgress: CGFloat = 0
    private var pullingIndex = false
    private var pullingPrevious = false
    private var usesSwipeIndex: Bool { swipeUpOpensIndex && !verticalPaging }
    private var canPullPrevious: Bool {
        current == 1 && previousPullEnabled && (canMoveBefore || onBeforeFirstPull != nil || startSwipeMotion != nil)
    }
    private var acceptsVerticalSwipe = false
    private var beganBeforeFirst = false
    private var beganAfterLast = false

    init(verticalPaging: Bool = false) {
        self.verticalPaging = verticalPaging
        pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: verticalPaging ? .vertical : .horizontal)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.dataSource = self
        pager.delegate = self
        verticalPan.addTarget(self, action: #selector(verticalSwipe(_:)))
        verticalPan.delegate = self
        verticalPan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(verticalPan)
        if !verticalPaging {
            horizontalBoundaryPan.addTarget(self, action: #selector(horizontalBoundarySwipe(_:)))
            horizontalBoundaryPan.delegate = self
            horizontalBoundaryPan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(horizontalBoundaryPan)
        }
        for scroll in pager.view.subviews.compactMap({ $0 as? UIScrollView }) {
            // 縦送りの先頭・末尾は文字だけを引き、途中のページは通常の送りへ渡す。
            scroll.panGestureRecognizer.require(toFail: verticalPan)
            if !verticalPaging {
                // 先頭の前作品案内と読み終わりの横操作は文字だけを動かす。
                scroll.panGestureRecognizer.require(toFail: horizontalBoundaryPan)
                scroll.panGestureRecognizer.addTarget(self, action: #selector(horizontalEdge(_:)))
            }
        }
    }

    func configure(comicID: Int, count: Int, includesEndPage: Bool, page: Int, images: [Int: UIImage], errors: [Int: String],
                   previewPages: Set<Int> = [], spreads: ReaderSpreadLayout? = nil) {
        loadViewIfNeeded()
        let changed = self.comicID != comicID
        if changed { clear() }
        let spreads = spreads ?? .single(count: count)
        // 回転・設定で組み方が変わったら、受信済みの画像はそのままに部品だけを作り直す。
        let regrouped = !changed && spreads != self.spreads
        if regrouped { pages.removeAll() }
        self.spreads = spreads
        self.comicID = comicID
        self.count = count
        self.includesEndPage = includesEndPage
        self.images = images
        self.errors = errors
        self.previewPages = previewPages
        for (number, reference) in pages {
            guard let controller = reference.value else { continue }
            show(controller, number: number)
        }
        let requested = min(max(page, 1), lastPage)
        // 組の2ページ目が指定されても、その組を表示する。指定したページ番号は変えない。
        let target = spreads.start(of: requested)
        requestedPage = requested
        if changed || regrouped || pager.viewControllers?.isEmpty != false || (!transitioning && target != current) {
            let direction = direction(for: target - current)
            current = target
            if let controller = controller(for: target) {
                pager.setViewControllers([controller], direction: direction, animated: false)
            }
            prune()
        }
        updatePagingEnabled()
        updateHeaderAppearance()
        updateStartHint()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutStartHint()
        updateHeaderAppearance()
    }

    private func controller(for number: Int) -> NativeImagePageController? {
        guard number > 0, number <= lastPage else { return nil }
        let number = spreads.start(of: number)
        if let controller = pages[number]?.value { return controller }
        let group = number <= count ? spreads.pages(startingAt: number) : [number]
        let controller = NativeImagePageController(comicID: comicID, number: number, pairedNumber: group.count > 1 ? group[1] : nil)
        controller.continuousVertical = verticalPaging
        controller.onImageGeometryChanged = { [weak self] in
            guard let self, self.current == number else { return }
            self.updateHeaderAppearance()
            self.layoutStartHint()
        }
        controller.onTap = { [weak self] fraction in self?.handleTap(at: fraction) }
        controller.onZoomChanged = { [weak self] zoomed in
            guard let self, self.current == number else { return }
            self.updatePagingEnabled()
        }
        show(controller, number: number)
        pages[number] = PageReference(controller)
        return controller
    }

    private func show(_ controller: NativeImagePageController, number: Int) {
        controller.display(image: images[number], error: errors[number], isEnd: number == count + 1, isPreview: previewPages.contains(number))
        if let paired = controller.pairedNumber {
            controller.displayPaired(image: images[paired], error: errors[paired], isPreview: previewPages.contains(paired))
        }
        if number == count + 1 { controller.displayEnd(endPage, insets: endContentInsets) }
    }

    /// 1ページ表示では前後の番号、見開きでは前後の組の先頭。
    private func neighbor(of number: Int, forward: Bool) -> Int {
        forward ? spreads.next(after: number) : spreads.previous(before: number)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? NativeImagePageController, page.comicID == comicID else { return nil }
        // 右から左へ読むので、左側（before）が次のページ。
        return controller(for: neighbor(of: page.number, forward: !verticalPaging))
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? NativeImagePageController, page.comicID == comicID else { return nil }
        return controller(for: neighbor(of: page.number, forward: verticalPaging))
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        transitioning = true
        onUserTurn()
        if !verticalPaging, let pending = pendingViewControllers.first as? NativeImagePageController, pending.comicID == comicID {
            // 確定ページは完了まで変えず、進捗の移動だけをスワイプ開始に合わせる。
            onSwipeTarget(pending.number)
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        transitioning = false
        defer { if !verticalPaging { onSwipeTarget(nil) } }
        guard let visible = pager.viewControllers?.first as? NativeImagePageController, visible.comicID == comicID else { return }
        current = visible.number
        prune()
        updatePagingEnabled()
        if completed { onPageChange(current) }
        updateHeaderAppearance()
        layoutStartHint()
    }

    private func updateStartHint() {
        guard startSwipeMotion != nil else { startController?.view.isHidden = true; return }
        if let startController { startController.rootView = startPage }
        else {
            let controller = UIHostingController(rootView: startPage)
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            controller.view.isUserInteractionEnabled = false
            addChild(controller)
            view.addSubview(controller.view)
            controller.didMove(toParent: self)
            startController = controller
        }
        layoutStartHint()
    }

    private func layoutStartHint() {
        guard let startController else { return }
        startController.view.isHidden = !previousPullEnabled || startSwipeMotion == nil || current != 1 || pages[current]?.value?.isZoomed == true
        let imageFrame = pages[1]?.value?.displayedImageFrame(in: view) ?? .null
        let space = imageFrame.isNull ? 0 : max(0, imageFrame.minY)
        let frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: space + startHintExtension)
        if startController.view.frame != frame { startController.view.frame = frame }
    }

    private func updateHeaderAppearance() {
        guard imageGeometry != nil || (headerAppearance != nil && !transitioning) else { return }
        let frame = pages[current]?.value?.displayedImageFrame(in: view) ?? .null
        imageGeometry?.update(frame: frame)
        guard let headerAppearance, !transitioning else { return }
        headerAppearance.update(isOverComic: frame.contains(CGPoint(x: view.bounds.midX, y: headerCenterY)))
    }

    private func prune() {
        // 保持中の部品をclearすると、UIPageViewControllerが空の画像・操作を再表示してしまう。
        pages = pages.filter { $0.value.value != nil }
    }

    private func updatePagingEnabled() {
        for scroll in pager.view.subviews.compactMap({ $0 as? UIScrollView }) {
            // 指で動かしている途中に無効化すると、スワイプの完了通知を失う。
            scroll.isScrollEnabled = (!navigationBlocked || transitioning) && !animatingTap && pages[current]?.value?.isZoomed != true
        }
    }

    func handleTap(at fraction: Double) {
        guard !navigationBlocked, !transitioning, current >= 1, current <= count, let visible = pages[current]?.value else { return }
        let offset = visible.isZoomed ? 0 : tapMode.pageOffset(at: fraction)
        guard offset != 0 else { onTap(); return }
        onUserTurn()
        let target = neighbor(of: current, forward: offset > 0)
        if target < 1 { onBeforeFirst(); return }
        if target > lastPage { onAfterLast(); return }
        guard let controller = controller(for: target) else { return }
        // 読み込みは移動開始時に進め、アニメーション中の重複した移動だけを防ぐ。
        current = target
        requestedPage = target
        let animated = animatesTap && !UIAccessibility.isReduceMotionEnabled
        transitioning = animated
        animatingTap = animated
        let ticket = UUID()
        transitionID = ticket
        onPageChange(target)
        updatePagingEnabled()
        pager.setViewControllers([controller], direction: direction(for: offset), animated: animated) { [weak self] _ in
            guard let self, self.transitionID == ticket else { return }
            self.transitioning = false
            self.animatingTap = false
            if let visible = self.pager.viewControllers?.first as? NativeImagePageController { self.current = visible.number }
            // アニメーション中のインデックス選択などは、完了時に最新の指定へ合わせる。
            self.configure(comicID: self.comicID, count: self.count, includesEndPage: self.includesEndPage,
                           page: self.requestedPage, images: self.images, errors: self.errors, previewPages: self.previewPages,
                           spreads: self.spreads)
            self.prune()
        }
    }

    func clear() {
        transitionID = UUID()
        endSwipeMotion?.reset()
        startSwipeMotion?.reset()
        startController?.willMove(toParent: nil)
        startController?.view.removeFromSuperview()
        startController?.removeFromParent()
        startController = nil
        pages.values.forEach { $0.value?.clear() }
        pages.removeAll()
        images.removeAll()
        errors.removeAll()
        previewPages.removeAll()
        transitioning = false
        animatingTap = false
        verticalProgress = 0
        pullingIndex = false
        pullingPrevious = false
        acceptsVerticalSwipe = false
        beganBeforeFirst = false
        beganAfterLast = false
        pullingStartHorizontally = false
        pullingEndHorizontally = false
        if isViewLoaded {
            // UIPageViewControllerは表示する部品を1つ必要とする。画像を空にした部品は、親の破棄に任せる。
            updatePagingEnabled()
        }
    }
    private func direction(for offset: Int) -> UIPageViewController.NavigationDirection {
        (offset > 0) == verticalPaging ? .forward : .reverse
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !navigationBlocked, !transitioning,
              let visible = pager.viewControllers?.first as? NativeImagePageController, !visible.isZoomed else { return false }
        if gestureRecognizer === horizontalBoundaryPan {
            let velocity = horizontalBoundaryPan.velocity(in: view)
            guard !verticalPaging, abs(velocity.x) > abs(velocity.y) else { return false }
            return (velocity.x < 0 && canPullPrevious) || (includesEndPage && current == lastPage)
        }
        guard gestureRecognizer === verticalPan else { return false }
        let velocity = verticalPan.velocity(in: view)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        if current == 1 && velocity.y > 0 && !previousPullEnabled { return false }
        if verticalPaging {
            return (current == 1 && velocity.y > 0) || (current == lastPage && velocity.y < 0)
        }
        return !usesSwipeIndex || velocity.y < 0 || canPullPrevious
    }

    @objc private func horizontalBoundarySwipe(_ recognizer: UIPanGestureRecognizer) {
        let threshold = max(1, min(view.bounds.width * 0.2, 64))
        switch recognizer.state {
        case .began:
            let available = !navigationBlocked && !transitioning
            pullingStartHorizontally = available && recognizer.velocity(in: view).x < 0 && canPullPrevious
            pullingEndHorizontally = available && !pullingStartHorizontally && includesEndPage && current == lastPage
            endPullsForward = recognizer.velocity(in: view).x > 0
            if pullingStartHorizontally || pullingEndHorizontally { onUserTurn() }
        case .changed:
            if pullingStartHorizontally {
                guard !navigationBlocked, canPullPrevious else { return }
                // 先頭から左へ引き始めた操作は、戻しても画像を動かさず文字だけを戻す。
                startSwipeMotion?.pullHorizontal(translation: min(0, recognizer.translation(in: view).x), threshold: threshold)
                return
            }
            guard pullingEndHorizontally, !navigationBlocked, current == lastPage else { return }
            let translation = recognizer.translation(in: view).x
            // 公式と同じく、引き始めた方向の範囲で止める。指を戻しても逆側の操作にはしない。
            let distance = endPullsForward ? (canMoveAfter ? max(0, translation) : 0) : min(0, translation)
            endSwipeMotion?.pullHorizontal(translation: distance, threshold: threshold)
        case .ended, .cancelled, .failed:
            let translation = recognizer.translation(in: view).x
            if pullingStartHorizontally {
                pullingStartHorizontally = false
                startSwipeMotion?.reset(animated: true)
                if recognizer.state == .ended && translation <= -threshold { finishPreviousPull() }
                return
            }
            let completed = recognizer.state == .ended && pullingEndHorizontally && !navigationBlocked && current == lastPage
            pullingEndHorizontally = false
            endSwipeMotion?.reset(animated: true)
            guard completed else { return }
            // 速さによる推測は加えず、公式と同じ引っ張り量に達してから指を離したときだけ移る。
            if endPullsForward && translation >= threshold && canMoveAfter { onAfterLast() }
            else if !endPullsForward && translation <= -threshold { onPageChange(max(1, neighbor(of: current, forward: false))) }
        default: break
        }
    }

    private func finishPreviousPull() {
        guard !navigationBlocked, !transitioning, canPullPrevious, pages[current]?.value?.isZoomed != true else { return }
        if let onBeforeFirstPull { onBeforeFirstPull() }
        else if canMoveBefore { onBeforeFirst() }
    }

    @objc private func horizontalEdge(_ recognizer: UIPanGestureRecognizer) {
        guard !navigationBlocked else { beganBeforeFirst = false; beganAfterLast = false; return }
        switch recognizer.state {
        case .began:
            beganBeforeFirst = current == 1 && pages[current]?.value?.isZoomed != true
            beganAfterLast = current == lastPage && pages[current]?.value?.isZoomed != true
        case .ended:
            let moved = recognizer.translation(in: view)
            if beganBeforeFirst, current == 1, moved.x <= -min(view.bounds.width * 0.2, 64), abs(moved.x) > abs(moved.y) {
                onUserTurn()
                onBeforeFirst()
            }
            if beganAfterLast, current == lastPage, moved.x >= min(view.bounds.width * 0.2, 64), abs(moved.x) > abs(moved.y) {
                onUserTurn()
                onAfterLast()
            }
            beganBeforeFirst = false
            beganAfterLast = false
        case .cancelled, .failed: beganBeforeFirst = false; beganAfterLast = false
        default: break
        }
    }

    @objc private func verticalSwipe(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginVerticalSwipe(upward: recognizer.velocity(in: view).y < 0)
        case .changed:
            updateVerticalSwipe(translation: recognizer.translation(in: view).y)
        case .ended:
            let translation = recognizer.translation(in: view).y
            endVerticalSwipe(translation: translation, predicted: translation + recognizer.velocity(in: view).y * 0.15, cancelled: false)
        case .cancelled, .failed:
            endVerticalSwipe(translation: 0, predicted: 0, cancelled: true)
        default: break
        }
    }

    func beginVerticalSwipe(upward: Bool) {
        acceptsVerticalSwipe = false
        pullingPrevious = false
        guard !navigationBlocked, !transitioning, pages[current]?.value?.isZoomed != true,
              !usesSwipeIndex || upward || canPullPrevious else { return }
        if current == 1 && !upward && !canPullPrevious { return }
        if !usesSwipeIndex && current == lastPage && upward && !canMoveAfter { return }
        acceptsVerticalSwipe = true
        onUserTurn()
        verticalProgress = 0
        pullingIndex = usesSwipeIndex && upward
        pullingPrevious = !pullingIndex && current == 1 && !upward
        if pullingIndex { onIndexDragChanged(0) }
    }

    func updateVerticalSwipe(translation: CGFloat) {
        guard acceptsVerticalSwipe, let visible = pager.viewControllers?.first else { return }
        if pullingIndex {
            visible.view.transform = .identity
            onIndexDragChanged(max(0, -translation))
        } else if pullingPrevious || !usesSwipeIndex {
            let threshold = max(1, min(view.bounds.width * 0.2, 64))
            verticalProgress = min(max(-translation / threshold, -1), 1)
            if pullingPrevious {
                // 前作品の文字だけを引き、途中で上へ戻しても画像を動かさない。
                visible.view.transform = .identity
                guard previousPullEnabled else { verticalProgress = 0; startSwipeMotion?.reset(); return }
                verticalProgress = -min(1, max(0, translation) / threshold)
                startSwipeMotion?.pull(translation: max(0, translation), threshold: threshold)
            } else if includesEndPage && current == lastPage {
                // 読み終わりは画面全体ではなく、次の作品の文字だけを動かす。
                visible.view.transform = .identity
                endSwipeMotion?.pull(translation: translation, threshold: threshold)
            } else {
                visible.view.transform = CGAffineTransform(translationX: 0, y: -verticalProgress * 32)
            }
        }
    }

    func endVerticalSwipe(translation: CGFloat, predicted: CGFloat, cancelled: Bool) {
        pager.viewControllers?.first?.view.transform = .identity
        endSwipeMotion?.reset(animated: true)
        startSwipeMotion?.reset(animated: true)
        let wasIndex = pullingIndex
        pullingIndex = false
        if wasIndex { onIndexDragEnded(max(0, -translation), max(0, -predicted), cancelled) }
        else if !cancelled && acceptsVerticalSwipe { handleVerticalSwipe(progress: verticalProgress) }
        acceptsVerticalSwipe = false
        pullingPrevious = false
        verticalProgress = 0
    }

    func handleVerticalSwipe(progress: CGFloat) {
        guard !navigationBlocked, !transitioning, pages[current]?.value?.isZoomed != true else { return }
        // 先頭の前作品案内だけは、インデックス用の上スワイプと併用する。
        if progress <= -1 && canPullPrevious {
            finishPreviousPull()
            return
        }
        // 途中のページでは、インデックス用の設定中は上下ともページ移動には使わない。
        if usesSwipeIndex {
            if progress >= 1 { onOpenIndex() }
            return
        }
        if progress >= 1 {
            if current < lastPage { onPageChange(neighbor(of: current, forward: true)) }
            else if canMoveAfter { onAfterLast() }
        } else if progress <= -1 && current > 1 {
            onPageChange(neighbor(of: current, forward: false))
        }
    }
}

final class NativeImagePageController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let comicID: Int
    let number: Int
    /// 見開きで左側に並べる次のページ。1ページ表示ではnil。
    let pairedNumber: Int?
    var onTap: (Double) -> Void = { _ in }
    var onZoomChanged: (Bool) -> Void = { _ in }
    var onImageGeometryChanged: () -> Void = {}
    var isZoomed: Bool { scroll.zoomScale > 1.01 }
    var continuousVertical = false
    // 操作の方向とは分け、元画像の比率で作った連続スクロールの枠だけを埋める。
    var fillsContinuousPage = false
    var onParentZoom: ((CGPoint) -> Void)?
    var parentTapFraction: ((CGPoint) -> Double)?
    private let scroll = UIScrollView()
    // 拡大は2枚を一緒に扱うため、画像を入れる枠ごと拡大する。
    private let contentView = UIView()
    private let imageView = UIImageView()
    private let pairedImageView = UIImageView()
    private var errorText: String?
    private var pairedErrorText: String?
    private var endController: UIHostingController<AnyView>?
    private var endConstraints: [NSLayoutConstraint] = []
    private let message = UILabel()
    private let edgeTap = UITapGestureRecognizer()
    private let centerTap = UITapGestureRecognizer()
    private let centerDoubleTap = UITapGestureRecognizer()

    init(comicID: Int, number: Int, pairedNumber: Int? = nil) {
        self.comicID = comicID
        self.number = number
        self.pairedNumber = pairedNumber
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "native-reader-page-\(number)"
        scroll.backgroundColor = .black
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = onParentZoom == nil ? 4 : 1
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        if continuousVertical { updateVerticalInput() }
        // 縦の列は画像の比率で枠を作るため、端数による内側の黒い隙間を作らず枠を埋める。
        imageView.contentMode = fillsContinuousPage ? .scaleToFill : .scaleAspectFit
        imageView.accessibilityLabel = "\(number)ページ"
        contentView.addSubview(imageView)
        if let pairedNumber {
            pairedImageView.contentMode = .scaleAspectFit
            pairedImageView.accessibilityLabel = "\(pairedNumber)ページ"
            contentView.addSubview(pairedImageView)
        }
        scroll.addSubview(contentView)
        view.addSubview(scroll)
        message.textColor = .white
        message.textAlignment = .center
        message.numberOfLines = 0
        view.addSubview(message)
        // 中央だけ2回目を判別し、左右のページ送りには待ち時間を付けない。
        edgeTap.addTarget(self, action: #selector(tapped(_:)))
        centerTap.addTarget(self, action: #selector(tapped(_:)))
        centerDoubleTap.addTarget(self, action: #selector(zoom(_:)))
        centerDoubleTap.numberOfTapsRequired = 2
        centerTap.require(toFail: centerDoubleTap)
        for gesture in [edgeTap, centerTap, centerDoubleTap] {
            gesture.delegate = self
            view.addGestureRecognizer(gesture)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.bounds.size != view.bounds.size {
            scroll.setZoomScale(1, animated: false)
            scroll.frame = view.bounds
            contentView.frame = scroll.bounds
            layoutImages()
            scroll.contentSize = scroll.bounds.size
        }
        message.frame = view.bounds.insetBy(dx: 28, dy: 80)
        if continuousVertical { updateVerticalInput() }
        onImageGeometryChanged()
    }

    func display(image: UIImage?, error: String?, isEnd: Bool, isPreview: Bool) {
        loadViewIfNeeded()
        let resized = imageView.image?.size != image?.size
        imageView.image = image
        // 公式の通常画質表示と同じく、縮小画像だけは薄く出して本画像と区別する。
        imageView.alpha = isPreview ? 0.5 : 1
        errorText = error
        message.text = errorText ?? pairedErrorText
        scroll.isHidden = isEnd
        view.backgroundColor = isEnd ? UIColor(white: 17 / 255, alpha: 1) : .black
        for gesture in view.gestureRecognizers ?? [] { gesture.isEnabled = !isEnd }
        if resized, pairedNumber != nil { layoutImages() }
        onImageGeometryChanged()
    }

    /// 見開きの左側のページ。右側と同じ画質の区別・失敗表示を使う。
    func displayPaired(image: UIImage?, error: String?, isPreview: Bool) {
        guard pairedNumber != nil else { return }
        loadViewIfNeeded()
        let resized = pairedImageView.image?.size != image?.size
        pairedImageView.image = image
        pairedImageView.alpha = isPreview ? 0.5 : 1
        pairedErrorText = error
        message.text = errorText ?? pairedErrorText
        if resized { layoutImages() }
        onImageGeometryChanged()
    }

    /// 2枚の高さをそろえて画面に収め、右から左へ読む順に小さい番号を右へ置く。
    private func layoutImages() {
        let bounds = contentView.bounds
        guard pairedNumber != nil else { imageView.frame = bounds; return }
        // 読み込み前のページは、もう片方か公式の標準寸法（1360×1920）の比率で場所を空けておく。
        let fallback = imageView.image?.size ?? pairedImageView.image?.size ?? CGSize(width: 1360, height: 1920)
        func ratio(_ size: CGSize?) -> CGFloat {
            let size = size ?? fallback
            return size.width > 0 && size.height > 0 ? size.width / size.height : 1360 / 1920
        }
        let right = ratio(imageView.image?.size), left = ratio(pairedImageView.image?.size)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let height = min(bounds.height, bounds.width / (right + left))
        let total = height * (right + left)
        let x = bounds.midX - total / 2, y = bounds.midY - height / 2
        pairedImageView.frame = CGRect(x: x, y: y, width: height * left, height: height)
        imageView.frame = CGRect(x: x + height * left, y: y, width: height * right, height: height)
    }

    func displayedImageFrame(in container: UIView) -> CGRect {
        guard isViewLoaded, !scroll.isHidden else { return .null }
        let frames = (pairedNumber == nil ? [imageView] : [imageView, pairedImageView]).map { fittedFrame(of: $0, in: container) }
        return frames.reduce(CGRect.null) { $0.union($1) }
    }

    private func fittedFrame(of imageView: UIImageView, in container: UIView) -> CGRect {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return .null }
        let bounds = imageView.bounds
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fitted = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        return imageView.convert(fitted, to: container)
    }

    func displayEnd(_ content: AnyView, insets: UIEdgeInsets? = nil) {
        if let endController {
            endController.rootView = content
            if let insets { updateEndInsets(insets) }
            return
        }
        let controller = UIHostingController(rootView: content)
        if insets != nil { controller.safeAreaRegions = [] }
        addChild(controller)
        controller.view.backgroundColor = UIColor(white: 17 / 255, alpha: 1)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        if let insets {
            // 横・縦とも同じ画面の余白を使い、スクロール中のセルの安全領域には依存しない。
            endConstraints = [
                controller.view.topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -insets.bottom),
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -insets.right)
            ]
        } else {
            endConstraints = [
                controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                controller.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
            ]
        }
        NSLayoutConstraint.activate(endConstraints)
        controller.didMove(toParent: self)
        endController = controller
        view.setNeedsLayout()
    }

    private func updateEndInsets(_ insets: UIEdgeInsets) {
        for (constraint, value) in zip(endConstraints, [insets.top, -insets.bottom, insets.left, -insets.right]) {
            if constraint.constant != value { constraint.constant = value }
        }
    }

    func clear() {
        imageView.image = nil
        imageView.alpha = 1
        pairedImageView.image = nil
        pairedImageView.alpha = 1
        errorText = nil
        pairedErrorText = nil
        scroll.setZoomScale(1, animated: false)
        endController?.willMove(toParent: nil)
        endController?.view.removeFromSuperview()
        endController?.removeFromParent()
        endController = nil
        endConstraints.removeAll()
        message.text = nil
        onTap = { _ in }
        onImageGeometryChanged = {}
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { onParentZoom == nil ? contentView : nil }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if continuousVertical { updateVerticalInput() }
        onZoomChanged(isZoomed)
        onImageGeometryChanged()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { onImageGeometryChanged() }

    private func updateVerticalInput() {
        // 等倍では内側のスクロールが指を受け取らず、親の縦送りへ渡す。拡大は維持する。
        scroll.isScrollEnabled = isZoomed
        scroll.pinchGestureRecognizer?.isEnabled = onParentZoom == nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard view.bounds.width > 0 else { return false }
        let point = touch.location(in: view)
        let center = ReaderTapMode.isCenter(parentTapFraction?(point) ?? Double(point.x / view.bounds.width))
        return gestureRecognizer === edgeTap ? !center && !continuousVertical : center
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard view.bounds.width > 0 else { return }
        let point = gesture.location(in: view)
        onTap(parentTapFraction?(point) ?? Double(point.x / view.bounds.width))
    }

    @objc private func zoom(_ gesture: UITapGestureRecognizer) {
        guard imageView.image != nil || pairedImageView.image != nil else { return }
        if let onParentZoom { onParentZoom(gesture.location(in: view)); return }
        if isZoomed {
            scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            let point = gesture.location(in: contentView)
            let size = CGSize(width: scroll.bounds.width / 2, height: scroll.bounds.height / 2)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                  width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

}
