import Foundation

/// 保存済みの表紙の内容に対し、顔・人物の座標だけを保持する。本文には使わない。
actor HeaderFramingCache {
    struct Framing: Codable, Sendable {
        let focus: CGRect?
        let protectedHead: CGRect?

        var isValid: Bool {
            [focus, protectedHead].allSatisfy { rect in
                guard let rect else { return true }
                return rect.origin.x.isFinite && rect.origin.y.isFinite
                    && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
            }
        }
    }

    static let shared = HeaderFramingCache(directory: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HeaderFraming-v1", isDirectory: true))
    private let disk: ImageDiskStore
    private let memory = NSCache<NSString, Entry>()
    private var inFlight: [String: Task<Framing, Error>] = [:]
    private final class Entry: NSObject {
        let value: Framing
        init(_ value: Framing) { self.value = value }
    }

    init(directory: URL) {
        disk = ImageDiskStore(directory: directory, byteLimit: { 4 * 1024 * 1024 })
        memory.countLimit = 256
    }

    func framing(fingerprint: String, detect: @escaping @Sendable () async throws -> Framing) async throws -> Framing {
        // 選び方を変更する場合は保存先の版も上げ、古い判定を混ぜない。
        let name = fingerprint
        if let entry = memory.object(forKey: name as NSString) { return entry.value }
        if let data = try? Data(contentsOf: disk.fileURL(named: name)),
           let saved = try? JSONDecoder().decode(Framing.self, from: data), saved.isValid {
            memory.setObject(Entry(saved), forKey: name as NSString)
            return saved
        }
        if let running = inFlight[name] { return try await running.value }
        let task = Task { try await detect() }
        inFlight[name] = task
        defer { inFlight[name] = nil }
        let result = try await task.value
        guard result.isValid else { throw CocoaError(.coderInvalidValue) }
        if let data = try? JSONEncoder().encode(result) { disk.store(data, named: name) }
        memory.setObject(Entry(result), forKey: name as NSString)
        return result
    }
}
