import SwiftUI

/// 作家・タグで、読み終わり画面と同じフォローの演出を使う。
struct FollowButton: View {
    let isFollowing: Bool
    let animated: Bool
    var drawsContent = true
    /// オン・オフの文字（特集のいいねでは「いいね済み」「いいね」）
    var onTitle = "フォロー中"
    var offTitle = "フォロー"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(onTitle.count >= offTitle.count ? onTitle : offTitle)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .hidden()
                .overlay {
                    if drawsContent {
                        GeometryReader { geometry in
                            ReaderAnimatedPill(title: isFollowing ? onTitle : offTitle, color: Theme.accent,
                                               maxSpread: 32 * geometry.size.height / 35,
                                               filled: isFollowing, animated: animated)
                        }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(isFollowing ? onTitle : offTitle)
    }
}
