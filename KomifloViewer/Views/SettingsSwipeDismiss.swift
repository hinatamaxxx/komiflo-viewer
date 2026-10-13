import SwiftUI
import UIKit

/// 設定一覧のスクロールより先に、先頭からの下スワイプを判定する。
struct SettingsSwipeDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        SettingsDismissGesture(content: content, environment: environment, reduceMotion: reduceMotion,
                               finished: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        })
        .ignoresSafeArea()
    }
}

private struct SettingsDismissGesture<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let environment: EnvironmentValues
    let reduceMotion: Bool
    let finished: () -> Void

    func makeCoordinator() -> ScreenDismissCoordinator {
        ScreenDismissCoordinator(reduceMotion: reduceMotion, enabled: true, allowsLeadingEdge: false, finished: finished)
    }

    func makeUIViewController(context: Context) -> PanelController {
        let controller = PanelController(rootView: AnyView(content.environment(\.self, environment)))
        controller.loadViewIfNeeded()
        context.coordinator.attach(panel: controller.hosting.view, gestureView: controller.view)
        return controller
    }

    func updateUIViewController(_ controller: PanelController, context: Context) {
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.finished = finished
        controller.hosting.rootView = AnyView(content.environment(\.self, environment))
    }

    static func dismantleUIViewController(_ controller: PanelController, coordinator: ScreenDismissCoordinator) {
        coordinator.detach()
    }

    final class PanelController: UIViewController {
        let hosting: UIHostingController<AnyView>

        init(rootView: AnyView) {
            hosting = UIHostingController(rootView: rootView)
            // 端の余白は親の制約で確保し、移動中の位置から再計算しない。
            hosting.safeAreaRegions = .keyboard
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            let statusBackground = UIView()
            statusBackground.backgroundColor = Theme.uiBackground
            statusBackground.translatesAutoresizingMaskIntoConstraints = false
            statusBackground.isUserInteractionEnabled = false
            view.addSubview(statusBackground)
            let bottomBackground = UIView()
            bottomBackground.backgroundColor = Theme.uiBackground
            bottomBackground.translatesAutoresizingMaskIntoConstraints = false
            bottomBackground.isUserInteractionEnabled = false
            view.addSubview(bottomBackground)
            let viewport = UIView()
            viewport.translatesAutoresizingMaskIntoConstraints = false
            viewport.clipsToBounds = true
            view.addSubview(viewport)
            addChild(hosting)
            let panel = hosting.view!
            panel.backgroundColor = .clear
            panel.clipsToBounds = true
            panel.translatesAutoresizingMaskIntoConstraints = false
            viewport.addSubview(panel)
            // 時計の領域は固定し、設定の描画と移動はその下だけにする。
            NSLayoutConstraint.activate([
                statusBackground.topAnchor.constraint(equalTo: view.topAnchor),
                statusBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                statusBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                statusBackground.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                bottomBackground.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                bottomBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                bottomBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bottomBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                viewport.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                viewport.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                viewport.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                viewport.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                panel.topAnchor.constraint(equalTo: viewport.topAnchor),
                panel.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            ])
            hosting.didMove(toParent: self)
        }
    }

}

/// 作家ページは外枠を固定し、その中の表示だけを一体で移動する。
struct ArtistSwipeDismiss: ViewModifier {
    let enabled: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ArtistDismissGesture(content: content, environment: environment,
                                 insets: geometry.safeAreaInsets, reduceMotion: reduceMotion,
                                 enabled: enabled) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dismiss() }
            }
            .ignoresSafeArea(.container)
        }
    }
}

private struct ArtistDismissGesture<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let environment: EnvironmentValues
    let insets: EdgeInsets
    let reduceMotion: Bool
    let enabled: Bool
    let finished: () -> Void

    private var rootView: AnyView {
        // 動かない外枠の余白だけを使い、移動先の時計領域を再適用しない。
        AnyView(content.environment(\.self, environment).safeAreaPadding(insets))
    }

    func makeCoordinator() -> ScreenDismissCoordinator {
        let coordinator = ScreenDismissCoordinator(reduceMotion: reduceMotion, enabled: enabled,
                                                  allowsLeadingEdge: true, finished: finished)
        coordinator.clipsToScreenCorners = true
        coordinator.allowsScrollHandoff = true
        return coordinator
    }

    func makeUIViewController(context: Context) -> PanelController {
        let controller = PanelController(rootView: rootView)
        controller.loadViewIfNeeded()
        context.coordinator.attach(panel: controller.panel, gestureView: controller.view)
        return controller
    }

    func updateUIViewController(_ controller: PanelController, context: Context) {
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.enabled = enabled
        context.coordinator.finished = finished
        controller.hosting.rootView = rootView
    }

    static func dismantleUIViewController(_ controller: PanelController, coordinator: ScreenDismissCoordinator) {
        coordinator.detach()
    }

    final class PanelController: UIViewController {
        let hosting: UIHostingController<AnyView>
        let panel = UIView()

        init(rootView: AnyView) {
            hosting = UIHostingController(rootView: rootView)
            hosting.safeAreaRegions = .keyboard
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            panel.backgroundColor = .clear
            panel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel)
            addChild(hosting)
            let page = hosting.view!
            page.backgroundColor = .clear
            page.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(page)
            // 移動は専用のpanelだけ。表示ホストと外枠の位置・寸法は書き換えない。
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: view.topAnchor),
                panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                page.topAnchor.constraint(equalTo: panel.topAnchor),
                page.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            ])
            hosting.didMove(toParent: self)
        }
    }
}

private final class ScreenDismissCoordinator: NSObject, UIGestureRecognizerDelegate {
    var reduceMotion: Bool
    var enabled: Bool
    var scrollOnly = false
    var clipsToScreenCorners = false
    var allowsScrollHandoff = false
    private var restoreCorners: (() -> Void)?
    private var scrollPin: NSKeyValueObservation?
    private var pinningScrollOffset = false
    let allowsLeadingEdge: Bool
    var finished: () -> Void
    var pan: UIPanGestureRecognizer?
    var edge: UIScreenEdgePanGestureRecognizer?
    private var horizontal = false
    private var touchedScrolls: [UIScrollView] = []
    weak var panel: UIView?
    weak var scroll: UIScrollView?
    private var origin: CGFloat = 0
    private var baseTransform = CGAffineTransform.identity
    private var animator: UIViewPropertyAnimator?
    private var closing = false
    private var moved = false

    init(reduceMotion: Bool, enabled: Bool, allowsLeadingEdge: Bool, finished: @escaping () -> Void) {
        self.reduceMotion = reduceMotion
        self.enabled = enabled
        self.allowsLeadingEdge = allowsLeadingEdge
        self.finished = finished
    }

    func attach(panel: UIView, gestureView: UIView) {
        guard self.panel !== panel else { return }
        detach()
        self.panel = panel
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = self
        gestureView.addGestureRecognizer(gesture)
        pan = gesture
        if allowsLeadingEdge {
            let edgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned(_:)))
            edgeGesture.edges = .left
            edgeGesture.delegate = self
            gestureView.addGestureRecognizer(edgeGesture)
            gesture.require(toFail: edgeGesture)
            edge = edgeGesture
        }
    }

    func detach() {
        animator?.stopAnimation(true)
        animator = nil
        // 閉じる途中の画面を元の位置へ戻してから撤去しない。
        if moved, !closing, let panel { panel.transform = baseTransform }
        if let pan { pan.view?.removeGestureRecognizer(pan) }
        pan = nil
        if let edge { edge.view?.removeGestureRecognizer(edge) }
        edge = nil
        finishMovement(restoringCorners: !closing)
        panel = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let panel, panel.bounds.contains(touch.location(in: panel)) else { return false }
        // 戻す演出中の新しいタッチで、保持中の一覧を上書きしない。
        guard enabled, !closing, animator == nil else { return false }
        scroll = nil
        touchedScrolls = []
        var touched = touch.view
        while let view = touched, view !== gestureRecognizer.view {
            // スイッチやスライダーの操作は、閉じるスワイプにしない。
            if view is UIControl { return false }
            if let list = view as? UIScrollView {
                touchedScrolls.append(list)
                // 作家の一覧は横ページの外側に縦スクロールがある。
                if scroll == nil || list.contentSize.height > list.bounds.height {
                    scroll = list
                }
            }
            touched = view.superview
        }
        return !scrollOnly || scroll != nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !closing, animator == nil, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        guard enabled else { return false }
        if gestureRecognizer === edge {
            let velocity = pan.velocity(in: pan.view?.window)
            return velocity.x > abs(velocity.y)
        }
        if allowsScrollHandoff, scroll != nil {
            // 上向きから始まっても追跡を続け、先頭へ戻るまでは一覧に任せる。
            return SettingsDismissMotion.canTrackScroll(velocity: pan.velocity(in: pan.view?.window))
        }
        // 上部バーには一覧がないので、下方向だけで判定する。
        return SettingsDismissMotion.canBegin(offset: scroll?.contentOffset.y ?? 0, top: -(scroll?.adjustedContentInset.top ?? 0),
            velocity: pan.velocity(in: pan.view?.window))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if allowsScrollHandoff, gestureRecognizer === pan { return false }
        // 縦一覧と内側の横ページの両方に対し、方向を決めてから操作を渡す。
        return touchedScrolls.contains { otherGestureRecognizer === $0.panGestureRecognizer }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard allowsScrollHandoff else { return false }
        let other = gestureRecognizer === pan ? otherGestureRecognizer : gestureRecognizer
        return (gestureRecognizer === pan || otherGestureRecognizer === pan)
            && touchedScrolls.contains { other === $0.panGestureRecognizer }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard !closing, let host = panel else { return }
        let isHorizontal = pan === edge
        let point = pan.translation(in: pan.view?.window)
        let translation = isHorizontal ? point.x : point.y
        switch pan.state {
        case .began:
            horizontal = isHorizontal
            if allowsScrollHandoff, !horizontal, scroll != nil {
                handOffScrollIfNeeded(host: host, pan: pan, translation: translation)
            } else {
                beginMovement(host: host, origin: translation)
            }
        case .changed:
            if returnToScrollIfNeeded(host: host, pan: pan, translation: translation) { return }
            if !moved, allowsScrollHandoff, !horizontal {
                handOffScrollIfNeeded(host: host, pan: pan, translation: translation)
            }
            guard moved else { return }
            // SwiftUIへ移動量を返さず、ナビと一覧を一体で動かす。
            let distance = SettingsDismissMotion.distance(translation: translation, origin: origin)
            host.transform = baseTransform.translatedBy(x: horizontal ? distance : 0, y: horizontal ? 0 : distance)
        case .ended, .cancelled:
            guard moved else { return }
            let distance = SettingsDismissMotion.distance(translation: translation, origin: origin)
            closing = SettingsDismissMotion.shouldClose(distance: distance, velocity: horizontal ? pan.velocity(in: host.window).x : pan.velocity(in: host.window).y,
                cancelled: pan.state == .cancelled)
            settle(host: host)
        default: break
        }
    }

    private func beginMovement(host: UIView, origin: CGFloat) {
        self.origin = origin
        if clipsToScreenCorners { configureScreenCorners(host) }
        baseTransform = host.transform
        moved = true
    }

    private func handOffScrollIfNeeded(host: UIView, pan: UIPanGestureRecognizer, translation: CGFloat) {
        guard !moved, let scroll else { return }
        let top = -scroll.adjustedContentInset.top
        guard SettingsDismissMotion.canBegin(offset: scroll.contentOffset.y, top: top,
                                             velocity: pan.velocity(in: host.window)) else { return }
        let origin = SettingsDismissMotion.handoffOrigin(translation: translation, offset: scroll.contentOffset.y, top: top)
        beginMovement(host: host, origin: origin)
        // 認識を止めず、閉じる間だけ一覧の位置を保つ。
        scrollPin = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.pinScrollToTop()
        }
        pinScrollToTop()
        host.transform = baseTransform.translatedBy(x: 0, y: SettingsDismissMotion.distance(translation: translation, origin: origin))
    }

    private func pinScrollToTop() {
        guard scrollPin != nil, !pinningScrollOffset, let scroll else { return }
        let top = -scroll.adjustedContentInset.top
        guard scroll.contentOffset.y != top else { return }
        pinningScrollOffset = true
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: top), animated: false)
        pinningScrollOffset = false
    }

    private func returnToScrollIfNeeded(host: UIView, pan: UIPanGestureRecognizer, translation: CGFloat) -> Bool {
        guard allowsScrollHandoff, !horizontal, moved, scrollPin != nil, let scroll,
              let remaining = SettingsDismissMotion.scrollReturnDistance(
                translation: translation, origin: origin, velocityY: pan.velocity(in: host.window).y) else { return false }
        host.transform = baseTransform
        finishMovement(restoringCorners: true)
        // 戻り切った境界を越えた分だけ、同じ指の一覧スクロールへ渡す。
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top + remaining), animated: false)
        return true
    }

    private func configureScreenCorners(_ host: UIView) {
        if #available(iOS 26.0, *), let container = host.superview {
            let previousMask = host.mask
            let mask = UIView(frame: host.convert(host.bounds, to: container))
            mask.backgroundColor = .white
            mask.isUserInteractionEnabled = false
            mask.alpha = 0
            mask.cornerConfiguration = .corners(radius: .containerConcentric())
            // 画面本体の角設定は触らず、移動前の位置で専用枠の丸みを解決する。
            container.addSubview(mask)
            mask.layoutIfNeeded()
            let corners = UICornerConfiguration.corners(
                topLeftRadius: .fixed(Double(mask.effectiveRadius(corner: .topLeft))),
                topRightRadius: .fixed(Double(mask.effectiveRadius(corner: .topRight))),
                bottomLeftRadius: .fixed(Double(mask.effectiveRadius(corner: .bottomLeft))),
                bottomRightRadius: .fixed(Double(mask.effectiveRadius(corner: .bottomRight))))
            mask.removeFromSuperview()
            mask.cornerConfiguration = corners
            mask.frame = host.bounds
            mask.alpha = 1
            mask.clipsToBounds = true
            host.mask = mask
            restoreCorners = { [weak host] in
                host?.mask = previousMask
            }
        }
    }

    private func settle(host: UIView) {
        if closing { host.isUserInteractionEnabled = false }
        let target = closing ? baseTransform.translatedBy(x: horizontal ? host.bounds.width : 0,
            y: horizontal ? 0 : host.bounds.height) : baseTransform
        if reduceMotion {
            host.transform = target
            if closing { finished() }
            else { finishMovement(restoringCorners: true) }
            return
        }
        let motion = closing ? UIViewPropertyAnimator(duration: 0.24, curve: .easeOut)
            : UIViewPropertyAnimator(duration: 0.3, dampingRatio: 0.85)
        motion.addAnimations {
            host.transform = target
        }
        motion.addCompletion { [weak self] position in
            guard let self else { return }
            self.animator = nil
            if position == .end, self.closing { self.finished() }
            else { self.finishMovement(restoringCorners: true) }
        }
        animator = motion
        motion.startAnimation()
    }

    private func finishMovement(restoringCorners: Bool) {
        scrollPin?.invalidate()
        scrollPin = nil
        if restoringCorners { restoreCorners?() }
        restoreCorners = nil
        moved = false
    }

}

/// コメントなど、既存の表示画面へ閉じる操作だけを追加する。
struct FullScreenSwipeDismiss: ViewModifier {
    let enabled: Bool
    var scrollOnly = false
    var allowsLeadingEdge = true
    var clipsToScreenCorners = false
    var allowsScrollHandoff = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            ExistingScreenDismissGesture(enabled: enabled, reduceMotion: reduceMotion,
                                         scrollOnly: scrollOnly, allowsLeadingEdge: allowsLeadingEdge,
                                         clipsToScreenCorners: clipsToScreenCorners, allowsScrollHandoff: allowsScrollHandoff) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dismiss() }
            }
        }
    }
}

private struct ExistingScreenDismissGesture: UIViewControllerRepresentable {
    let enabled: Bool
    let reduceMotion: Bool
    let scrollOnly: Bool
    let allowsLeadingEdge: Bool
    let clipsToScreenCorners: Bool
    let allowsScrollHandoff: Bool
    let finished: () -> Void

    func makeCoordinator() -> ScreenDismissCoordinator {
        ScreenDismissCoordinator(reduceMotion: reduceMotion, enabled: enabled,
                                 allowsLeadingEdge: allowsLeadingEdge, finished: finished)
    }

    func makeUIViewController(context: Context) -> AttachmentController {
        let controller = AttachmentController()
        context.coordinator.clipsToScreenCorners = clipsToScreenCorners
        context.coordinator.allowsScrollHandoff = allowsScrollHandoff
        context.coordinator.scrollOnly = scrollOnly
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AttachmentController, context: Context) {
        context.coordinator.clipsToScreenCorners = clipsToScreenCorners
        context.coordinator.allowsScrollHandoff = allowsScrollHandoff
        context.coordinator.scrollOnly = scrollOnly
        context.coordinator.enabled = enabled
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.finished = finished
    }

    static func dismantleUIViewController(_ controller: AttachmentController, coordinator: ScreenDismissCoordinator) {
        coordinator.detach()
    }

    final class AttachmentController: UIViewController {
        weak var coordinator: ScreenDismissCoordinator?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attach()
        }

        private func attach() {
            guard view.window != nil else { return }
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            // 別の画面やウインドウには付けず、この全画面表示のホストだけを動かす。
            guard root !== self, root.presentingViewController != nil else { return }
            coordinator?.attach(panel: root.view, gestureView: root.view)
        }
    }
}
