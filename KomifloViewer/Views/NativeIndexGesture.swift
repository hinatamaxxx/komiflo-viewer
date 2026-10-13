import SwiftUI
import UIKit

/// 縦はパネルを閉じる操作、横は中のスクロール。認識する前に担当を決める。
struct NativeIndexGestureHost<Content: View>: UIViewControllerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> NativeIndexGestureController<Content> {
        let controller = NativeIndexGestureController(content: content())
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: NativeIndexGestureController<Content>, context: Context) {
        controller.host.rootView = content()
        update(controller)
    }

    private func update(_ controller: NativeIndexGestureController<Content>) {
        controller.onChanged = onChanged
        controller.onEnded = onEnded
        controller.onCancelled = onCancelled
    }
}

final class NativeIndexGestureController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    let host: UIHostingController<Content>
    var onChanged: (CGFloat) -> Void = { _ in }
    var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onCancelled: () -> Void = {}
    private let pan = UIPanGestureRecognizer()
    private let registered = NSHashTable<UIPanGestureRecognizer>.weakObjects()

    init(content: Content) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        pan.delegate = self
        pan.addTarget(self, action: #selector(dragged(_:)))
        view.addGestureRecognizer(pan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        registerRows(in: host.view)
    }

    private func registerRows(in root: UIView) {
        if let scroll = root as? UIScrollView, !registered.contains(scroll.panGestureRecognizer) {
            // 縦と判定した後に認識器を止めず、横の列は縦の判定が終わるまで待つ。
            scroll.panGestureRecognizer.require(toFail: pan)
            registered.add(scroll.panGestureRecognizer)
        }
        root.subviews.forEach { registerRows(in: $0) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: view.window)
        return velocity.y > abs(velocity.x)
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        // 動くパネルではなく、動かない画面の座標で指の移動を測る。
        let distance = max(0, recognizer.translation(in: view.window).y)
        switch recognizer.state {
        case .began, .changed: onChanged(distance)
        case .ended: onEnded(distance, distance + recognizer.velocity(in: view.window).y * 0.15)
        case .cancelled, .failed: onCancelled()
        default: break
        }
    }
}
