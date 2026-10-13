import Foundation

enum SettingsScope: String {
    case application, reader, all

    var title: String {
        switch self {
        case .application: return "アプリ設定"
        case .reader: return "ビュアー設定"
        case .all: return "アプリ・ビュアー設定"
        }
    }
}

/// 起動時の標準値と、画面ごとの初期化に同じ定義を使う。
struct SettingsDefaults {
    enum Value: Equatable {
        case bool(Bool), number(Double), text(String)

        var storedValue: Any {
            switch self {
            case .bool(let value): return value
            case .number(let value): return value
            case .text(let value): return value
            }
        }
    }

    struct Field {
        let key: String
        let initial: Value
    }

    let applicationFields: [Field]
    let readerFields: [Field]

    func fields(for scope: SettingsScope) -> [Field] {
        switch scope {
        case .application: return applicationFields
        case .reader: return readerFields
        case .all:
            // 両画面で共用する設定は一度だけ含める。
            var unique: [String: Field] = [:]
            for field in applicationFields + readerFields { unique[field.key] = field }
            return unique.values.sorted { $0.key < $1.key }
        }
    }

    func register(defaults: UserDefaults = .standard) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues:
            fields(for: .all).map { ($0.key, $0.initial.storedValue) }))
    }

    func reset(_ scope: SettingsScope, defaults: UserDefaults = .standard) {
        for field in fields(for: scope) { defaults.set(field.initial.storedValue, forKey: field.key) }
    }
}
