import SwiftUI

/// お知らせ（公式の /notifications と同じ作り）：
/// フォロー中の作家・タグの新着を日付ごとに。1件ずつ、表紙・作品名・フォローのきっかけ（作家・タグ）・♥数・コメント数
struct NotificationsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全て"
        case artists = "作家"
        case tags = "タグ"
        case follows = "フォロー"
        var id: String { rawValue }
    }

    @ObservedObject var library: LibraryStore

    @Environment(\.openRoute) private var openRoute
    @State private var tabProgress = PagerProgress()
    @State private var filter: Filter = .all
    @State private var items: [KFContent] = []
    @State private var page = 0
    @State private var totalPages: Int?
    @State private var isLoading = false
    @State private var error: String?

    private var hasMore: Bool { totalPages.map { page < $0 } ?? true }

    /// 公式のリンクの青（rgb 66, 143, 205）
    private static let linkBlue = Color(red: 66 / 255, green: 143 / 255, blue: 205 / 255)

    private func visibleItems(for filter: Filter) -> [KFContent] {
        switch filter {
        case .all:
            return items
        case .artists:
            return items.filter { item in item.artists.contains { $0.id.map(library.followedIDs.contains) ?? false } }
        case .tags:
            return items.filter { item in item.tags.contains { $0.id.map(library.followedIDs.contains) ?? false } }
        case .follows:
            return []
        }
    }

    private struct DaySection: Identifiable {
        let day: Date
        let items: [KFContent]
        var id: Date { day }
    }

    private func sections(for filter: Filter) -> [DaySection] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        var result: [DaySection] = []
        for item in visibleItems(for: filter) {
            let day = calendar.startOfDay(for: item.published ?? .distantPast)
            if let last = result.last, last.day == day {
                result[result.count - 1] = DaySection(day: day, items: last.items + [item])
            } else {
                result.append(DaySection(day: day, items: [item]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabs(items: Filter.allCases, selection: $filter, progress: tabProgress, title: { $0.rawValue })
            .padding(.horizontal, 15 * OfficialMetrics.scale)
            .frame(height: 56)

            // フォローリストも同じ切り替えと左右スワイプで開く。
            PagedView(items: Filter.allCases, selection: $filter, commitsSelectionOnIdle: true, progress: tabProgress) { option in
                if option == .follows {
                    FollowList(library: library)
                } else {
                    page(for: option)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("お知らせ")
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        .task { if items.isEmpty { await loadMore() } }
        .task { if !library.hasLoadedFollows { await library.loadFollows() } }
        .task { await library.refreshLikedIDs() }
        .markErrorAlert(library)
    }

    /// 1ページ分（日付ごとの見出しと、その日のお知らせ）
    private func page(for option: Filter) -> some View {
        let visible = visibleItems(for: option)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty, let error {
                    EmptyState(title: "読み込めませんでした", systemImage: "exclamationmark.triangle", message: error)
                        .frame(height: 260)
                } else if items.isEmpty, isLoading || hasMore {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 260)
                } else if visible.isEmpty {
                    EmptyState(title: "お知らせはありません", systemImage: "bell", message: "フォロー中の作家・タグの新着がここに届きます。")
                        .frame(height: 260)
                }

                ForEach(sections(for: option)) { section in
                    // 公式と同じ、日付の見出し（中央・灰色）
                    Text(section.day.formatted(.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "ja_JP"))))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.sectionTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                        .padding(.bottom, 10)
                    ForEach(section.items, id: \.id) { item in
                        row(item)
                            .onAppear {
                                if item.id == visible.last?.id { Task { await loadMore() } }
                            }
                    }
                }

                if isLoading, !items.isEmpty {
                    LoadingFooter()
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await reload() }
    }
    /// 1件（左に表紙、右に作品名・フォローのきっかけ・♥とコメントの数）
    private func row(_ item: KFContent) -> some View {
        let comic = item.summary
        let isLiked = library.likedIDs.contains(item.id)
        let reasons = (item.artists + item.tags).filter { $0.id.map(library.followedIDs.contains) ?? false }
        return HStack(alignment: .top, spacing: 21 * OfficialMetrics.scale) {
            ComicCoverButton(comic: comic, library: library)
                .frame(width: 152 * OfficialMetrics.scale)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    openRoute(.comic(id: item.id))
                } label: {
                    Text(item.title ?? "")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Self.linkBlue)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)

                if !reasons.isEmpty {
                    Text("下記をフォローしています")
                        .font(.caption2)
                        .foregroundStyle(Theme.sectionTitle)
                    ForEach(reasons, id: \.self) { reason in
                        Button {
                            if let slug = reason.slug, item.artists.contains(reason) {
                                openRoute(.artist(slug: slug, name: reason.name))
                            } else if let id = reason.id {
                                openRoute(.tag(id: id, name: reason.name))
                            }
                        } label: {
                            Text(reason.name)
                                .lineLimit(1)
                                .modifier(FollowAttributeStyle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 14) {
                    Button {
                        Task { await library.toggleLike(item.id) }
                    } label: {
                        Label("\(item.likesCount ?? 0)", systemImage: isLiked ? "heart.fill" : "heart")
                            .foregroundStyle(isLiked ? Theme.accent : Theme.sectionTitle)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(library.pendingIDs.contains(item.id))
                    .accessibilityLabel(isLiked ? "いいねを取り消す" : "いいねする")
                    CommentsButton(contentID: item.id, title: item.title ?? "", library: library) {
                        Label("\(item.commentsCount ?? 0)", systemImage: "bubble.left")
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("コメント\(item.commentsCount ?? 0)件を表示")
                }
                .font(.footnote)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15 * OfficialMetrics.scale)
        .padding(.vertical, 10)
    }

    private func reload() async {
        items = []
        page = 0
        totalPages = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            // Komifloのページは0始まり
            let response = try await library.api.feeds(page: page)
            let known = Set(items.map(\.id))
            items += (response.results ?? []).filter { !known.contains($0.id) }
            page += 1
            totalPages = response.totalPages ?? page
            if response.results?.isEmpty ?? true { totalPages = page }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 表紙だけのボタン（タップで漫画を開く、右上に☆/★）。お知らせなど表紙を単独で置く場所で使う
struct ComicCoverButton: View {
    let comic: ComicSummary
    @ObservedObject var library: LibraryStore

    @Environment(\.openReader) private var openReader

    var body: some View {
        let isBookmarked = library.bookmarkedIDs.contains(comic.id)
        Button {
            openReader(ReaderRequest(comicID: comic.id, title: comic.title))
        } label: {
            CoverImage(url: comic.coverURL, placeholderTitle: comic.title)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await library.toggleBookmark(comic.id) }
            } label: {
                Image(systemName: isBookmarked ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isBookmarked ? Theme.star : .white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isBookmarked ? "ブックマークを外す" : "ブックマークする")
        }
        .modifier(HomeMagazineArtwork(comic: comic, enabled: true, library: library))
    }
}
