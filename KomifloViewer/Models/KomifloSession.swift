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
    let readingLists: [KFReadingList]?
}

struct KFReadingList: Decodable {
    let id: Int
    let listType: String?
    let name: String?
}
