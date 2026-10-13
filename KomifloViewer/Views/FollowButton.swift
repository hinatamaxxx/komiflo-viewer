import SwiftUI

/// 作家・タグで、読み終わり画面と同じフォローの演出を使う。
struct FollowButton: View {
    let isFollowing: Bool
    let animated: Bool
    var drawsContent = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("フォロー中")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .hidden()
                .overlay {
                    if drawsContent {
                        GeometryReader { geometry in
                            ReaderAnimatedPill(title: isFollowing ? "フォロー中" : "フォロー", color: Theme.accent,
                                               maxSpread: 32 * geometry.size.height / 35,
                                               filled: isFollowing, animated: animated)
                        }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(isFollowing ? "フォロー中" : "フォロー")
    }
}
