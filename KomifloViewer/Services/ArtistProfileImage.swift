import Foundation

/// 帯の画像に使う作家のプロフィール画像（公式の作家バナー）。
/// タグ・ホームの棚の一覧で、先頭の作品の作家に画像が無ければnil（画像なしの帯）
@MainActor
enum ArtistProfileImage {
    /// 保存してある前回の画像をすぐ渡し、公式から取り直して最新の画像を渡す（作家が画像を変えていれば差し替わる）。
    /// 前回の分も取り直しも無いときはnil
    static func load(authorSlug: String?, api: KomifloAPI, apply: (URL?) -> Void) async {
        guard let slug = authorSlug, !slug.isEmpty else {
            apply(nil)
            return
        }
        let saved = try? await APICache.fromCache({ try await api.attribute(slug: slug) })
        guard !Task.isCancelled else { return }
        if let saved { apply(saved.bannerURL) }
        let latest = try? await api.attribute(slug: slug)
        guard !Task.isCancelled else { return }
        if let latest {
            apply(latest.bannerURL)
        } else if saved == nil {
            // 別の作家の画像を出したままにしない
            apply(nil)
        }
    }
}

/// 以前の版で、帯の切り抜き位置を決めるために端末に保存していたもの（変換済みのモデルと判定結果）。
/// 位置決めの処理を外したので、残っていれば一度だけ消す
enum RetiredHeaderCaches {
    static func remove() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["ThumbnailCompiledModels-v1", "HeaderFraming-v1"] {
            let url = caches.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
