import Foundation

/// 表紙・作品情報の保存には、漫画のページ情報と表示用のキーを混ぜない。
enum NativeReaderPrivacy {
    static func metadataOnly(_ data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        func strip(_ value: Any) -> Any {
            if let fields = value as? [String: Any] {
                return fields.filter { !["imgs", "key_data", "key_hash"].contains($0.key) }.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        return try? JSONSerialization.data(withJSONObject: strip(json), options: [.fragmentsAllowed, .sortedKeys])
    }
}
