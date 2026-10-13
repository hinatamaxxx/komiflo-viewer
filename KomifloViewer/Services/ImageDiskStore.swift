import Foundation

/// 表紙・バナーの保存量を、新しく保存する時にも上限内へ戻す。
final class ImageDiskStore: @unchecked Sendable {
    private let directory: URL
    private let byteLimit: @Sendable () -> Int64
    private let lock = NSLock()
    private var knownBytes: Int64?

    init(directory: URL, byteLimit: @escaping @Sendable () -> Int64) {
        self.directory = directory
        self.byteLimit = byteLimit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func fileURL(named name: String) -> URL { directory.appendingPathComponent(name) }

    func store(_ data: Data, named name: String) {
        lock.withLock {
            if knownBytes == nil { knownBytes = entries().reduce(0) { $0 + $1.size } }
            let url = fileURL(named: name)
            let oldSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            do { try data.write(to: url, options: .atomic) }
            catch { return }
            knownBytes = (knownBytes ?? 0) + Int64(data.count) - oldSize
            let limit = byteLimit()
            if limit > 0, (knownBytes ?? 0) > limit { trimLocked(limit: limit) }
        }
    }

    func usage() -> Int64 {
        lock.withLock {
            let bytes = entries().reduce(0) { $0 + $1.size }
            knownBytes = bytes
            return bytes
        }
    }

    func trim() { lock.withLock { trimLocked(limit: byteLimit()) } }

    func clear() {
        lock.withLock {
            for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
            knownBytes = entries().reduce(0) { $0 + $1.size }
        }
    }

    private func trimLocked(limit: Int64) {
        var files = entries()
        var total = files.reduce(0) { $0 + $1.size }
        if limit > 0, total > limit {
            files.sort { $0.date < $1.date }
            for file in files where total > limit {
                do {
                    try FileManager.default.removeItem(at: file.url)
                    total -= file.size
                } catch { continue }
            }
        }
        knownBytes = total
    }

    private func entries() -> [(url: URL, size: Int64, date: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }
}
