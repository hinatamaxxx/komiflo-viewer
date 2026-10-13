import SwiftUI

/// タグのページ（公式の /category/<slug> と同じ作り）：
/// 上にタグ名とフォローボタン、表紙カードの2列グリッド。番号と横スワイプでページを切り替える。
/// アプリ独自の「タグの掛け合わせ」は右上のメニューから
struct TagPageView: View {
    enum Source {
        case id(Int)
        case slug(String)
    }

    let source: Source
    let title: String
    @ObservedObject var library: LibraryStore
    var headerImageURL: URL?
    var options: TagListingOptions = .init()
    let homeComics: [ComicSummary]
    @Environment(\.dismiss) private var dismiss

    @State private var tagID: Int?
    @State private var tagName = ""
    @State private var tagImageURL: URL?
    @State private var headerCandidateURL: URL?
    @State private var headerThumbnail: TagHeaderThumbnail.Selection?
    @State private var extraTags: [KFAttribute] = []
    @State private var feeds: [Int: ChronologicalComicFeed] = [:]
    @State private var page = 0
    @State private var pageCount = 1
    @State private var total: Int?
    @State private var loadGeneration = 0
    @State private var isPickingTag = false
    @State private var pendingTags: [KFAttribute]?
    @State private var pendingRequest: TagCombinationRequest?
    @State private var followToggledAt: Date?
    @StateObject private var pageProgress = PagerProgress()

    init(source: Source, title: String, library: LibraryStore,
         headerImageURL: URL? = nil, options: TagListingOptions = .init(), homeComics: [ComicSummary] = []) {
        self.source = source
        self.title = title
        self.library = library
        self.headerImageURL = headerImageURL
        self.options = options
        self.homeComics = homeComics
        if options.initialPage == 0, headerImageURL == nil, !homeComics.contains(where: \.isCoverExpired) {
            _headerCandidateURL = State(initialValue: homeComics.first?.coverURL)
        }
        _page = State(initialValue: max(0, options.initialPage))
        _pageCount = State(initialValue: max(1, options.initialPage + 1))
    }

    private var pages: [Int] { Array(0..<pageCount) }

    private var displayTitle: String {
        let name: String
        switch source {
        case .id: name = title
        case .slug: name = tagName
        }
        return ([name] + extraTags.map(\.name)).joined(separator: " + ")
    }

    var body: some View {
        ImageHeaderPagedPage(items: pages, selection: $page, footerHeight: 44, progress: pageProgress) { width, layout, scroll in
            ImagePageHeader(artist: nil, title: displayTitle, total: total,
                            width: width, layout: layout, scroll: scroll,
                            isFollowing: tagID.map { library.followedIDs.contains($0) } ?? false,
                            followAnimated: followToggledAt.map { Date().timeIntervalSince($0) < 3 } ?? false,
                            onFollow: tagID == nil ? nil : toggleFollow, onBack: { dismiss() },
                            bannerURL: headerImageURL ?? tagImageURL ?? headerThumbnail?.url,
                            bannerFocus: headerImageURL == nil && tagImageURL == nil ? headerThumbnail?.focus : nil,
                            bannerProtectedHead: headerImageURL == nil && tagImageURL == nil ? headerThumbnail?.protectedHead : nil,
                            sectionPicker: AnyView(pagePicker.background(Theme.background)),
                            topTrailing: { AnyView(combinationMenu(height: $0)) }, followCrossesBoundary: true)
        } content: { item, width, minimumHeight in
            VStack(alignment: .leading, spacing: 16) {
                if !extraTags.isEmpty { extraTagChips.padding(.horizontal, 15 * OfficialMetrics.scale) }
                ChronologicalComicList(feed: displayFeed(page: item), library: library,
                                           isActive: page == item, loadsMoreAutomatically: false,
                                           emptyTitle: extraTags.isEmpty ? "作品がありません" : "該当する作品がありません",
                                           emptyMessage: extraTags.isEmpty ? "このタグの作品は見つかりませんでした。"
                                               : "選んだタグの組み合わせに当てはまる作品はありませんでした。") {
                        await load(page: item, refreshing: true)
                    }
                    .frame(width: width)
                    .frame(minHeight: minimumHeight, alignment: .top)
                    .id(loadGeneration)
                    .transition(.opacity)
                    .opacity(pendingRequest != nil && !isPickingTag ? 0.5 : 1)
                    .allowsHitTesting(pendingRequest == nil)
                    .overlay {
                        if pendingRequest != nil && !isPickingTag {
                            ProgressView("読み込み中")
                                .padding(16)
                                .background(Theme.bar, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
            }
            .padding(.vertical, 12)
            .frame(width: width)
        }
        .sheet(isPresented: $isPickingTag, onDismiss: applyPickedTags) {
            TagPickerSheet(
                library: library,
                baseName: tagName.isEmpty ? title : tagName,
                excludedIDs: Set([tagID].compactMap { $0 }),
                initialTags: extraTags
            ) { tags in
                prepareTagChange(tags)
            }
        }
        .onDisappear {
            pendingRequest?.cancel()
            pendingRequest = nil
            pendingTags = nil
        }
        .task { await load(page: page) }
        .onChange(of: page) { _, value in
            Task { await load(page: value) }
        }
        .task(id: headerCandidateURL) {
            // 一覧更新でURLが変わっても、画像と切り抜き位置が揃ってから一緒に差し替える。
            do {
                let selected = try await TagHeaderThumbnail.select(url: headerCandidateURL)
                guard !Task.isCancelled else { return }
                headerThumbnail = selected
            } catch {
                guard !Task.isCancelled else { return }
                headerThumbnail = headerCandidateURL.map { .init(url: $0, focus: nil, protectedHead: nil) }
                library.actionError = error.localizedDescription
            }
        }
        .task { if !library.hasLoadedFollows { await library.loadFollows() } }
        .markErrorAlert(library)
    }

    private var pagePicker: some View {
        PagerTabs(items: pages, selection: $page, progress: pageProgress, scrolls: true,
                  font: .footnote.weight(.semibold), title: { String($0 + 1) })
            .frame(height: 32)
            .padding(.vertical, 6)
    }

    private func displayFeed(page item: Int) -> ChronologicalComicFeed {
        let feed = feeds[item] ?? ChronologicalComicFeed()
        // ホームの一部を表示に使う。正式な1ページの取得状態・総数には数えない。
        return item == 0 && options.initialPage == 0 && extraTags.isEmpty
            ? feed.previewing(homeComics) : feed
    }
    private func combinationMenu(height: CGFloat) -> some View {
        Menu {
            Button {
                isPickingTag = true
            } label: {
                Label("タグを掛け合わせる", systemImage: "plus")
            }
            .disabled(tagID == nil || pendingRequest != nil)
            if !extraTags.isEmpty {
                Button(role: .destructive) {
                    prepareTagChange([])
                    applyPickedTags()
                } label: {
                    Label("掛け合わせをやめる", systemImage: "xmark")
                }
            }
        } label: {
            HStack(spacing: height * 0.09) {
                ForEach(0..<3) { _ in
                    Circle().frame(width: height * 0.1, height: height * 0.1)
                }
            }
            .foregroundStyle(Theme.accent)
            .frame(width: height, height: height)
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: ReaderPillFill.borderWidth))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tint(Theme.accent)
        .accessibilityLabel("タグのメニュー")
    }

    private func toggleFollow() {
        guard let tagID else { return }
        followToggledAt = Date()
        Task { await library.toggleFollow(attributeID: tagID) }
    }

    private var extraTagChips: some View {
        // 掛け合わせ中のタグ（×で外す）
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(extraTags) { tag in
                    Button {
                        prepareTagChange((pendingTags ?? extraTags).filter { $0.id != tag.id })
                        applyPickedTags()
                    } label: {
                        HStack(spacing: 4) {
                            Text("+ \(tag.name)")
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.3), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func prepareTagChange(_ tags: [KFAttribute]) {
        guard let tagID else { return }
        pendingRequest?.cancel()
        pendingTags = tags
        var listingOptions = tags.isEmpty ? options : TagListingOptions()
        listingOptions.sort = nil
        pendingRequest = TagCombinationRequest(api: library.api, ids: [tagID] + tags.map(\.id), options: listingOptions)
    }

    private func applyPickedTags() {
        guard let request = pendingRequest, let tags = pendingTags else { return }
        Task {
            do {
                let result = try await request.task.value
                guard pendingRequest?.id == request.id else { return }
                guard request.cacheGeneration == APICache.generation else {
                    pendingRequest = nil
                    pendingTags = nil
                    return
                }
                var contents = result.response.results ?? []
                if tags.isEmpty, options.fromTop, let tagID {
                    var generator = DailyShuffle(seed: tagID)
                    contents = generator.shuffle(contents)
                }
                let count = result.response.total ?? (result.response.totalPages == 1 ? contents.count : nil)
                var feed = ChronologicalComicFeed()
                guard feed.replacePage(contents.map(\.summary), requestedPage: 0, returnedPage: result.response.page,
                                       pages: result.response.totalPages, count: count) else { return }
                // 外枠とヘッダーは保持し、閉じた後に用意済みの一覧だけを入れ替える。
                withAnimation(.easeOut(duration: 0.2)) {
                    extraTags = tags
                    feeds = [0: feed]
                    page = 0
                    pageCount = max(1, result.response.totalPages ?? 1)
                    total = count
                    loadGeneration += 1
                    pendingRequest = nil
                    pendingTags = nil
                }
                let generation = loadGeneration
                await load(page: 0, refreshing: true, preparedResponse: result.response)
                if result.fromCache, generation == loadGeneration {
                    await load(page: 0, refreshing: true)
                }
            } catch {
                guard pendingRequest?.id == request.id else { return }
                pendingRequest = nil
                pendingTags = nil
                if !(error is CancellationError) { library.actionError = error.localizedDescription }
            }
        }
    }

    private func load(page item: Int, refreshing: Bool = false, preparedResponse: KFContentListResponse? = nil) async {
        var feed = feeds[item] ?? ChronologicalComicFeed()
        guard !feed.hasLoaded || refreshing else { return }
        feed.nextPage = item
        guard let requestedPage = feed.beginLoad(continuing: refreshing) else { return }
        let generation = loadGeneration
        let cacheGeneration = APICache.generation
        let token = feed.token
        feeds[item] = feed
        do {
            if tagID == nil {
                switch source {
                case .id(let id):
                    tagID = id
                    tagName = title
                case .slug(let slug):
                    let tag: KFAttribute
                    if let cached = try? await APICache.fromCache({ try await library.api.attribute(slug: slug) }) {
                        tag = cached
                    } else {
                        tag = try await library.api.attribute(slug: slug)
                    }
                    try Task.checkCancellation()
                    guard generation == loadGeneration, feeds[item]?.token == token else { return }
                    tagID = tag.id
                    tagName = tag.name
                    tagImageURL = tag.bannerURL
                }
            }
            guard let tagID else { throw KomifloAPIError.invalidResponse }
            let ids = [tagID] + extraTags.map(\.id)
            var listingOptions = extraTags.isEmpty ? options : TagListingOptions()
            listingOptions.sort = nil

            // 履歴と同じ応答キャッシュで先に表示し、通常の取得で新しい内容へ更新する。
            if !refreshing, preparedResponse == nil, let cached = try? await APICache.fromCache({
                try await library.api.attributeContents(attributeIDs: ids, page: requestedPage, options: listingOptions)
            }), !(cached.results ?? []).contains(where: { $0.summary.isCoverExpired }) {
                publish(cached)
            }

            @discardableResult
            func publish(_ response: KFContentListResponse) -> Bool {
                guard !Task.isCancelled, generation == loadGeneration, cacheGeneration == APICache.generation,
                      ids == [tagID] + extraTags.map(\.id), var current = feeds[item], current.token == token else { return false }
                var contents = response.results ?? []
                if listingOptions.fromTop {
                    var generator = DailyShuffle(seed: tagID)
                    contents = generator.shuffle(contents)
                }
                let count = response.total ?? (response.totalPages == 1 ? contents.count : nil)
                guard current.replacePage(contents.map(\.summary), requestedPage: requestedPage, returnedPage: response.page,
                                          pages: response.totalPages, count: count) else { return false }
                feeds[item] = current
                pageCount = max(1, response.totalPages ?? 1)
                if let count { total = count }
                if requestedPage == options.initialPage, extraTags.isEmpty, headerImageURL == nil, tagImageURL == nil {
                    headerCandidateURL = contents.first?.coverURL
                }
                return true
            }

            let response: KFContentListResponse
            if let preparedResponse {
                response = preparedResponse
            } else {
                response = try await library.api.attributeContents(attributeIDs: ids, page: requestedPage, options: listingOptions)
            }
            try Task.checkCancellation()
            guard response.page == nil || response.page == requestedPage else { throw KomifloAPIError.invalidResponse }
            guard publish(response) else { return }

            // 作品数の計算は一覧の表示を待たせない。最終ページも保存済みなら通信しない。
            let pages = response.totalPages ?? 1
            if total == nil, requestedPage == 0, pages > 1 {
                let lastCount: Int?
                if let saved = feeds[pages - 1], saved.hasLoaded {
                    lastCount = saved.comics.count
                } else {
                    let last: KFContentListResponse?
                    if let cached = try? await APICache.fromCache({
                        try await library.api.attributeContents(attributeIDs: ids, page: pages - 1, options: listingOptions)
                    }) {
                        last = cached
                    } else {
                        last = try? await library.api.attributeContents(attributeIDs: ids, page: pages - 1, options: listingOptions)
                    }
                    lastCount = last?.page == pages - 1 ? last?.results?.count : nil
                }
                guard !Task.isCancelled, generation == loadGeneration, cacheGeneration == APICache.generation,
                      ids == [tagID] + extraTags.map(\.id), feeds[item]?.token == token else { return }
                if let lastCount {
                    total = (pages - 1) * (response.pageSize ?? response.results?.count ?? 0) + lastCount
                }
            }
        } catch {
            guard generation == loadGeneration, var current = feeds[item], current.token == token else { return }
            current.isLoading = false
            if !Task.isCancelled, !(error is CancellationError) { current.error = error.localizedDescription }
            feeds[item] = current
        }
    }
}
