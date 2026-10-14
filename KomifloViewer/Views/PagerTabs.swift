import SwiftUI

/// スワイプ中の見た目だけを共有し、一覧の選択確定・取得とは分ける。
final class PagerProgress: ObservableObject {
    @Published private(set) var position: CGFloat?

    func update(_ value: CGFloat) {
        guard value.isFinite, position != value else { return }
        position = value
    }
}

private struct PagerTabFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 一覧や背景の番号と区別し、帯の中のボタンだけをスクロール先にする。
private struct PagerTabTarget<Item: Hashable>: Hashable {
    let namespace: Namespace.ID
    let item: Item
}

/// 同じページ位置から、選択の背景だけを連続して動かす。
struct PagerTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    @ObservedObject var progress: PagerProgress
    var scrolls = false
    var font: Font = .system(size: 13, weight: .semibold)
    var selectedFont: Font?
    var positionTransform: (CGFloat) -> CGFloat = { $0 }
    let title: (Item) -> String
    @Namespace private var coordinateSpace

    private var position: CGFloat {
        let value = progress.position.map(positionTransform) ?? CGFloat(items.firstIndex(of: selection) ?? 0)
        return min(CGFloat(max(0, items.count - 1)), max(0, value))
    }

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    tabs.padding(.horizontal, 16)
                        // 表示した瞬間はボタンの配置が終わっていないことがあり、そこで動かしても効かない。
                        // 並びの幅が決まったとき（最初の配置・項目の増減）に、選択中のボタンを中央へ
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            guard width > 0, !items.isEmpty else { return }
                            proxy.scrollTo(scrollTarget(items[Int(position.rounded())]), anchor: .center)
                        }
                }
                .onChange(of: Int(position.rounded())) { _, index in
                    guard items.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(scrollTarget(items[index]), anchor: .center)
                    }
                }
            }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        HStack(spacing: scrolls ? 6 : 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { selection = item }
                } label: {
                    Text(title(item))
                        .font(selection == item ? selectedFont ?? font : font)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, scrolls ? 14 : 4)
                        .frame(maxWidth: scrolls ? nil : .infinity)
                        .frame(height: 32)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PagerTabFrames.self,
                            value: [index: geometry.frame(in: .named(coordinateSpace))])
                    }
                }
                .id(scrollTarget(item))
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(scrolls ? 0 : 2)
        .coordinateSpace(name: coordinateSpace)
        .backgroundPreferenceValue(PagerTabFrames.self) { frames in
            GeometryReader { _ in
                if scrolls {
                    ForEach(Array(frames.keys), id: \.self) { index in
                        if let rect = frames[index] {
                            Capsule().fill(Theme.bar)
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    }
                }
                if let rect = indicator(in: frames) {
                    Capsule().fill(scrolls ? Theme.accent : Color(white: 0.36))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .allowsHitTesting(false)
        }
        .background(scrolls ? .clear : Theme.bar, in: Capsule())
    }

    private func scrollTarget(_ item: Item) -> PagerTabTarget<Item> {
        PagerTabTarget(namespace: coordinateSpace, item: item)
    }

    private func indicator(in frames: [Int: CGRect]) -> CGRect? {
        let lower = Int(position.rounded(.down))
        let upper = min(items.count - 1, lower + 1)
        guard let first = frames[lower], let last = frames[upper] else { return nil }
        let part = position - CGFloat(lower)
        return CGRect(x: first.minX + (last.minX - first.minX) * part, y: first.minY,
                      width: first.width + (last.width - first.width) * part, height: first.height)
    }
}
