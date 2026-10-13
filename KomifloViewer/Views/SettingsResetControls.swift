import SwiftUI
import UIKit

/// 確認・完了とも、iOS標準のアラートで表示する。
struct SettingsResetControls: View {
    let scope: SettingsScope
    @State private var confirmsReset = false

    var body: some View {
        Button("初期設定に戻す", role: .destructive) { confirmsReset = true }
            .background(SettingsResetAlertPresenter(scope: scope, requested: $confirmsReset)
                .allowsHitTesting(false))
    }
}

/// 標準アラートの閉じ終わり通知で、次の標準アラートへつなぐ。
private struct SettingsResetAlertPresenter: UIViewControllerRepresentable {
    let scope: SettingsScope
    @Binding var requested: Bool

    final class Coordinator {
        var presenting = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard requested, !context.coordinator.presenting, controller.view.window != nil else { return }
        context.coordinator.presenting = true
        let confirmation = UIAlertController(
            title: "\(scope.title)を初期設定に戻しますか？",
            message: "この画面の設定を初期値に戻します。共通のコメント投稿ボタンの位置も右側に戻ります。",
            preferredStyle: .alert
        )
        confirmation.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in
            requested = false
            context.coordinator.presenting = false
        })
        confirmation.addAction(UIAlertAction(title: "戻す", style: .destructive) { [weak confirmation] _ in
            guard let confirmation else { return }
            requested = false
            let presenter = confirmation.presentingViewController ?? controller
            confirmation.dismiss(animated: true) {
                SettingsDefaults.shared.reset(scope)
                let completed = UIAlertController(title: "初期設定に戻しました",
                    message: "\(scope.title)を初期設定に戻しました。", preferredStyle: .alert)
                completed.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                    context.coordinator.presenting = false
                })
                presenter.present(completed, animated: true)
            }
        })
        controller.present(confirmation, animated: true)
    }
}
