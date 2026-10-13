import Foundation
import Combine
import ImageIO
import UIKit
import WebKit

/// APIは既存のログインCookieを使う。公式ビューアやトップページを読み込まずに通信する。
/// ページのデータ・画像はメモリだけで扱い、URLCache・表紙のキャッシュ・ファイルには保存しない。
protocol NativeReaderLoading {
    @MainActor func document(comicID: Int) async throws -> (NativeReaderDocument, KFContent)
    func data(for page: NativeReaderDocument.Page) async throws -> Data
    func data(for page: NativeReaderDocument.Page, priority: Float) async throws -> Data
    func render(_ data: Data, for page: NativeReaderDocument.Page) async throws -> UIImage
    func preview(for page: NativeReaderDocument.Page) async throws -> UIImage?
    @MainActor func close()
}

extension NativeReaderLoading {
    func data(for page: NativeReaderDocument.Page, priority: Float) async throws -> Data { try await data(for: page) }
    func preview(for page: NativeReaderDocument.Page) async throws -> UIImage? { nil }
}

final class NativeReaderService: NativeReaderLoading {
    private let transport = NativeReaderTransport()

    @MainActor
    func document(comicID: Int) async throws -> (NativeReaderDocument, KFContent) {
        guard comicID > 0, let url = URL(string: "https://api.komiflo.com/content/id/\(comicID)") else {
            throw NativeReaderError.documentCheck("D18")
        }
        // 独立したGETを並行して待つ。両方の検証が終わるまで画像の取得は始めない。
        async let userData = apiData(url: URL(string: "https://api.komiflo.com/session/user")!, method: "GET", withCredentials: true, body: nil)
        async let contentData = apiData(url: url, method: "GET", withCredentials: true, body: nil)
        let identity = try NativeReaderIdentity.decode(await userData)
        let data: Data
        // session/userでログイン中と確認できた後の401・403は、作品の閲覧権限が足りないものとして扱う。
        do { data = try await contentData }
        catch NativeReaderError.notLoggedIn { throw NativeReaderError.notEntitled }
        let document = try NativeReaderDocument.decode(from: data, requestedID: comicID, identity: identity)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let content: KFContent?
        do { content = try decoder.decode(KFContentResponse.self, from: data).content }
        catch { throw NativeReaderError.documentCheck(NativeReaderDiagnostic.decoding(error, stage: "D16")) }
        guard let content else { throw NativeReaderError.documentCheck("D16-02-2") }
        return (document, content)
    }

    @MainActor
    func apiData(url: URL, method: String, withCredentials: Bool, body: [String: Any]?) async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              (url.port == nil || url.port == 443), url.fragment == nil,
              url.host == "api.komiflo.com" || url.host == "cache.api.komiflo.com" else {
            throw NativeReaderError.invalidDocument
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://komiflo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://komiflo.com/", forHTTPHeaderField: "Referer")
        if withCredentials {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let applicable = cookies.filter { NativeReaderCookiePolicy.permits($0, for: url) }.sorted { $0.path.count > $1.path.count }
            for (key, value) in HTTPCookie.requestHeaderFields(with: applicable) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await receive(request, maximumBytes: 8 * 1024 * 1024, successfulStatuses: [200, 201])
        if withCredentials {
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
                if let key = field.key as? String, let value = field.value as? String { result[key] = value }
            }
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                where NativeReaderCookiePolicy.permits(cookie, for: url, now: .distantPast) {
                await store.update(cookie)
            }
        }
        return data
    }

    func image(for page: NativeReaderDocument.Page) async throws -> UIImage {
        try await render(data(for: page), for: page)
    }

    func data(for page: NativeReaderDocument.Page) async throws -> Data {
        try await data(for: page, priority: URLSessionTask.defaultPriority)
    }

    func data(for page: NativeReaderDocument.Page, priority: Float) async throws -> Data {
        guard NativeReaderDocument.allowedImageURL(page.url) else { throw NativeReaderError.invalidImage }
        let request = URLRequest(url: page.url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, _) = try await receive(request, maximumBytes: 32 * 1024 * 1024, priority: priority)
        return data
    }

    func preview(for page: NativeReaderDocument.Page) async throws -> UIImage? {
        guard let url = page.previewURL else { return nil }
        let preview = NativeReaderDocument.Page(id: page.id, url: url, layout: nil, watermark: page.watermark)
        return try await render(data(for: preview, priority: URLSessionTask.lowPriority), for: preview)
    }

    func render(_ data: Data, for page: NativeReaderDocument.Page) async throws -> UIImage {
        try await NativeImageDecodeQueue.shared.render(data, for: page)
    }

    func close() { transport.close() }

    private func receive(_ request: URLRequest, maximumBytes: Int, successfulStatuses: Set<Int> = [200], priority: Float = URLSessionTask.defaultPriority) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request, maximumBytes: maximumBytes, successfulStatuses: successfulStatuses, priority: priority)
            try Task.checkCancellation()
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeReaderError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // 通信のエラーに含まれる署名付きURLなどは、画面やログに出さない。
            throw NativeReaderError.communicationError(error)
        }
    }

}

/// キャンセルされた展開が終わる前に次の展開を重ねない。画像の作業領域も1件ごとに解放する。
private actor NativeImageDecodeQueue {
    static let shared = NativeImageDecodeQueue()

    func render(_ data: Data, for page: NativeReaderDocument.Page) throws -> UIImage {
        try autoreleasepool {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 10000, height <= 10000, width * height <= 20_000_000,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw NativeReaderError.invalidImage
            }
            try Task.checkCancellation()
            return try NativePageRenderer.render(UIImage(cgImage: decoded), page: page)
        }
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }

    func update(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            if cookie.expiresDate.map({ $0 <= Date() }) ?? false {
                delete(cookie) { continuation.resume() }
            } else {
                setCookie(cookie) { continuation.resume() }
            }
        }
    }
}

@MainActor
final class NativeReaderSession: ObservableObject {
    @Published private(set) var document: NativeReaderDocument?
    @Published private(set) var content: KFContent?
    @Published private(set) var images: [Int: UIImage] = [:]
    @Published private(set) var previews: [Int: UIImage] = [:]
    @Published private(set) var errors: [Int: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var service: NativeReaderLoading?
    private let makeService: () -> NativeReaderLoading
    private let onAuthenticationRequired: () -> Void
    private var generation = NativeReaderGeneration()
    private var imageGeneration = NativeReaderGeneration()
    private var imageQuality = ReaderImageQuality.high
    private var automaticQuality = ReaderAutomaticQuality()
    private let loadTiming = ReaderImageLoadTiming()
    private var pageTasks: [Int: Task<Void, Never>] = [:]
    private var renderTasks: [Int: Task<Void, Never>] = [:]
    private var previewTasks: [Int: Task<Void, Never>] = [:]
    private var pageData: [Int: Data] = [:]
    private var pageQualities: [Int: ReaderImageQuality] = [:]
    private var previewFailures: Set<Int> = []
    private var deferredPages: Set<Int> = []
    private var expiryTask: Task<Void, Never>?
    private var current = 1
    private var continuousScrolling = false
    private var visiblePages: Set<Int> = []

    init(makeService: @escaping () -> NativeReaderLoading = {
        NativeReaderService()
    },
         onAuthenticationRequired: @escaping () -> Void = {}) {
        self.makeService = makeService
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    deinit {
        expiryTask?.cancel()
        pageTasks.values.forEach { $0.cancel() }
        renderTasks.values.forEach { $0.cancel() }
        previewTasks.values.forEach { $0.cancel() }
        let service = service
        Task { @MainActor in service?.close() }
    }

    func open(comicID: Int, page: Int = 1) async {
        if document?.comicID == comicID {
            resume(page: page)
            return
        }
        close()
        let service = makeService()
        self.service = service
        let ticket = generation.value
        loading = true
        defer { if generation.accepts(ticket) { loading = false } }
        do {
            let (document, content) = try await service.document(comicID: comicID)
            guard generation.accepts(ticket), !Task.isCancelled else { return }
            self.document = document
            self.content = content
            if let expiry = document.expiresAt {
                expiryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
                    guard let self, self.generation.accepts(ticket) else { return }
                    self.close()
                    self.error = NativeReaderError.notEntitled.errorDescription
                }
            }
            select(page: page)
        } catch is CancellationError {
        } catch {
            guard generation.accepts(ticket), !Task.isCancelled else { return }
            self.error = (error as? NativeReaderError)?.errorDescription ?? NativeReaderError.network.errorDescription
            if error as? NativeReaderError == .notLoggedIn { onAuthenticationRequired() }
        }
    }

    /// 復帰時は保持中のページを使う。期限はselectで再確認し、足りない先読みだけを進める。
    func resume(page: Int, now: Date = Date()) {
        select(page: page, now: now)
    }

    /// 自動へ切り替えるときや、同じ画質の受信済み画像はそのまま使う。
    func setImageQuality(_ quality: ReaderImageQuality) {
        guard quality != imageQuality else { return }
        imageQuality = quality
        automaticQuality = ReaderAutomaticQuality()
        cancelPageWork()
        let retained = Set(pageQualities.keys.filter { quality == .automatic || pageQualities[$0] == quality })
        pageData = pageData.filter { retained.contains($0.key) }
        images = images.filter { retained.contains($0.key) }
        pageQualities = pageQualities.filter { retained.contains($0.key) }
        previews.removeAll()
        previewFailures.removeAll()
        deferredPages.removeAll()
        errors.removeAll()
        select(page: current)
    }

    func setActive(_ active: Bool) {
        loadTiming.setActive(active)
    }

    func setContinuousScrolling(_ enabled: Bool) {
        guard enabled != continuousScrolling else { return }
        continuousScrolling = enabled
        visiblePages.removeAll()
        select(page: current)
    }

    func setVisiblePages(_ pages: Set<Int>) {
        guard continuousScrolling, let document else { return }
        let visible = Set(pages.filter { $0 > 0 && $0 <= document.pages.count }
            .sorted { abs($0 - current) < abs($1 - current) }.prefix(6))
        guard visible != visiblePages else { return }
        visiblePages = visible
        deferredPages.subtract(visible)
        select(page: current)
    }

    func select(page: Int, now: Date = Date()) {
        guard let document else { return }
        if let expiry = document.expiresAt, expiry <= now {
            close()
            error = NativeReaderError.notEntitled.errorDescription
            return
        }
        let target = min(max(page, 1), document.pages.count + 1)
        if target != current { deferredPages.removeAll() }
        current = target
        // 公式と同じ範囲と優先順。現在を含む前方5・後方3ページを受信しておく。
        let usualOrder = (-3...4).sorted {
            ($0 < 0 ? 1 - 4 * $0 : 2 * $0) < ($1 < 0 ? 1 - 4 * $1 : 2 * $1)
        }.map { current + $0 }.filter { $0 > 0 && $0 <= document.pages.count }
        let visible = continuousScrolling && !visiblePages.isEmpty ? visiblePages : Set([current])
        let first = visible.min() ?? current
        let last = visible.max() ?? current
        let nearVisible = [last + 1, first - 1, last + 2, first - 2]
        var seen: Set<Int> = []
        let ordered = continuousScrolling
            ? ([current] + visible.sorted { abs($0 - current) < abs($1 - current) } + nearVisible + usualOrder)
                .filter { $0 > 0 && $0 <= document.pages.count && seen.insert($0).inserted }
            : usualOrder
        let wanted = Set(ordered)
        let drawable = continuousScrolling
            ? Set(ordered.filter { visible.contains($0) || [first - 1, last + 1, last + 2].contains($0) }.prefix(8))
            : Set([current, current + 1, current + 2, current - 1].filter { wanted.contains($0) })
        let downloadLimit = continuousScrolling ? 3 : 2
        for number in Array(pageTasks.keys) where !wanted.contains(number) {
            pageTasks.removeValue(forKey: number)?.cancel()
        }
        for number in Array(renderTasks.keys) where !drawable.contains(number) {
            renderTasks[number]?.cancel()
        }
        for number in Array(previewTasks.keys) where !wanted.contains(number) || (continuousScrolling && drawable.contains(number)) {
            previewTasks.removeValue(forKey: number)?.cancel()
        }
        // 移動先の通信を先読みの空き待ちにしない。最も遠い先読みを譲る。
        if wanted.contains(current), pageData[current] == nil, images[current] == nil,
           pageTasks[current] == nil, errors[current] == nil, pageTasks.count >= downloadLimit,
           let last = ordered.reversed().first(where: { pageTasks[$0] != nil }) {
            pageTasks.removeValue(forKey: last)?.cancel()
        }
        if continuousScrolling {
            // 同時に見えているページも、遠い先読みの空き待ちにしない。
            let waiting = visible.filter { pageData[$0] == nil && images[$0] == nil && pageTasks[$0] == nil && errors[$0] == nil && !deferredPages.contains($0) }.count
            while pageTasks.count + waiting > downloadLimit,
                  let far = ordered.reversed().first(where: { pageTasks[$0] != nil && !visible.contains($0) && $0 != current }) {
                pageTasks.removeValue(forKey: far)?.cancel()
            }
        }
        pageData = pageData.filter { wanted.contains($0.key) }
        // 受信済みデータは64MiBまで。大きなページで退避した分は移動するまで再取得しない。
        var bytes = pageData.values.reduce(0) { $0 + $1.count }
        for number in ordered.reversed() where bytes > 64 * 1024 * 1024 && number != current {
            if let removed = pageData.removeValue(forKey: number) {
                bytes -= removed.count
                deferredPages.insert(number)
            }
        }
        let retainedImages = continuousScrolling
            ? drawable.union(images.keys.filter { !drawable.contains($0) }
                .sorted { abs($0 - current) < abs($1 - current) }.prefix(max(0, 8 - drawable.count)))
            : drawable
        images = images.filter { retainedImages.contains($0.key) }
        pageQualities = pageQualities.filter { pageData[$0.key] != nil || images[$0.key] != nil }
        previews = previews.filter { wanted.contains($0.key) }
        errors = errors.filter { wanted.contains($0.key) }
        previewFailures.formIntersection(wanted)
        // 受信と描画を別に進める。2ページ先まで描き、続けてめくっても展開を待たせない。
        for number in ordered where pageTasks.count < downloadLimit {
            load(page: number)
        }
        for number in ordered {
            if drawable.contains(number), renderTasks.isEmpty { render(page: number) }
            if previewTasks.count < 2, !continuousScrolling || !drawable.contains(number) { loadPreview(page: number) }
        }
    }

    private func load(page: Int) {
        guard pageData[page] == nil, images[page] == nil, !deferredPages.contains(page), errors[page] == nil, pageTasks[page] == nil,
              let document, let service, page > 0, page <= document.pages.count else { return }
        let source = document.pages[page - 1]
        let ticket = imageGeneration.value
        let priority = page == current || (continuousScrolling && (visiblePages.contains(page) || abs(page - current) <= 2))
            ? URLSessionTask.highPriority : URLSessionTask.lowPriority
        pageTasks[page] = Task { [weak self] in
            do {
                guard let self else { return }
                let (data, quality) = try await self.download(source, service: service, priority: priority, ticket: ticket)
                guard self.imageGeneration.accepts(ticket), !Task.isCancelled else { return }
                self.pageTasks[page] = nil
                self.pageData[page] = data
                self.pageQualities[page] = quality
                self.select(page: self.current)
            } catch {
                guard let self, self.imageGeneration.accepts(ticket), !Task.isCancelled else { return }
                self.pageTasks[page] = nil
                self.errors[page] = (error as? NativeReaderError)?.errorDescription ?? NativeReaderError.network.errorDescription
                self.select(page: self.current)
            }
        }
    }

    /// 自動画質の高画質通信だけに一度の待ち時間を設け、遅ければ同じページの縮小画像へ切り替える。
    private func download(_ source: NativeReaderDocument.Page, service: NativeReaderLoading,
                          priority: Float, ticket: UUID) async throws -> (Data, ReaderImageQuality) {
        let automatic = imageQuality == .automatic
        let sample = automatic ? loadTiming.sample() : nil
        var quality = automatic ? automaticQuality.quality : imageQuality
        if automatic, quality == .low, source.previewURL == nil { quality = .high }
        if automatic, quality == .high, let preview = source.previewURL,
           NativeReaderDocument.allowedImageURL(preview) {
            do {
                let data = try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await service.data(for: source, priority: priority) }
                    group.addTask {
                        try await self.loadTiming.waitForLimit(sample, seconds: ReaderAutomaticQuality.highWaitSeconds)
                        throw CancellationError()
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation()
                guard imageGeneration.accepts(ticket) else { throw CancellationError() }
                return (data, .high)
            } catch ReaderImageLoadTiming.LimitReached.slow {
                try Task.checkCancellation()
                guard imageGeneration.accepts(ticket) else { throw CancellationError() }
                automaticQuality.highTimedOut()
                quality = .low
            }
        }
        let revision = automaticQuality.revision
        let lowSample = automatic && quality == .low ? loadTiming.sample() : nil
        let data = try await service.data(for: quality.source(for: source), priority: priority)
        try Task.checkCancellation()
        guard imageGeneration.accepts(ticket) else { throw CancellationError() }
        if automatic, quality == .low, let elapsed = loadTiming.elapsed(lowSample) {
            automaticQuality.receivedLow(seconds: elapsed, revision: revision)
        }
        return (data, quality)
    }

    private func render(page: Int) {
        guard images[page] == nil, errors[page] == nil, renderTasks[page] == nil,
              let data = pageData[page], let document, let service else { return }
        let source = document.pages[page - 1]
        let ticket = imageGeneration.value
        guard let quality = pageQualities[page] else { return }
        renderTasks[page] = Task { [weak self] in
            do {
                let image = try await service.render(data, for: quality.source(for: source))
                guard let self, self.imageGeneration.accepts(ticket) else { return }
                self.renderTasks[page] = nil
                if !Task.isCancelled { self.images[page] = image }
                self.select(page: self.current)
            } catch {
                guard let self, self.imageGeneration.accepts(ticket) else { return }
                self.renderTasks[page] = nil
                if !Task.isCancelled, !(error is CancellationError) {
                    self.errors[page] = (error as? NativeReaderError)?.errorDescription ?? NativeReaderError.invalidImage.errorDescription
                }
                self.select(page: self.current)
            }
        }
    }

    private func loadPreview(page: Int) {
        guard imageQuality == .high,
              previews[page] == nil, images[page] == nil, !previewFailures.contains(page), previewTasks[page] == nil,
              let document, let service, page > 0, page <= document.pages.count,
              document.pages[page - 1].previewURL != nil else { return }
        let source = document.pages[page - 1]
        let ticket = imageGeneration.value
        previewTasks[page] = Task { [weak self] in
            let image = try? await service.preview(for: source)
            guard let self, self.imageGeneration.accepts(ticket), !Task.isCancelled else { return }
            self.previewTasks[page] = nil
            if let image { self.previews[page] = image } else { self.previewFailures.insert(page) }
            self.select(page: self.current)
        }
    }

    private func cancelPageWork() {
        imageGeneration.advance()
        pageTasks.values.forEach { $0.cancel() }
        pageTasks.removeAll()
        renderTasks.values.forEach { $0.cancel() }
        renderTasks.removeAll()
        previewTasks.values.forEach { $0.cancel() }
        previewTasks.removeAll()
        loadTiming.cancelAll()
    }

    private func clearPageImages() {
        cancelPageWork()
        pageData.removeAll()
        pageQualities.removeAll()
        previews.removeAll()
        previewFailures.removeAll()
        deferredPages.removeAll()
        images.removeAll()
        errors.removeAll()
    }

    func close() {
        generation.advance()
        expiryTask?.cancel()
        expiryTask = nil
        clearPageImages()
        automaticQuality = ReaderAutomaticQuality()
        service?.close()
        service = nil
        document = nil
        content = nil
        loading = false
        error = nil
        current = 1
        visiblePages.removeAll()
    }
}
