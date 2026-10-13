import Foundation

/// モデルだけを保存し、同じモデル・OSなら端末用への変換を繰り返さない。
struct ThumbnailModelCache {
    let directory: URL

    func load<Model>(name: String, version: String, compile: () throws -> URL,
                     open: (URL) throws -> Model) throws -> Model {
        let files = FileManager.default
        let target = directory.appendingPathComponent("\(name)-\(version).mlmodelc", isDirectory: true)
        if files.fileExists(atPath: target.path) {
            do { return try open(target) }
            catch {
                try? files.removeItem(at: target)
                throw error
            }
        }

        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let compiled = try compile()
        defer { try? files.removeItem(at: compiled) }
        let staging = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: compiled, to: staging)
        try files.moveItem(at: staging, to: target)
        let model: Model
        do {
            model = try open(target)
        } catch {
            try? files.removeItem(at: target)
            throw error
        }
        // 使える新版を確認してから、このモデルの古い変換結果だけを片付ける。
        for old in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if old != target, old.lastPathComponent.hasPrefix(name + "-"), old.pathExtension == "mlmodelc" {
                try? files.removeItem(at: old)
            }
        }
        return model
    }
}
