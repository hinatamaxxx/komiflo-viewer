import SwiftUI

enum ReaderProgressThumb {
    static let diameter: CGFloat = 22
    static let activeWidth: CGFloat = 36
    static let activeHeight: CGFloat = 18
    static let railHeight: CGFloat = 22
    static let inset: CGFloat = 18
}

/// 右から左へ進む進捗。ナビ非表示中も、その位置のページを選べる。
struct NativePageProgress: View {
    let page: Int
    let count: Int
    var transitionPage: Int?
    var usesGlass = false
    var navigationVisible = true
    let onSelect: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragFraction: CGFloat?
    private var fraction: CGFloat { dragFraction ?? CGFloat(max(0, min(transitionPage ?? page, count) - 1)) / CGFloat(max(1, count - 1)) }
    private var isDragging: Bool { dragFraction != nil }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(min(page, count))/\(count) ページ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
            GeometryReader { geometry in
                let inset = ReaderProgressThumb.inset
                let width = max(1, geometry.size.width - inset * 2)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(width: width, height: 4)
                        .offset(x: inset)
                    Capsule().fill(Theme.accent).frame(width: width, height: 4)
                        .scaleEffect(x: fraction, y: 1, anchor: .trailing)
                        .offset(x: inset)
                        Color.clear
                        .frame(width: isDragging ? ReaderProgressThumb.activeWidth : ReaderProgressThumb.diameter,
                               height: isDragging ? ReaderProgressThumb.activeHeight : ReaderProgressThumb.diameter)
                        .modifier(ProgressThumbStyle(usesGlass: usesGlass))
                        .shadow(color: .black.opacity(isDragging ? 0.25 : 0.15), radius: isDragging ? 4 : 2, y: 1)
                        // 取り除かずに薄くすることで、バーと同じ移動に追従して消える。
                        .opacity(isDragging || navigationVisible ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: navigationVisible)
                        .position(x: inset + width * (1 - fraction),
                                  y: geometry.size.height / 2)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .animation(reduceMotion || isDragging ? nil : .easeOut(duration: 0.22), value: fraction)
            }
            .frame(height: ReaderProgressThumb.railHeight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.65)))
        .overlay {
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        // つまみの大きさに応じたレールの余白と、操作位置を揃える。
                        let inset = 12 + ReaderProgressThumb.inset
                        let width = max(1, geometry.size.width - inset * 2)
                        let fraction = 1 - min(1, max(0, (value.location.x - inset) / width))
                        // 指の位置はそのまま反映し、ページ境界だけ既存の選択へ渡す。
                        withTransaction(Transaction(animation: nil)) { dragFraction = fraction }
                        onSelect(min(max(1, 1 + Int((fraction * CGFloat(max(0, count - 1))).rounded())), max(1, count)))
                    }.onEnded { _ in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { dragFraction = nil }
                    })
            }
        }
        .sensoryFeedback(.selection, trigger: page) { _, _ in isDragging }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ページ進捗")
        .accessibilityValue("\(min(page, count))/\(count) ページ")
        .accessibilityIdentifier("reader-page-progress")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect(min(count, page + 1))
            case .decrement: onSelect(max(1, page - 1))
            @unknown default: break
            }
        }
    }
}

/// 縦読みは上から下へ進む。横読みと同じつまみ・ページ選択を使う。
struct NativeVerticalPageProgress: View {
    let page: Int
    let count: Int
    var usesGlass = false
    var navigationVisible = true
    let onSelect: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragFraction: CGFloat?
    private var fraction: CGFloat { dragFraction ?? CGFloat(max(0, min(page, count) - 1)) / CGFloat(max(1, count - 1)) }
    private var isDragging: Bool { dragFraction != nil }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(min(page, count))/\(count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6).frame(height: 16)
            GeometryReader { geometry in
                let inset = ReaderProgressThumb.inset
                let height = max(1, geometry.size.height - inset * 2)
                ZStack(alignment: .top) {
                    Capsule().fill(.white.opacity(0.25)).frame(width: 4, height: height).offset(y: inset)
                    Capsule().fill(Theme.accent).frame(width: 4, height: height)
                        .scaleEffect(x: 1, y: fraction, anchor: .top).offset(y: inset)
                    Color.clear
                        .frame(width: isDragging ? ReaderProgressThumb.activeHeight : ReaderProgressThumb.diameter,
                               height: isDragging ? ReaderProgressThumb.activeWidth : ReaderProgressThumb.diameter)
                        .modifier(ProgressThumbStyle(usesGlass: usesGlass))
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .opacity(isDragging || navigationVisible ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: navigationVisible)
                        .position(x: geometry.size.width / 2, y: inset + height * fraction)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(reduceMotion || isDragging ? nil : .easeOut(duration: 0.22), value: fraction)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.65)))
        .overlay {
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        // 数字と余白を除いたレールに操作位置を揃える。
                        let inset: CGFloat = 6 + 16 + 4 + ReaderProgressThumb.inset
                        let height = max(1, geometry.size.height - inset - 6 - ReaderProgressThumb.inset)
                        let fraction = min(1, max(0, (value.location.y - inset) / height))
                        withTransaction(Transaction(animation: nil)) { dragFraction = fraction }
                        onSelect(min(max(1, 1 + Int((fraction * CGFloat(max(0, count - 1))).rounded())), max(1, count)))
                    }.onEnded { _ in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { dragFraction = nil }
                    })
            }
        }
        .sensoryFeedback(.selection, trigger: page) { _, _ in isDragging }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ページ進捗")
        .accessibilityValue("\(min(page, count))/\(count) ページ")
        .accessibilityIdentifier("reader-page-progress")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect(min(count, page + 1))
            case .decrement: onSelect(max(1, page - 1))
            @unknown default: break
            }
        }
    }
}

private struct ProgressThumbStyle: ViewModifier {
    let usesGlass: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), usesGlass, !reduceTransparency {
            content.background(Capsule().fill(.white.opacity(0.18)))
                // 拡大はバー全体の操作状態から制御し、接触位置による二重の拡大を避ける。
                .glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.white))
                .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1))
        }
    }
}
