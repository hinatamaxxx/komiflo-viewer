import SwiftUI

/// 作品の詳細（表紙・作者・雑誌・タグ・★♥・読む・おすすめ）
struct ComicDetailView: View {
    let comicID: Int
    @ObservedObject var library: LibraryStore

    @Environment(\.openRoute) private var openRoute
    @Environment(\.openReader) private var openReader

    @State private var state: LoadState<KFContent> = .loading
    @State private var recommends: [ComicSummary] = []
    @State private var otherChapters: [ComicSummary] = []

    var body: some View {
        LoadStateView(state: state, retry: load) { content in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(content)
                    actions(content)
                    if !content.tags.isEmpty {
                        tags(content.tags)
                    }
                    CommentsButton(contentID: content.id, title: content.title ?? "", library: library, returnsToDetails: true) {
                        Label("コメントを開く", systemImage: "bubble.left.and.bubble.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if !otherChapters.isEmpty {
                        CoverShelf(title: "同じ号の作品", comics: otherChapters, library: library,
                                   showsMagazineLogo: true,
                                   magazine: MagazineIdentity.display(slug: content.magazineSlug, issue: content.magazine))
                    }
                    if !recommends.isEmpty {
                        CoverShelf(title: "こちらもおすすめ", comics: recommends, library: library, showsMagazineLogo: true)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
        .task { if case .loading = state { await load() } }
    }

    // MARK: - 表紙と基本情報

    private func header(_ content: KFContent) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button {
                openReader(ReaderRequest(comicID: content.id, title: content.title ?? ""))
            } label: {
                CoverImage(url: content.coverURL, placeholderTitle: content.title ?? "", cornerRadius: 6)
                    .frame(width: 132)
                    .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 6)
                    .modifier(HomeMagazineArtwork(comic: content.summary, enabled: true, library: library,
                                                  atBottom: true,
                                                  magazine: MagazineIdentity.display(comic: content.summary) ?? .unavailable))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("読む")

            VStack(alignment: .leading, spacing: 8) {
                Text(content.title ?? "無題")
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(content.artists, id: \.self) { artist in
                    if let slug = artist.slug {
                        Button {
                            openRoute(.artist(slug: slug, name: artist.name))
                        } label: {
                            Label(artist.name, systemImage: "person.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let magazine = content.magazine {
                    if let parentID = content.parentID {
                        Button {
                            openRoute(.issue(id: parentID, title: magazine))
                        } label: {
                            Label(magazine, systemImage: "books.vertical")
                                .font(.footnote)
                                .foregroundStyle(Theme.accent)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(magazine, systemImage: "books.vertical")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    if let pages = content.pageCount {
                        Label("\(pages)ページ", systemImage: "doc.on.doc")
                    }
                    if let likes = content.likesCount {
                        Label("\(likes)", systemImage: "heart")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let published = content.published {
                    Text(published.formatted(date: .long, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 読む・★・♥

    private func actions(_ content: KFContent) -> some View {
        let isBookmarked = library.bookmarkedIDs.contains(content.id)
        let isLiked = library.likedIDs.contains(content.id)
        return HStack(spacing: 10) {
            Button {
                openReader(ReaderRequest(comicID: content.id, title: content.title ?? ""))
            } label: {
                Label("読む", systemImage: "book.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            toggleButton(
                isOn: isBookmarked,
                onImage: "star.fill",
                offImage: "star",
                color: Theme.star,
                label: isBookmarked ? "ブックマークを外す" : "ブックマーク"
            ) {
                Task { await library.toggleBookmark(content.id) }
            }

            toggleButton(
                isOn: isLiked,
                onImage: "heart.fill",
                offImage: "heart",
                color: Theme.accent,
                label: isLiked ? "いいねを外す" : "いいね"
            ) {
                Task { await library.toggleLike(content.id) }
            }
        }
        .padding(.horizontal, 16)
    }

    private func toggleButton(
        isOn: Bool,
        onImage: String,
        offImage: String,
        color: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? onImage : offImage)
                .font(.title3)
                .foregroundStyle(isOn ? color : Color.primary)
                .frame(width: 52, height: 48)
                .background(Theme.bar, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - タグ

    private func tags(_ tags: [KFAttributeRef]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("タグ")
                .font(.headline)
                .padding(.horizontal, 16)
            FlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        if let id = tag.id { openRoute(.tag(id: id, name: tag.name)) }
                    } label: {
                        Text(tag.name)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.bar, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 読み込み

    private func load() async {
        // 保存してある前回の作品情報があればすぐ出し、公式から取り直して差し替える
        if case .loading = state, let saved = try? await APICache.fromCache({ try await library.api.content(id: comicID) }) {
            state = .loaded(saved)
        }
        do {
            let content = try await library.api.content(id: comicID)
            state = .loaded(content)
            recommends = ((try? await library.api.recommends(contentID: comicID)) ?? []).map(\.summary)
            if let parentID = content.parentID {
                otherChapters = (await library.issueComics(issueID: parentID) ?? [])
                    .filter { $0.id != comicID && !$0.title.contains("表紙") }
            }
        } catch {
            guard !(error is CancellationError) else { return }
            // 前回の作品情報が出ていれば、取り直しに失敗してもそのまま
            if case .loaded = state { return }
            state = .failed(error.localizedDescription)
        }
    }
}

/// タグを折り返して並べる
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
