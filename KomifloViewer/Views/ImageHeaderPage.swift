import SwiftUI

/// 作家・雑誌・特集・タグで、縮む帯と一覧の安全領域を同じ処理で管理する。
struct ImageHeaderPage<Header: View, Content: View>: View {
    var footerHeight: CGFloat = 0
    let header: (CGFloat, ArtistHeaderLayout, ArtistHeaderScroll) -> Header
    let content: (ScrollViewProxy, CGFloat, CGFloat) -> Content
    @State private var scroll = ArtistHeaderScroll()

    var body: some View {
        ImageHeaderCanvas { size, layout in
            ImageHeaderScroll(size: size, layout: layout, footerHeight: footerHeight, scroll: scroll) { proxy in
                Color.clear.frame(height: 0).id("top")
                Section {
                    content(proxy, size.width, max(0, size.height - layout.compactHeight - footerHeight))
                } header: {
                    header(size.width, layout, scroll)
                        .frame(height: layout.expandedHeight + footerHeight, alignment: .top)
                        .modifier(ArtistHeaderHitRegion(scroll: scroll, layout: layout, footerHeight: footerHeight))
                }
            }
        }
    }
}

/// 履歴と同じく各ページが縦スクロールを持ち、ヘッダーと選択の帯だけを共有する。
struct ImageHeaderPagedPage<Item: Hashable, Header: View, Content: View>: View {
    let items: [Item]
    @Binding var selection: Item
    var footerHeight: CGFloat = 0
    let progress: PagerProgress
    let header: (CGFloat, ArtistHeaderLayout, ArtistHeaderScroll) -> Header
    let content: (Item, CGFloat, CGFloat) -> Content
    @State private var scrolls = HeaderScrolls<Item>()

    var body: some View {
        ImageHeaderCanvas(extendsToBottom: true) { size, layout in
            PagedView(items: items, selection: $selection, commitsSelectionOnIdle: true,
                      onScrollActivityChange: { moving in
                          if moving { scrolls.prepareOtherPages(selected: selection, layout: layout) }
                      }, progress: progress) { item in
                ImageHeaderScroll(size: size, layout: layout, footerHeight: footerHeight, scroll: scrolls.header,
                                  onOffset: { scrolls.update(item, offset: $0, selected: selection, layout: layout) },
                                  onScrollEnd: { scrolls.finish(item, selected: selection, layout: layout) },
                                  onResolve: { scrolls.attach($0, item: item, layout: layout) }) { _ in
                    Color.clear.frame(height: layout.expandedHeight + footerHeight).allowsHitTesting(false)
                    content(item, size.width, max(0, size.height - layout.compactHeight - footerHeight))
                }
            }
            .onChange(of: selection) { _, item in scrolls.prepare(item, layout: layout) }
            .onAppear { scrolls.prepare(selection, layout: layout) }
            .overlay(alignment: .top) {
                let scroll = scrolls.header
                header(size.width, layout, scroll)
                    .frame(height: layout.expandedHeight + footerHeight, alignment: .top)
                    .modifier(ArtistHeaderHitRegion(scroll: scroll, layout: layout, footerHeight: footerHeight))
            }
        }
    }
}

/// 連続位置を親の一覧で購読せず、訪問したページのヘッダーだけを更新する。
@MainActor private final class HeaderScrolls<Item: Hashable> {
    let header = ArtistHeaderScroll()
    private var values: [Item: Position] = [:]

    private final class Position {
        weak var view: UIScrollView?
        var offset: CGFloat = 0
        var headerOffset: CGFloat = 0
    }

    private func value(for item: Item) -> Position {
        if let value = values[item] { return value }
        let value = Position()
        values[item] = value
        return value
    }

    func attach(_ view: UIScrollView, item: Item, layout: ArtistHeaderLayout) {
        let position = value(for: item)
        guard position.view !== view else { return }
        position.view = view
        prepare(item, layout: layout, restoring: true)
    }

    func prepareOtherPages(selected: Item, layout: ArtistHeaderLayout) {
        let current = value(for: selected)
        current.offset = current.view?.contentOffset.y ?? current.offset
        current.headerOffset = header.offset
        for item in Array(values.keys) where item != selected { prepare(item, layout: layout) }
    }

    func prepare(_ item: Item, layout: ArtistHeaderLayout, restoring: Bool = false) {
        let position = value(for: item)
        let current = restoring ? position.offset : position.view?.contentOffset.y ?? position.offset
        let offset = layout.transferredOffset(current, from: position.headerOffset, to: header.offset)
        position.offset = offset
        position.headerOffset = header.offset
        if let view = position.view, view.contentOffset.y != offset {
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: offset), animated: false)
        }
    }

    func update(_ item: Item, offset: CGFloat, selected: Item, layout: ArtistHeaderLayout) {
        let position = value(for: item)
        // 切り替え時の配置通知では共有ヘッダーを広げず、縦の操作だけを反映する。
        guard let view = position.view, view.isDragging || view.isDecelerating else { return }
        position.offset = view.contentOffset.y
        position.headerOffset = layout.offset(position.offset)
        if item == selected { header.update(offset) }
    }

    func finish(_ item: Item, selected: Item, layout: ArtistHeaderLayout) {
        let position = value(for: item)
        guard let view = position.view else { return }
        position.offset = view.contentOffset.y
        position.headerOffset = layout.offset(position.offset)
        if item == selected { header.update(position.headerOffset) }
    }
}

private struct ImageHeaderCanvas<Content: View>: View {
    var extendsToBottom = false
    @ViewBuilder let content: (CGSize, ArtistHeaderLayout) -> Content
    @State private var windowTopInset: CGFloat?

    var body: some View {
        GeometryReader { safeArea in
            let statusHeight = windowTopInset ?? safeArea.safeAreaInsets.top
            let layout = ArtistHeaderLayout(
                expandedHeight: max(ArtistHeaderLayout.controlsHeight + 80, 121 * OfficialMetrics.scale) + statusHeight,
                compactHeight: ArtistHeaderLayout.controlsHeight + statusHeight, statusHeight: statusHeight)
            GeometryReader { canvas in
                content(canvas.size, layout)
                    .frame(width: canvas.size.width, height: canvas.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea(.container, edges: extendsToBottom ? [.top, .bottom] : .top)
        }
        .background(Theme.background.ignoresSafeArea())
        .background { ArtistWindowInsetReader { windowTopInset = $0 } }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 一覧の安全領域・ヘッダー追従・標準スクロールバーは全画面で共用する。
private struct ImageHeaderScroll<Content: View>: View {
    let size: CGSize
    let layout: ArtistHeaderLayout
    let footerHeight: CGFloat
    let scroll: ArtistHeaderScroll
    var onOffset: ((CGFloat) -> Void)? = nil
    var onScrollEnd: (() -> Void)? = nil
    var onResolve: ((UIScrollView) -> Void)? = nil
    @ViewBuilder let content: (ScrollViewProxy) -> Content
    @State private var coordinateSpace = UUID()

    var body: some View {
        ScrollViewReader { proxy in
            trackedScroll(proxy: proxy)
        }
        .coordinateSpace(name: coordinateSpace)
    }

    @ViewBuilder
    private func trackedScroll(proxy: ScrollViewProxy) -> some View {
        if #available(iOS 18.0, *) {
            pageScroll(proxy: proxy)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    layout.offset(geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, offset in (onOffset ?? scroll.update)(offset) }
                .onScrollPhaseChange { oldPhase, newPhase in
                    if newPhase == .idle, oldPhase == .interacting || oldPhase == .decelerating {
                        onScrollEnd?()
                    }
                }
        } else {
            pageScroll(proxy: proxy)
        }
    }

    private func pageScroll(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                content(proxy)
            }
            .frame(width: size.width)
            .frame(minHeight: size.height + layout.collapseDistance, alignment: .top)
            .modifier(ArtistLegacyScrollOffset(coordinateSpace: coordinateSpace, scroll: scroll, layout: layout, onOffset: onOffset))
            .background { ArtistScrollInsets(scroll: scroll, layout: layout, footerHeight: footerHeight, onResolve: onResolve) }
        }
        .modifier(ArtistTopScrollEdge())
    }
}
