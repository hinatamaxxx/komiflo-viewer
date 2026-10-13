import SwiftUI
import UIKit

/// 既存の画像配置の通知を受け、自動再生表示と掲載誌ロゴへ位置を渡す。
final class ReaderImageGeometry: ObservableObject {
    @Published private(set) var frame = CGRect.null
    private var requestedFrame = CGRect.null
    private var scheduled = false

    func update(frame: CGRect) {
        guard requestedFrame != frame else { return }
        requestedFrame = frame
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if self.frame != self.requestedFrame { self.frame = self.requestedFrame }
        }
    }
}

struct NativeAutoplayBelowImage: View {
    @ObservedObject var imageGeometry: ReaderImageGeometry
    let available: CGRect
    let clock: ReaderAutoplayClock
    let style: String
    let showsStopButton: Bool
    let usesGlass: Bool
    let onStop: () -> Void

    var body: some View {
        let aboveHeight: CGFloat = showsStopButton ? NativeAutoplayControls.stopButtonHeight + 8 : 0
        let size = CGSize(width: max(1, available.width), height: (style == "ring" ? 44 : 20) + aboveHeight)
        let frame = ReaderAutoplayPlacement.frame(image: imageGeometry.frame, available: available, size: size, aboveHeight: aboveHeight)
        if !frame.isNull {
            NativeAutoplayControls(clock: clock, style: style, showsStopButton: showsStopButton,
                usesGlass: usesGlass, onStop: onStop)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }
}

/// 一時停止と再開はナビで行い、ここでは再生表示ごと終了する操作を置く。
struct NativeAutoplayControls: View {
    static let stopButtonHeight: CGFloat = 36
    let clock: ReaderAutoplayClock
    let style: String
    let showsStopButton: Bool
    let usesGlass: Bool
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsStopButton {
                Button(action: onStop) {
                    Label("自動再生をやめる", systemImage: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: Self.stopButtonHeight)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(ReaderGlassStyle(enabled: usesGlass, originalFill: .black.opacity(0.8), adaptiveControl: true))
                .accessibilityIdentifier("reader-stop-autoplay")
                .transition(.opacity)
            }
            NativeAutoplayIndicator(clock: clock, style: style)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
    }
}

private struct ReaderFooterHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func readerFooterHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ReaderFooterHeight.self, value: geometry.size.height)
        })
        .onPreferenceChange(ReaderFooterHeight.self, perform: onChange)
    }
}

/// 公式の白・青と右からの進捗を使う。毎フレームの監視はせず、ページの変更時だけ動かす。
struct NativeAutoplayIndicator: View {
    let clock: ReaderAutoplayClock
    let style: String

    var body: some View {
        Group {
            if style == "ring" {
                ZStack {
                    NativeAutoplayProgress(clock: clock, ring: true)
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                .padding(8)
            } else {
                GeometryReader { geometry in
                    NativeAutoplayProgress(clock: clock, ring: false)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(height: 4)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(Capsule().fill(.black.opacity(0.65)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clock.isPlaying ? "自動再生中" : "自動再生を一時停止中")
        .accessibilityValue("約\(Int(clock.duration))秒ごとにページ送り")
    }
}

private struct NativeAutoplayProgress: UIViewRepresentable {
    let clock: ReaderAutoplayClock
    let ring: Bool

    func makeUIView(context: Context) -> AutoplayProgressView {
        let view = AutoplayProgressView(ring: ring)
        view.update(clock)
        return view
    }

    func updateUIView(_ view: AutoplayProgressView, context: Context) { view.update(clock) }
}

private final class AutoplayProgressView: UIView {
    private let ring: Bool
    private let track: CALayer
    private let fill: CALayer
    private let progress = ReaderAutoplayProgress()
    private var clock = ReaderAutoplayClock()

    init(ring: Bool) {
        self.ring = ring
        track = ring ? CAShapeLayer() : CALayer()
        fill = ring ? CAShapeLayer() : CALayer()
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        let blue = UIColor(red: 66 / 255, green: 143 / 255, blue: 205 / 255, alpha: 1).cgColor
        if let track = track as? CAShapeLayer, let fill = fill as? CAShapeLayer {
            for shape in [track, fill] {
                shape.fillColor = UIColor.clear.cgColor
                shape.lineWidth = 3
            }
            track.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
            fill.strokeColor = blue
            fill.lineCap = .round
        } else {
            track.backgroundColor = UIColor.white.cgColor
            track.cornerRadius = 2
            track.masksToBounds = true
            fill.backgroundColor = blue
            fill.anchorPoint = CGPoint(x: 1, y: 0.5)
        }
        layer.addSublayer(track)
        if ring { layer.addSublayer(fill) } else { track.addSublayer(fill) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ clock: ReaderAutoplayClock) {
        self.clock = clock
        guard window != nil else { return }
        applyProgress()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 表示先へ載る前の演出に頼らず、載った時点の進み具合から始める。
        progress.invalidate()
        if window != nil { applyProgress() }
        else { fill.removeAnimation(forKey: ReaderAutoplayProgress.animationKey) }
    }

    private func applyProgress() {
        progress.apply(clock, to: fill, keyPath: ring ? "strokeEnd" : "transform.scale.x",
                       at: ProcessInfo.processInfo.systemUptime)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 寸法だけを更新する。進行中の進捗アニメーションを作り直さない。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        if let track = track as? CAShapeLayer, let fill = fill as? CAShapeLayer {
            fill.frame = bounds
            let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                radius: max(0, min(bounds.width, bounds.height) / 2 - 1.5),
                startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
            track.path = path
            fill.path = path
        } else {
            fill.bounds = CGRect(origin: .zero, size: bounds.size)
            fill.position = CGPoint(x: bounds.width, y: bounds.height / 2)
        }
        CATransaction.commit()
    }
}
