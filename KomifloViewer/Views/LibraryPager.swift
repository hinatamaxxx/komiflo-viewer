import SwiftUI
import UIKit

/// ライブラリの横めくりの途中の位置。from から to へ fraction（0〜1）だけ進んでいる
struct LibraryPagerMotion<Page: Hashable>: Equatable {
    var from: Page
    var to: Page?
    var fraction: CGFloat
}

/// めくりの途中の位置を、操作の段など表示する部品だけに渡す（親の画面は作り直さない）
final class LibraryMotion<Page: Hashable>: ObservableObject {
    @Published private(set) var value: LibraryPagerMotion<Page>

    init(page: Page) {
        value = LibraryPagerMotion(from: page, to: nil, fraction: 0)
    }

    func update(_ motion: LibraryPagerMotion<Page>) {
        if value != motion { value = motion }
    }
}

/// ライブラリの横めくり。漫画ビューアと同じiOS標準のページめくり（UIPageViewController）を使う。
/// 隣のページは呼び出し側が決める（タブの中は次のページ、端なら隣のタブの最後に見たページ）。
/// page を変えると、そのページを決まった向きに、スワイプと同じ動きでめくる
struct LibraryPager<Page: Hashable>: UIViewControllerRepresentable {
    /// 表示するページ。変えるとそのページへめくる
    let page: Page
    /// 隣のページ（forward が true なら右側）
    let neighbor: (Page, Bool) -> Page?
    /// from から見て to が右側（進む向き）か
    let isForward: (Page, Page) -> Bool
    /// 隣のページの決まり方が変わったとき（ページ数・最後に見たページなど）に変わる値
    let neighborsVersion: AnyHashable
    let content: (Page) -> AnyView
    /// めくり終わって止まったページ
    let onSettle: (Page) -> Void
    /// めくっている途中の位置（上のタブ・操作の段・ページ番号を指に合わせる）
    let onMotion: (LibraryPagerMotion<Page>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.view.backgroundColor = .clear
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        context.coordinator.attach(pager, page: page, environment: context.environment)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.update(parent: self, environment: context.environment)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private(set) var parent: LibraryPager
        private weak var pager: UIPageViewController?
        private var environment = EnvironmentValues()
        private var controllers: [Page: UIHostingController<AnyView>] = [:]
        /// 今止まっているページ
        private var current: Page
        /// 動いている間の行き先（指で動かしているときは次に出てくるページ、押したときは指定のページ）
        private var target: Page?
        private var transitioning = false
        /// 動いている間に指定された次の行き先
        private var queued: Page?
        private var neighborsVersion: AnyHashable
        private var offsetObservation: NSKeyValueObservation?
        private weak var scrollView: UIScrollView?

        init(parent: LibraryPager) {
            self.parent = parent
            current = parent.page
            neighborsVersion = parent.neighborsVersion
        }

        func attach(_ pager: UIPageViewController, page: Page, environment: EnvironmentValues) {
            self.pager = pager
            self.environment = environment
            pager.setViewControllers([controller(for: page)], direction: .forward, animated: false)
            // めくりの位置は内側の横スクロールの位置から読む（スクロールしたときだけ呼ばれる）
            if let scroll = pager.view.subviews.compactMap({ $0 as? UIScrollView }).first {
                scrollView = scroll
                offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                    MainActor.assumeIsolated { self?.scrolled(scroll) }
                }
            }
        }

        func update(parent: LibraryPager, environment: EnvironmentValues) {
            self.parent = parent
            self.environment = environment
            // 一覧の中身（読み込み・★♥など）は各ページが自分で受け取る。呼び出し側の状態だけを渡し直す
            for (page, controller) in controllers {
                controller.rootView = rooted(parent.content(page))
            }
            if parent.page != current, parent.page != target {
                go(to: parent.page)
            } else if parent.neighborsVersion != neighborsVersion, !transitioning,
                      scrollView?.isDragging != true, let pager {
                // 隣のページが変わったので、今のページを置き直してiOSに覚えている隣を捨てさせる（見た目は変わらない）
                neighborsVersion = parent.neighborsVersion
                pager.setViewControllers([controller(for: current)], direction: .forward, animated: false)
                prune()
            }
        }

        private func rooted(_ view: AnyView) -> AnyView {
            AnyView(view.environment(\.self, environment))
        }

        private func controller(for page: Page) -> UIHostingController<AnyView> {
            if let controller = controllers[page] { return controller }
            let controller = UIHostingController(rootView: rooted(parent.content(page)))
            controller.view.backgroundColor = .clear
            controllers[page] = controller
            return controller
        }

        private func page(of controller: UIViewController) -> Page? {
            controllers.first { $0.value === controller }?.key
        }

        /// 今のページと、その両隣だけを残す
        private func prune() {
            let keep = Set([current, parent.neighbor(current, true), parent.neighbor(current, false), target]
                .compactMap { $0 })
            controllers = controllers.filter { keep.contains($0.key) }
        }

        /// タブ・ページ番号を押したとき。今のページから見た向きに、スワイプと同じ動きでめくる
        private func go(to page: Page) {
            guard let pager else { return }
            if transitioning {
                queued = page
                return
            }
            let forward = parent.isForward(current, page)
            let animated = !UIAccessibility.isReduceMotionEnabled
            transitioning = true
            target = page
            pager.setViewControllers([controller(for: page)], direction: forward ? .forward : .reverse,
                                     animated: animated) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishProgrammatic(page) }
            }
            if !animated { finishProgrammatic(page) }
        }

        private func finishProgrammatic(_ page: Page) {
            guard transitioning, target == page, let pager else { return }
            transitioning = false
            target = nil
            current = page
            neighborsVersion = parent.neighborsVersion
            // 動き終わったら置き直して、iOSが覚えている移動前の隣を捨てさせる。
            // めくりの完了の処理の中では置き直せないため、完了の処理を返してから行う（UIPageViewControllerの決まった使い方）
            DispatchQueue.main.async { [weak self, weak pager] in
                guard let self, let pager, !self.transitioning, self.current == page,
                      self.scrollView?.isDragging != true else { return }
                pager.setViewControllers([self.controller(for: page)], direction: .forward, animated: false)
                self.prune()
            }
            parent.onMotion(LibraryPagerMotion(from: page, to: nil, fraction: 0))
            parent.onSettle(page)
            if let queued {
                self.queued = nil
                if queued != current { go(to: queued) }
            }
        }

        private func scrolled(_ scroll: UIScrollView) {
            let width = scroll.bounds.width
            guard width > 0 else { return }
            let offset = (scroll.contentOffset.x - width) / width
            guard offset != 0 else {
                // めくり終わりにiOSが位置を真ん中へ戻した瞬間は、まだ止まったページが確定していないので知らせない
                if target == nil { parent.onMotion(LibraryPagerMotion(from: current, to: nil, fraction: 0)) }
                return
            }
            let to = target ?? parent.neighbor(current, offset > 0)
            parent.onMotion(LibraryPagerMotion(from: current, to: to, fraction: min(1, abs(offset))))
        }

        // MARK: - UIPageViewController

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = page(of: viewController), let previous = parent.neighbor(page, false) else { return nil }
            return controller(for: previous)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = page(of: viewController), let next = parent.neighbor(page, true) else { return nil }
            return controller(for: next)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            target = pendingViewControllers.first.flatMap(page(of:))
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            target = nil
            if let visible = pageViewController.viewControllers?.first.flatMap(page(of:)) { current = visible }
            prune()
            parent.onMotion(LibraryPagerMotion(from: current, to: nil, fraction: 0))
            if completed { parent.onSettle(current) }
            if let queued {
                self.queued = nil
                if queued != current { go(to: queued) }
            }
        }
    }
}
