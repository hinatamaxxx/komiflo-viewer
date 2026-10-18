import SwiftUI
import UIKit

/// 「さがす」の検索バーと各画面の切り替えの位置（アプリ設定で共通。既定は上）
enum ControlsPosition {
    static let key = "layout.controlsAtBottom"
}

/// 画面の下（タブバーのすぐ上）に置く操作の帯。指が届きやすく、余白もしっかり取る
struct BottomControlBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }
}

/// 下に置く検索欄。見た目は上に置くときと同じ、iOS標準の検索バー（UISearchBar）そのもの
struct InlineSearchField: UIViewRepresentable {
    @Binding var text: String
    let prompt: String
    var onSubmit: () -> Void = {}
    /// この値が変わるたびに、検索欄にカーソルを入れてキーボードを出す（「さがす」を開いたときなど）
    var focusToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.returnKeyType = .search
        bar.delegate = context.coordinator
        bar.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return bar
    }

    /// 検索バー本来の高さで置く（高さを決め打ちすると、はみ出して上の帯に重なることがある）
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISearchBar, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(height, 44))
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.parent = self
        if bar.text != text { bar.text = text }
        bar.placeholder = prompt
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            if focusToken > 0 {
                // 画面が表示されてからでないとキーボードが出ないので、少し待つ
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    bar.becomeFirstResponder()
                }
            }
        }
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: InlineSearchField
        var lastFocusToken = 0

        init(_ parent: InlineSearchField) { self.parent = parent }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            parent.text = searchText
            if searchText.isEmpty { parent.onSubmit() }
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            searchBar.setShowsCancelButton(true, animated: true)
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            searchBar.setShowsCancelButton(false, animated: true)
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
            parent.onSubmit()
        }

        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            searchBar.text = ""
            parent.text = ""
            searchBar.resignFirstResponder()
            parent.onSubmit()
        }
    }
}

/// 一番上でさらに下に引っぱったときに一度だけ動かす（「さがす」で検索欄にカーソルを入れるのに使う）。
/// スクロール位置を読めるのはiOS 18以降なので、それより前は何もしない
struct PullDownAction: ViewModifier {
    let action: (() -> Void)?
    /// どれだけ引っぱったら動かすか
    var threshold: CGFloat = 60

    @State private var didFire = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let action {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                if offset < -threshold, !didFire {
                    didFire = true
                    action()
                } else if offset >= -4 {
                    didFire = false
                }
            }
        } else {
            content
        }
    }
}

/// 左右スワイプで1ページずつ切り替える表示（アプリ内の横スワイプの切り替えはすべてこれを使う）。
/// iOS標準のページ表示（TabViewのpage）は、勢いの弱いスワイプだとページの途中で止まってしまうことがあるので、
/// 必ずページの切れ目で止まる横スクロール（ページ送り）で作る
struct PagedView<Item: Hashable, Page: View>: View {
    let items: [Item]
    @Binding var selection: Item
    /// ページの下に「・・・」の位置表示を出す（ホームのバナー用）
    var showsIndicator = false
    /// 外側で縦スクロールする場合だけ、選択中の内容の高さに合わせる。
    var sizesToContent = false
    /// 少数の固定タブは枠を保持し、切り替え中の作り直しを避ける。中の一覧は遅延表示のまま。
    var keepsPagesAlive = false
    /// 選択に連動する一覧更新・設定保存は、指を離した後の移動も終わってから行う。
    var commitsSelectionOnIdle = false
    var onScrollActivityChange: ((Bool) -> Void)? = nil
    var progress: PagerProgress? = nil
    @Namespace private var scrollSpace
    @ViewBuilder let page: (Item) -> Page

    /// スクロールの位置（どのページが表示されているか）
    @State private var position: Item?
    @State private var didScrollToInitial = false
    @State private var isScrolling = false
    @State private var contentHeights: [Item: CGFloat] = [:]
    /// 外から渡されないときの位置（下の点の表示に使う）
    @State private var ownProgress = PagerProgress()
    /// 選択の変更で動かしている先のページ
    @State private var pendingTarget: Item?

    private var currentProgress: PagerProgress { progress ?? ownProgress }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    if keepsPagesAlive {
                        HStack(alignment: .top, spacing: 0) {
                            pages(size: geometry.size)
                        }
                        .scrollTargetLayout()
                        .onGeometryChange(for: CGFloat.self) { contentGeometry in
                            -contentGeometry.frame(in: .named(scrollSpace)).minX / max(1, geometry.size.width)
                        } action: { value in scrolled(to: value) }
                    } else {
                        LazyHStack(alignment: .top, spacing: 0) {
                            pages(size: geometry.size)
                        }
                        .scrollTargetLayout()
                        .onGeometryChange(for: CGFloat.self) { contentGeometry in
                            -contentGeometry.frame(in: .named(scrollSpace)).minX / max(1, geometry.size.width)
                        } action: { value in scrolled(to: value) }
                    }
                }
                .coordinateSpace(name: scrollSpace)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $position)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .modifier(PageScrollActivity(onChange: observesScrollActivity ? scrollActivityChanged : nil))
                .onAppear {
                    guard !didScrollToInitial else { return }
                    didScrollToInitial = true
                    position = selection
                    proxy.scrollTo(selection, anchor: .leading)
                }
                // スワイプで止まったページを選択にする
                .onChange(of: position) { _, value in
                    guard !commitsSelectionOnIdle || !isScrolling else { return }
                    if let value, value != selection { selection = value }
                }
                // 切り替えボタンなどで選択が変わったら、そのページへ動かす
                .onChange(of: selection) { _, value in
                    guard value != position else { return }
                    if showsIndicator {
                        // 指で送って止まったページを選択にしたときは、動かさずに位置だけ合わせる
                        if visibleItem == value {
                            position = value
                            return
                        }
                        // 自動送りで最後から先頭へ戻る間は、途中のページを選択にしない
                        pendingTarget = value
                    }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        position = value
                    }
                }
                // ページが増減・並べ替えられたら（前の一覧のページ数が届いたときなど）、見えていたページに位置を合わせ直す。
                // 前にページが入ると、スクロールの位置が同じままで別のページが見えてしまう
                .onChange(of: items) { oldItems, newItems in
                    // 並べ替えの前に実際に見えていたページを残す。選択は並べ替えと同時に行き先へ変わることがあり、
                    // それに合わせると、横に動く前に行き先へ一瞬で移ってしまう（ライブラリのページ番号・タブ）
                    let index = currentProgress.position.map { Int($0.rounded()) }
                    let visible = index.flatMap { oldItems.indices.contains($0) ? oldItems[$0] : nil }
                    guard let anchor = [visible, position, selection].compactMap({ $0 }).first(where: newItems.contains)
                    else { return }
                    // 位置の記録が同じなら書き換えない（書き換えると、止まったページとして選択に入ってしまう）
                    if position != anchor { position = anchor }
                    proxy.scrollTo(anchor, anchor: .leading)
                }
            }
        }
        .frame(height: sizesToContent ? (contentHeights[selection] ?? 1) : nil)
        .overlay(alignment: .bottom) {
            if showsIndicator, items.count > 1 {
                PageDots(count: items.count, selectedIndex: items.firstIndex(of: selection) ?? 0,
                         progress: currentProgress)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func scrolled(to value: CGFloat) {
        currentProgress.update(value)
        // 点を出す横並び（ホームのバナー）は縦の一覧の中にあり、指で送ったときに表示中のページの通知
        // （scrollPosition）が返らず、選択が前のページのまま残っていた。止まった位置から選択を決める
        guard showsIndicator else { return }
        let nearest = value.rounded()
        guard abs(value - nearest) < 0.01, items.indices.contains(Int(nearest)) else { return }
        let item = items[Int(nearest)]
        if let pendingTarget {
            guard item == pendingTarget else { return }
            self.pendingTarget = nil
        }
        if item != selection { selection = item }
    }

    private var visibleItem: Item? {
        guard let position = currentProgress.position else { return nil }
        let index = Int(position.rounded())
        return items.indices.contains(index) ? items[index] : nil
    }

    private var observesScrollActivity: Bool {
        commitsSelectionOnIdle || onScrollActivityChange != nil || showsIndicator
    }

    private func scrollActivityChanged(_ moving: Bool) {
        isScrolling = moving
        if !moving, commitsSelectionOnIdle, let position, position != selection {
            selection = position
        }
        // 自動送りの途中で指が触れて止まったときも、止まったページを選択にする（iOS 18以降）
        if !moving, showsIndicator {
            pendingTarget = nil
            if let visibleItem, visibleItem != selection { selection = visibleItem }
        }
        onScrollActivityChange?(moving)
    }

    private func pages(size: CGSize) -> some View {
        ForEach(items, id: \.self) { item in
            sizedPage(item, size: size).id(item)
        }
    }

    @ViewBuilder
    private func sizedPage(_ item: Item, size: CGSize) -> some View {
        if sizesToContent {
            page(item)
                .frame(width: size.width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    max(1, geometry.size.height)
                } action: { height in
                    if contentHeights[item] != height { contentHeights[item] = height }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
        } else {
            // ページの大きさは表示する枠ぴったりにする（上下にはみ出さない）。
            page(item)
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }
}

/// ホームのバナーの下の点。表示中の位置だけを購読し、半分を越えたところで次の点へ移る
private struct PageDots: View {
    let count: Int
    let selectedIndex: Int
    @ObservedObject var progress: PagerProgress

    private var current: Int {
        let index = progress.position.map { Int($0.rounded()) } ?? selectedIndex
        return min(count - 1, max(0, index))
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// スクロール状態の変化だけを受け取り、時間待ちで終了を推測しない。
private struct PageScrollActivity: ViewModifier {
    let onChange: ((Bool) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let onChange {
            content.onScrollPhaseChange { oldPhase, newPhase in
                let wasMoving = oldPhase != .idle
                let isMoving = newPhase != .idle
                if wasMoving != isMoving { onChange(isMoving) }
            }
            .onDisappear { onChange(false) }
        } else {
            content
        }
    }
}

/// キーボードが出ているときだけ、キーボードのすぐ上に出す丸い「キーボードを閉じる」ボタン。
/// キーボードの上に帯（黒いバー）は付けず、このボタンだけを浮かせる
struct KeyboardDismissButton: View {
    @State private var isKeyboardVisible = false

    var body: some View {
        Group {
            if isKeyboardVisible {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("キーボードを閉じる")
                .padding(.trailing, 12)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { isKeyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.15)) { isKeyboardVisible = false }
        }
    }
}

extension View {
    /// 一覧をスクロールし始めたら、キーボードを閉じる（さがすの検索欄で使う）
    func dismissesKeyboardOnScroll() -> some View {
        modifier(DismissKeyboardOnScroll())
    }
}

/// スクロールし始めたらキーボードを閉じる。
/// iOS自身の「スクロールで閉じる」はスクロールの処理の途中で閉じるため、アニメーションなしで突然消えることがある。
/// iOS 18以降は、iOS自身の閉じ方は止めて、アプリがスクロールの処理の外で閉じる（下へ下がるアニメーションが付く）
private struct DismissKeyboardOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .scrollDismissesKeyboard(.never)
                .onScrollPhaseChange { _, phase in
                    guard phase == .interacting else { return }
                    DispatchQueue.main.async {
                        guard KeyboardState.shared.isVisible else { return }
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
        } else {
            content.scrollDismissesKeyboard(.immediately)
        }
    }
}

/// キーボードが今出ているか（アプリ全体で1つ。起動時に見張りを始める）
final class KeyboardState {
    static let shared = KeyboardState()

    private(set) var isVisible = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isVisible = true
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isVisible = false
        })
    }
}
