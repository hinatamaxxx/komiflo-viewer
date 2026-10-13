import Foundation

/// Webからの通知と画面遷移は、文字列の見た目ではなく送信元とURL全体を確認する。
enum ReaderURLPolicy {
    static func isSecureURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func isReaderSite(_ url: URL) -> Bool {
        isSecureURL(url) && ["komiflo.com", "www.komiflo.com"].contains(url.host?.lowercased() ?? "")
    }

    static func isKomifloSite(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return isSecureURL(url) && (host == "komiflo.com" || host.hasSuffix(".komiflo.com"))
    }

    static func acceptsMessage(scheme: String, host: String, port: Int, mainFrame: Bool) -> Bool {
        mainFrame && scheme == "https" && ["komiflo.com", "www.komiflo.com"].contains(host.lowercased())
            && (port == 0 || port == 443)
    }

    static func canOpenExternally(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
}
