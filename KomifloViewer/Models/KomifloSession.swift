import Foundation

enum KomifloSession {
    /// 未ログインのsession/userは400を返す。他のAPIの400とは区別する。
    static func requiresLogin(status: Int, path: String) -> Bool {
        status == 401 || status == 403 || (status == 400 && path == "/session/user")
    }
}

struct KFSessionResponse: Decodable {
    let success: Bool?
    let user: KFUser?

    var loggedInUser: KFUser? {
        // 公式Webやビューアと同じく、削除済みの利用者はログインしていない扱いにする。
        guard success != false, let user, user.id > 0, user.deleted != true else { return nil }
        return user
    }
}

struct KFUser: Decodable {
    let id: Int
    let deleted: Bool?
    /// 読み放題の利用中か。公式Webはfalseのとき、作品の画面のかわりに購読の案内を出す
    let canViewContents: Bool?
    let readingLists: [KFReadingList]?
}

/// /billing/subscription。購読の案内に再開の文言を出すかだけに使う
struct KFSubscriptionResponse: Decodable {
    let subscription: Subscription?

    struct Subscription: Decodable {
        let created: String?
        let finished: String?
    }

    /// 公式Webと同じく、開始日時より終了日時が後なら以前に契約していた扱い（ISO8601の文字列で比べる）
    var hadSubscription: Bool {
        guard let created = subscription?.created, let finished = subscription?.finished else { return false }
        return created < finished
    }
}

struct KFReadingList: Decodable {
    let id: Int
    let listType: String?
    let name: String?
}
