import Foundation

/// 受信した塊ごとにメモリへ追加する。サイズ制限は受信中に確認し、ファイルを作らない。
final class NativeReaderTransport: NSObject, URLSessionDataDelegate {
    private var session: URLSession!
    private let lock = NSLock()
    private var pending: [Int: Transfer] = [:]

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func data(for request: URLRequest, maximumBytes: Int, successfulStatuses: Set<Int>, priority: Float = URLSessionTask.defaultPriority) async throws -> (Data, HTTPURLResponse) {
        let task = session.dataTask(with: request)
        task.priority = priority
        let transfer = Transfer(maximumBytes: maximumBytes, successfulStatuses: successfulStatuses)
        register(transfer, for: task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.wait(continuation)
                if Task.isCancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: { task.cancel() }
    }

    func close() { session.invalidateAndCancel() }

    private func register(_ transfer: Transfer, for task: URLSessionTask) {
        lock.lock()
        pending[task.taskIdentifier] = transfer
        lock.unlock()
    }

    private func transfer(for task: URLSessionTask, remove: Bool = false) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return remove ? pending.removeValue(forKey: task.taskIdentifier) : pending[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(transfer(for: dataTask)?.accept(response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if transfer(for: dataTask)?.append(data) != true { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(for: task, remove: true)?.finish(error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private final class Transfer {
        typealias Output = (Data, HTTPURLResponse)
        private let lock = NSLock()
        private let maximumBytes: Int
        private let successfulStatuses: Set<Int>
        private var data = Data()
        private var response: HTTPURLResponse?
        private var failure: Error?
        private var continuation: CheckedContinuation<Output, Error>?
        private var completed: Result<Output, Error>?

        init(maximumBytes: Int, successfulStatuses: Set<Int>) {
            self.maximumBytes = maximumBytes
            self.successfulStatuses = successfulStatuses
        }

        func wait(_ continuation: CheckedContinuation<Output, Error>) {
            lock.lock()
            let result = completed
            if result == nil { self.continuation = continuation }
            lock.unlock()
            if let result { continuation.resume(with: result) }
        }

        func accept(_ response: URLResponse) -> Bool {
            guard let response = response as? HTTPURLResponse else { failure = NativeReaderError.network; return false }
            switch response.statusCode {
            case let status where KomifloSession.requiresLogin(status: status, path: response.url?.path ?? ""):
                failure = NativeReaderError.notLoggedIn
            case let status where successfulStatuses.contains(status): break
            default: failure = NativeReaderError.http(response.statusCode)
            }
            guard failure == nil else { return false }
            if response.expectedContentLength > Int64(maximumBytes) { failure = NativeReaderError.documentCheck("D17") }
            guard failure == nil else { return false }
            self.response = response
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            return true
        }

        func append(_ chunk: Data) -> Bool {
            guard failure == nil, chunk.count <= maximumBytes - data.count else {
                failure = failure ?? NativeReaderError.documentCheck("D17")
                return false
            }
            data.append(chunk)
            return true
        }

        func finish(_ error: Error?) {
            let result: Result<Output, Error>
            if let error = failure ?? error { result = .failure(error) }
            else if let response { result = .success((data, response)) }
            else { result = .failure(NativeReaderError.network) }
            data = Data()
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil { completed = result }
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
