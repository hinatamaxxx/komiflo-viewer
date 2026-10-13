import Foundation

/// ロゴの識別結果だけを既存の情報キャッシュへ保存する。画像の期限とは切り離す。
enum MagazineIdentityCache {
    private static func key(_ id: Int) -> String { "magazine-logo-v1:\(id)" }

    static func read(id: Int) -> MagazineIdentity? {
        guard let data = APICache.read(key(id)) else { return nil }
        return try? JSONDecoder().decode(MagazineIdentity.self, from: data)
    }

    static func store(_ identity: MagazineIdentity, id: Int) async {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        await APICache.write(data, for: key(id)).value
    }
}
