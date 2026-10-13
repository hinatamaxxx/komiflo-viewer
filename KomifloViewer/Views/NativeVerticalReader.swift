import SwiftUI
import UIKit

/// 表示するページだけを再利用し、取得・描画は横読みと同じセッションへ任せる。
struct NativeVerticalReader: UIViewControllerRepresentable {
    let document: NativeReaderDocument
    let includesEndPage: Bool
    let images: [Int: UIImage]
    let errors: [Int: String]
    let previewPages: Set<Int>
    @Binding var page: Int
    let navigationBlocked: Bool
    let tapMode: ReaderTapMode
    let onVisiblePages: (Set<Int>) -> Void
    let onTap: () -> Void
    let onUserTurn: () -> Void
    let onBeforeFirst: () -> Void
    let onAfterLast: () -> Void
    var canMoveBefore = true
    var canMoveAfter = true
    let endPage: AnyView
    var endSwipeMotion: ReaderEndSwipeMotion?
    var endContentInsets: UIEdgeInsets?
    var startPage: AnyView = AnyView(Color.clear)
    var startSwipeMotion: ReaderEndSwipeMotion?
    var startHintExtension: CGFloat = 0
    var headerAppearance: ReaderHeaderAppearance?
    var headerCenterY: CGFloat = 0
    var imageGeometry: ReaderImageGeometry?

    func makeUIViewController(context: Context) -> NativeVerticalController {
        let controller = NativeVerticalController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: NativeVerticalController, context: Context) {
        controller.onPageChange = { [weak controller] value in
            DispatchQueue.main.async {
                guard controller?.currentPage == value else { return }
                if page != value { page = value }
            }
        }
        controller.onTap = onTap
        controller.onUserTurn = onUserTurn
        controller.onBeforeFirst = onBeforeFirst
        controller.onAfterLast = onAfterLast
        controller.canMoveBefore = canMoveBefore
        controller.canMoveAfter = canMoveAfter
        controller.endSwipeMotion = endSwipeMotion
        controller.endContentInsets = endContentInsets
        controller.startPage = startPage
        controller.startSwipeMotion = startSwipeMotion
        controller.startHintExtension = startHintExtension
        controller.headerAppearance = headerAppearance
        controller.headerCenterY = headerCenterY
        controller.imageGeometry = imageGeometry
        controller.tapMode = tapMode
        controller.onVisiblePages = { [weak controller] pages in
            DispatchQueue.main.async {
                guard controller?.reportedPages == pages else { return }
                onVisiblePages(pages)
            }
        }
        controller.blocked = navigationBlocked
        controller.endPage = endPage
        controller.configure(document: document, includesEnd: includesEndPage, page: page,
                             images: images, errors: errors, previews: previewPages)
    }

    static func dismantleUIViewController(_ controller: NativeVerticalController, coordinator: ()) {
        controller.clear()
    }
}

final class NativeVerticalController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    var onPageChange: (Int) -> Void = { _ in }
    var onTap: () -> Void = {}
    var onUserTurn: () -> Void = {}
    var onBeforeFirst: () -> Void = {}
    var onAfterLast: () -> Void = {}
    var canMoveBefore = true
    var canMoveAfter = true
    var endSwipeMotion: ReaderEndSwipeMotion?
    var endContentInsets: UIEdgeInsets?
    var startPage = AnyView(Color.clear)
    var startSwipeMotion: ReaderEndSwipeMotion?
    var startHintExtension: CGFloat = 0
    var headerAppearance: ReaderHeaderAppearance?
    var headerCenterY: CGFloat = 0
    var imageGeometry: ReaderImageGeometry?
    private var startController: UIHostingController<AnyView>?
    var onVisiblePages: (Set<Int>) -> Void = { _ in }
    private(set) var reportedPages: Set<Int> = []
    var tapMode = ReaderTapMode.leftForward
    var endPage = AnyView(Color.clear)
    var blocked = false { didSet { updateScrolling() } }
    private(set) var currentPage = 1
    private let layout = NativeVerticalLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private lazy var startPullGesture = UIPanGestureRecognizer(target: self, action: #selector(startPulled(_:)))
    private var document: NativeReaderDocument?
    private var includesEnd = false
    private var images: [Int: UIImage] = [:]
    private var errors: [Int: String] = [:]
    private var previews: Set<Int> = []
    private var ratios: [Int: CGFloat] = [:]
    private var layingOut = false
    private var width: CGFloat = 0
    private var zoomAnimating = false
    private var pendingGeometry = false
    private var pendingSelection: Int?
    private var beganAtEnd = false
    private var endPullOrigin: CGFloat?
    private(set) var zoomScale: CGFloat = 1
    private var lastPage: Int { (document?.pages.count ?? 0) + (includesEnd ? 1 : 0) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.accessibilityIdentifier = "native-vertical-reader"
        collection.backgroundColor = .black
        collection.contentInsetAdjustmentBehavior = .never
        collection.bounces = false
        collection.showsVerticalScrollIndicator = false
        collection.dataSource = self
        collection.delegate = self
        collection.panGestureRecognizer.addTarget(self, action: #selector(boundaryPulled(_:)))
        startPullGesture.delegate = self
        startPullGesture.maximumNumberOfTouches = 1
        collection.addGestureRecognizer(startPullGesture)
        // 先頭を下へ引っ張り始めた操作は、指を離すまで通常スクロールへ渡さない。
        collection.panGestureRecognizer.require(toFail: startPullGesture)
        collection.register(NativeVerticalCell.self, forCellWithReuseIdentifier: "page")
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        collection.addGestureRecognizer(pinch)
        view.addSubview(collection)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !zoomAnimating else { return }
        // 引っ張り中のtransformを保ち、frameの再設定で画像の位置を跳ねさせない。
        if collection.bounds.size != view.bounds.size {
            var bounds = collection.bounds
            bounds.size = view.bounds.size
            collection.bounds = bounds
        }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if collection.center != center { collection.center = center }
        if width != view.bounds.width {
            width = view.bounds.width
            layingOut = true
            updateLayout()
            collection.layoutIfNeeded()
            move(to: currentPage)
            layingOut = false
        }
        reportVisiblePages()
    }

    func configure(document: NativeReaderDocument, includesEnd: Bool, page: Int,
                   images: [Int: UIImage], errors: [Int: String], previews: Set<Int>) {
        loadViewIfNeeded()
        let changed = self.document?.comicID != document.comicID || self.includesEnd != includesEnd
        if self.document?.comicID != document.comicID { clear() }
        let anchor = collection.indexPathForItem(at: CGPoint(x: collection.bounds.midX, y: collection.contentOffset.y + 1))
        let oldTop = anchor.flatMap { layout.layoutAttributesForItem(at: $0)?.frame.minY }
        let offset = oldTop.map { collection.contentOffset.y - $0 } ?? 0
        self.document = document
        self.includesEnd = includesEnd
        self.images = images
        self.errors = errors
        self.previews = previews
        var resized = pendingGeometry
        pendingGeometry = false
        for (index, source) in document.pages.enumerated() {
            let number = index + 1
            let ratio: CGFloat?
            if let sourceLayout = source.layout {
                ratio = CGFloat(sourceLayout.height) / CGFloat(sourceLayout.width)
            } else if let image = images[number], image.size.width > 0 {
                ratio = image.size.height / image.size.width
            } else { ratio = nil }
            if let ratio, ratios[number] != ratio { ratios[number] = ratio; resized = true }
        }
        if zoomAnimating {
            pendingGeometry = pendingGeometry || changed || resized
            if page != currentPage { pendingSelection = page }
            for cell in collection.visibleCells.compactMap({ $0 as? NativeVerticalCell }) {
                if let index = collection.indexPath(for: cell) { display(cell, number: index.item + 1) }
            }
            return
        }
        layingOut = true
        if changed || resized { updateLayout() }
        if changed { collection.reloadData() }
        collection.layoutIfNeeded()
        if changed || page != currentPage {
            currentPage = min(max(1, page), max(1, lastPage))
            move(to: currentPage)
        } else if resized, let anchor, let top = layout.layoutAttributesForItem(at: anchor)?.frame.minY {
            collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: top + offset), animated: false)
        }
        for cell in collection.visibleCells.compactMap({ $0 as? NativeVerticalCell }) {
            if let index = collection.indexPath(for: cell) { display(cell, number: index.item + 1) }
        }
        layingOut = false
        updateStartHint()
        updateScrolling()
        reportVisiblePages()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { lastPage }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! NativeVerticalCell
        guard let document else { return cell }
        let number = indexPath.item + 1
        let controller = NativeImagePageController(comicID: document.comicID, number: number)
        controller.continuousVertical = true
        controller.fillsContinuousPage = true
        controller.parentTapFraction = { [weak self, weak controller] point in
            guard let self, let controller else { return 0.5 }
            let contentPoint = controller.view.convert(point, to: self.collection)
            return Double((contentPoint.x - self.collection.contentOffset.x) / max(1, self.collection.bounds.width))
        }
        controller.onParentZoom = { [weak self, weak controller] point in
            guard let self, let controller, !self.blocked else { return }
            let contentPoint = controller.view.convert(point, to: self.collection)
            let viewportPoint = CGPoint(x: contentPoint.x - self.collection.contentOffset.x,
                                        y: contentPoint.y - self.collection.contentOffset.y)
            self.onUserTurn()
            self.setZoomScale(self.zoomScale > 1.01 ? 1 : 2, around: viewportPoint,
                              animated: !UIAccessibility.isReduceMotionEnabled)
        }
        controller.onTap = { [weak self] _ in
            guard let self, !self.blocked else { return }
            self.onTap()
        }
        addChild(controller)
        cell.attach(controller)
        controller.didMove(toParent: self)
        display(cell, number: number)
        return cell
    }

    private func display(_ cell: NativeVerticalCell, number: Int) {
        let isEnd = number > (document?.pages.count ?? 0)
        cell.controller?.display(image: images[number], error: errors[number], isEnd: isEnd, isPreview: previews.contains(number))
        if isEnd { cell.controller?.displayEnd(endPage, insets: endContentInsets) }
    }

    private func updateLayout() {
        layout.displayScale = max(1, view.traitCollection.displayScale)
        let width = (max(1, collection.bounds.width) * zoomScale * layout.displayScale).rounded() / layout.displayScale
        let firstHeight = max(1, collection.bounds.width) * (ratios[1] ?? 1.5)
        layout.leadingSpace = max(0, (collection.bounds.height - firstHeight) / 2) * zoomScale
        layout.itemSizes = (0..<lastPage).map { index in
            let height = index + 1 > (document?.pages.count ?? 0)
                ? max(1, collection.bounds.height) * zoomScale : width * (ratios[index + 1] ?? 1.5)
            return CGSize(width: width, height: height)
        }
        layoutStartHint()
    }

    private func updateStartHint() {
        guard startSwipeMotion != nil else { return }
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
        // 画像の配置は変えず、文字を引っ張れる領域だけ下へ広げる。
        startController?.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width,
                                            height: layout.leadingSpace + startHintExtension)
    }

    @objc private func startPulled(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view).y
        switch gesture.state {
        case .began:
            onUserTurn()
        case .changed:
            guard canMoveBefore, !blocked, !zoomAnimating, document != nil else { return }
            startSwipeMotion?.pull(translation: max(0, translation), threshold: min(collection.bounds.width * 0.2, 64))
        case .ended, .cancelled, .failed:
            startSwipeMotion?.reset(animated: true)
            guard gesture.state == .ended, canMoveBefore, !blocked, !zoomAnimating,
                  document != nil, translation > min(64, collection.bounds.height * 0.2) else { return }
            onBeforeFirst()
        default: break
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard !blocked else { return }
        if gesture.state == .began { onUserTurn() }
        if gesture.state == .began || gesture.state == .changed {
            let point = gesture.location(in: collection)
            setZoomScale(zoomScale * gesture.scale,
                         around: CGPoint(x: point.x - collection.contentOffset.x, y: point.y - collection.contentOffset.y))
            gesture.scale = 1
        }
    }

    // ページごとの拡大をせず、列全体の寸法と指の下の位置を一緒に更新する。
    func setZoomScale(_ requested: CGFloat, around point: CGPoint, animated: Bool = false) {
        guard requested.isFinite, !zoomAnimating else { return }
        let scale = min(4, max(1, requested))
        let factor = scale / zoomScale
        let anchor = CGPoint(x: (collection.contentOffset.x + point.x) * factor - point.x,
                             y: (collection.contentOffset.y + point.y) * factor - point.y)
        if animated {
            let previousOffset = collection.contentOffset
            let target = CGPoint(x: min(max(0, anchor.x), max(0, collection.contentSize.width * factor - collection.bounds.width)),
                                 y: min(max(0, anchor.y), max(0, collection.contentSize.height * factor - collection.bounds.height)))
            // 戻った先で見えるページまで先に揃え、列の寸法は演出の開始前に確定する。
            let targetRect = CGRect(x: target.x / factor, y: target.y / factor,
                                 width: collection.bounds.width / factor, height: collection.bounds.height / factor)
            layout.retainedPages = Set((layout.layoutAttributesForElements(in: collection.bounds.union(targetRect)) ?? [])
                .map { $0.indexPath.item })
            let preparedPages = Set(layout.retainedPages.map { $0 + 1 })
            if preparedPages != reportedPages { reportedPages = preparedPages; onVisiblePages(preparedPages) }
            zoomAnimating = true
            updateScrolling()
            UIView.performWithoutAnimation {
                applyZoom(scale, anchor: target)
                restoreZoomStart(factor: factor, previousOffset: previousOffset)
                layoutPageContents()
            }
            // 始点は逆変換で保ち、同じ列を等倍の座標へ戻す。終了時にページを入れ替えない。
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut], animations: {
                self.collection.transform = .identity
            }, completion: { [weak self] _ in
                guard let self, self.zoomAnimating, self.document != nil else { return }
                UIView.performWithoutAnimation {
                    self.collection.transform = .identity
                    self.collection.clipsToBounds = true
                }
                self.zoomAnimating = false
                self.layout.retainedPages.removeAll()
                self.layout.invalidateLayout()
                if self.pendingGeometry || self.pendingSelection != nil, let document = self.document {
                    let page = self.pendingSelection ?? self.currentPage
                    self.pendingSelection = nil
                    self.configure(document: document, includesEnd: self.includesEnd, page: page,
                                   images: self.images, errors: self.errors, previews: self.previews)
                }
                self.collection.layoutIfNeeded()
                self.updateScrolling()
                self.scrollViewDidScroll(self.collection)
            })
        } else { applyZoom(scale, anchor: anchor) }
    }

    private func restoreZoomStart(factor: CGFloat, previousOffset: CGPoint) {
        let inverse: CGFloat = 1 / factor
        let centerShiftX: CGFloat = (inverse - 1) * collection.bounds.width / 2
        let centerShiftY: CGFloat = (inverse - 1) * collection.bounds.height / 2
        let translationX = centerShiftX + collection.contentOffset.x * inverse - previousOffset.x
        let translationY = centerShiftY + collection.contentOffset.y * inverse - previousOffset.y
        collection.clipsToBounds = false
        collection.transform = CGAffineTransform(translationX: translationX, y: translationY).scaledBy(x: inverse, y: inverse)
    }

    private func applyZoom(_ scale: CGFloat, anchor: CGPoint) {
        zoomScale = scale
        layingOut = true
        updateLayout()
        collection.layoutIfNeeded()
        let size = collection.contentSize
        collection.setContentOffset(CGPoint(x: min(max(0, anchor.x), max(0, size.width - collection.bounds.width)),
                                            y: min(max(0, anchor.y), max(0, size.height - collection.bounds.height))), animated: false)
        // 枠と画像の配置を同じアニメーションの中で確定する。
        layoutPageContents()
        layingOut = false
        scrollViewDidScroll(collection)
        updateHeaderAppearance()
    }

    private func layoutPageContents() {
        for cell in collection.visibleCells.compactMap({ $0 as? NativeVerticalCell }) {
            cell.contentView.layoutIfNeeded()
            cell.controller?.view.layoutIfNeeded()
        }
    }

    private func reportVisiblePages() {
        guard !zoomAnimating else { return }
        updateHeaderAppearance()
        let pages = Set((layout.layoutAttributesForElements(in: collection.bounds) ?? [])
            .filter { $0.frame.intersects(collection.bounds) }.map { $0.indexPath.item + 1 })
        guard pages != reportedPages else { return }
        reportedPages = pages
        onVisiblePages(pages)
    }

    private func updateHeaderAppearance() {
        if let imageGeometry {
            if let document, currentPage <= document.pages.count,
               let item = layout.layoutAttributesForItem(at: IndexPath(item: currentPage - 1, section: 0)) {
                imageGeometry.update(frame: collection.convert(item.frame, to: view))
            } else {
                imageGeometry.update(frame: .null)
            }
        }
        guard let headerAppearance else { return }
        guard let document, !document.pages.isEmpty,
              let last = layout.layoutAttributesForItem(at: IndexPath(item: document.pages.count - 1, section: 0)) else {
            headerAppearance.update(isOverComic: false)
            return
        }
        // 画像の中身を調べず、連続した画像の列とアイコン中央の位置だけで判断する。
        let point = view.convert(CGPoint(x: view.bounds.midX, y: headerCenterY), to: collection)
        let comicFrame = CGRect(x: last.frame.minX, y: layout.leadingSpace,
                                width: last.frame.width, height: last.frame.maxY - layout.leadingSpace)
        headerAppearance.update(isOverComic: comicFrame.contains(point))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === startPullGesture || otherGestureRecognizer === startPullGesture { return false }
        return otherGestureRecognizer === collection.panGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === startPullGesture else { return true }
        let velocity = startPullGesture.velocity(in: view)
        return canMoveBefore && !blocked && !zoomAnimating && zoomScale <= 1.01 && document != nil
            && collection.contentOffset.y <= 1 && velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        let bottom = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        beganAtEnd = !blocked && canMoveAfter && zoomScale <= 1.01 && includesEnd && currentPage == lastPage && scrollView.contentOffset.y >= bottom - 1
        endPullOrigin = beganAtEnd ? 0 : nil
        if !blocked { onUserTurn() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        defer { beganAtEnd = false; endPullOrigin = nil }
        guard !blocked, !zoomAnimating, zoomScale <= 1.01 else { return }
        let threshold = min(64, scrollView.bounds.height * 0.2)
        let bottom = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let translation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        if beganAtEnd, scrollView.contentOffset.y >= bottom - 1,
                translation - (endPullOrigin ?? 0) < -threshold || scrollView.contentOffset.y > bottom + threshold { onAfterLast() }
    }

    @objc private func boundaryPulled(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            endSwipeMotion?.reset(animated: true)
            startSwipeMotion?.reset(animated: true)
        }
        guard !blocked, !zoomAnimating, zoomScale <= 1.01 else { return }
        switch gesture.state {
        case .began: scrollViewWillBeginDragging(collection)
        case .changed:
            let translation = gesture.translation(in: view).y
            let bottom = max(0, collection.contentSize.height - collection.bounds.height)
            if !beganAtEnd, canMoveAfter, includesEnd, currentPage == lastPage, collection.contentOffset.y >= bottom - 1 {
                // 読み終わりが横読みと同じ位置へ着いた後の移動だけ、案内を引っ張る。
                beganAtEnd = true
                endPullOrigin = translation
            } else if beganAtEnd, collection.contentOffset.y < bottom - 1 {
                beganAtEnd = false
                endPullOrigin = nil
            }
            if beganAtEnd && translation < 0 {
                endSwipeMotion?.pull(translation: min(0, translation - (endPullOrigin ?? 0)),
                                     threshold: min(collection.bounds.width * 0.2, 64))
            } else {
                endSwipeMotion?.reset()
                startSwipeMotion?.reset()
            }
        default: break
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !layingOut, !blocked, !zoomAnimating, lastPage > 0 else { return }
        reportVisiblePages()
        // 画面の中央にあるページを進捗と先読みに使う。監視タイマーは使わない。
        let point = CGPoint(x: collection.bounds.midX, y: collection.contentOffset.y + collection.bounds.height / 2)
        guard let index = collection.indexPathForItem(at: point) else { return }
        let number = index.item + 1
        if currentPage != number { currentPage = number; onPageChange(number) }
    }

    private func select(_ number: Int) {
        guard number >= 1, number <= lastPage else { return }
        currentPage = number
        layingOut = true
        move(to: number)
        layingOut = false
        onPageChange(number)
    }

    private func move(to number: Int) {
        guard number > 0, number <= lastPage, collection.bounds.width > 0 else { return }
        collection.scrollToItem(at: IndexPath(item: number - 1, section: 0), at: .centeredVertically, animated: false)
    }

    private func updateScrolling() {
        guard isViewLoaded else { return }
        collection.isScrollEnabled = !blocked && !zoomAnimating
        collection.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.forEach { $0.isEnabled = !blocked && !zoomAnimating }
        collection.visibleCells.forEach { $0.isUserInteractionEnabled = !blocked }
    }

    func clear() {
        startPullGesture.isEnabled = false
        startPullGesture.isEnabled = true
        endSwipeMotion?.reset()
        startSwipeMotion?.reset()
        startController?.willMove(toParent: nil)
        startController?.view.removeFromSuperview()
        startController?.removeFromParent()
        startController = nil
        collection.visibleCells.compactMap { $0 as? NativeVerticalCell }.forEach { $0.detach() }
        images.removeAll(); errors.removeAll(); previews.removeAll(); ratios.removeAll()
        document = nil
        zoomScale = 1
        zoomAnimating = false
        collection.layer.removeAllAnimations()
        collection.transform = .identity
        collection.clipsToBounds = true
        layout.retainedPages.removeAll()
        layout.itemSizes = []
        collection.reloadData()
        reportedPages.removeAll()
        pendingGeometry = false
        pendingSelection = nil
        beganAtEnd = false
        endPullOrigin = nil
    }
}

/// 拡大時も画面内のセルだけを再利用する、ページが隙間なくつながる1列の配置。
private final class NativeVerticalLayout: UICollectionViewLayout {
    var retainedPages: Set<Int> = []
    var displayScale: CGFloat = 1 { didSet { if displayScale != oldValue { invalidateLayout() } } }
    var leadingSpace: CGFloat = 0 { didSet { if leadingSpace != oldValue { invalidateLayout() } } }
    var itemSizes: [CGSize] = [] { didSet { invalidateLayout() } }
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var size = CGSize.zero
    override func prepare() {
        super.prepare()
        guard attributes.count != itemSizes.count || size == .zero else { return }
        var top = leadingSpace
        attributes = itemSizes.enumerated().map { index, itemSize in
            let item = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            // 隣り合うページは同じ丸めた境界を使い、1ピクセル未満の黒い隙間を作らない。
            let start = (top * displayScale).rounded() / displayScale
            top += itemSize.height
            let end = (top * displayScale).rounded() / displayScale
            item.frame = CGRect(x: 0, y: start, width: itemSize.width, height: end - start)
            return item
        }
        size = CGSize(width: itemSizes.first?.width ?? 0, height: (top * displayScale).rounded() / displayScale)
    }
    override func invalidateLayout() { size = .zero; super.invalidateLayout() }
    override var collectionViewContentSize: CGSize { size }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) || retainedPages.contains($0.indexPath.item) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }
}

private final class NativeVerticalCell: UICollectionViewCell {
    private(set) var controller: NativeImagePageController?
    func attach(_ controller: NativeImagePageController) {
        detach()
        self.controller = controller
        controller.view.frame = contentView.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(controller.view)
    }
    func detach() {
        controller?.clear()
        controller?.willMove(toParent: nil)
        controller?.view.removeFromSuperview()
        controller?.removeFromParent()
        controller = nil
    }
    override func prepareForReuse() { super.prepareForReuse(); detach() }
}
