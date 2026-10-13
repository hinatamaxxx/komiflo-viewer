import SwiftUI

struct MagazineHeaderBranding {
    let slug: String
    let name: String
}

/// 透明な余白を除いた共通のロゴを、表示枠の中へ収める。
struct AutomaticMagazineLogo: View {
    let slug: String
    let name: String
    var fittingHeight: CGFloat?
    var maximumWidth: CGFloat
    var alignment: Alignment
    var fitsContent: Bool
    var onSize: ((CGSize) -> Void)?
    @State private var image: UIImage?
    @State private var loadedRow: Int?

    private var row: Int? { MagazineIdentity.rows[slug] }
    private var displayedImage: UIImage? {
        loadedRow == row ? image : row.flatMap { ImageCache.shared.memoryMagazineLogo(row: $0) }
    }
    private var imageAspect: CGFloat {
        displayedImage.map { $0.size.width / $0.size.height } ?? MagazineLogo.rowAspect
    }
    private var fittingWidth: CGFloat? {
        guard let fittingHeight else { return nil }
        return min(maximumWidth, fittingHeight * imageAspect)
    }
    private var displayedHeight: CGFloat? {
        guard fitsContent, let fittingHeight, let fittingWidth else { return fittingHeight }
        return min(fittingHeight, fittingWidth / imageAspect)
    }

    init(slug: String, name: String, fittingHeight: CGFloat? = nil, maximumWidth: CGFloat = .infinity,
         alignment: Alignment = .leading, fitsContent: Bool = false, onSize: ((CGSize) -> Void)? = nil) {
        self.slug = slug
        self.name = name
        self.fittingHeight = fittingHeight
        self.maximumWidth = maximumWidth
        self.alignment = alignment
        self.fitsContent = fitsContent
        self.onSize = onSize
        let row = MagazineIdentity.rows[slug]
        let cached = row.flatMap { ImageCache.shared.memoryMagazineLogo(row: $0) }
        _image = State(initialValue: cached)
        _loadedRow = State(initialValue: cached == nil ? nil : row)
    }

    var body: some View {
        GeometryReader { geometry in
            if let image = displayedImage {
                Image(uiImage: image).resizable().scaledToFit()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize?($0) }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
            } else if row == nil {
                Text(name).font(.headline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .frame(width: fittingWidth, height: displayedHeight)
        .clipped().allowsHitTesting(false).accessibilityLabel(name)
        .task(id: row) {
            guard let row else { image = nil; loadedRow = nil; return }
            if loadedRow == row, image != nil { return }
            let loaded = await ImageCache.shared.magazineLogo(row: row)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedRow = row
        }
    }
}

struct MagazineHeading: View {
    let branding: MagazineHeaderBranding
    let total: Int?
    let countUnit: String
    let width: CGFloat
    let scroll: ArtistHeaderScroll

    var body: some View {
        GeometryReader { geometry in
            let countWidth = total.map {
                ("\($0)\(countUnit)" as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)]).width
            } ?? 0
            HStack(alignment: .bottom, spacing: 8) {
                AutomaticMagazineLogo(slug: branding.slug, name: branding.name, fittingHeight: 48,
                                      maximumWidth: min(MagazineLogo.tileLogoWidth(in: width), max(0, geometry.size.width - countWidth - 8)), alignment: .bottomLeading,
                                      onSize: { if $0.height > 0 { scroll.magazineLogoHeight = $0.height } })
                count
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 48)
        }
        .frame(height: 48)
    }

    @ViewBuilder private var count: some View {
        if let total {
            Text("\(total)\(countUnit)").font(.caption)
                .foregroundStyle(.white.opacity(0.85)).fixedSize()
                .shadow(color: .black.opacity(0.7), radius: 3)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll.countTextHeight = $0 }
        }
    }
}

/// ロゴと号数をそれぞれ元の位置で切り、同じ境界から登らせる。
struct MagazineCompactHeading: View {
    let branding: MagazineHeaderBranding
    let total: Int?
    let countUnit: String
    let width: CGFloat
    @ObservedObject var scroll: ArtistHeaderScroll
    let layout: ArtistHeaderLayout
    @State private var logoHeight: CGFloat = 42
    @State private var countSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 8) {
                AutomaticMagazineLogo(slug: branding.slug, name: branding.name, fittingHeight: 42,
                                      maximumWidth: min(MagazineLogo.tileLogoWidth(in: width), max(0, geometry.size.width - countSize.width - 8)), alignment: .bottomLeading,
                                      onSize: { if $0.height > 0 { logoHeight = $0.height } })
                    .offset(y: risingTop(sourceHeight: scroll.magazineLogoHeight, height: logoHeight) - (42 - logoHeight))
                if let total {
                    Text("\(total)\(countUnit)").font(.caption)
                        .foregroundStyle(.white.opacity(0.85)).fixedSize()
                        .shadow(color: .black.opacity(0.7), radius: 3)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { countSize = $0 }
                        .offset(y: risingTop(sourceHeight: scroll.countTextHeight, height: countSize.height))
                }
            }
        }
        .frame(height: ArtistHeaderLayout.controlsHeight)
        .clipped().allowsHitTesting(false)
    }

    private func risingTop(sourceHeight: CGFloat, height: CGFloat) -> CGFloat {
        let targetBottom = ArtistHeaderLayout.controlsHeight - ArtistHeaderLayout.magazineBottomInset
        return layout.risingTop(sourceTop: layout.magazineSourceBottom - sourceHeight,
                                sourceHeight: sourceHeight, targetTop: targetBottom - height,
                                targetHeight: height, offset: scroll.offset)
    }
}

struct HomeMagazineArtwork: ViewModifier {
    let comic: ComicSummary
    let enabled: Bool
    let library: LibraryStore
    var atBottom = false
    var magazine: MagazineIdentity?
    @State private var resolved: MagazineIdentity?
    @State private var resolvedID: Int?

    init(comic: ComicSummary, enabled: Bool, library: LibraryStore,
         atBottom: Bool = false, magazine: MagazineIdentity? = nil) {
        self.comic = comic
        self.enabled = enabled
        self.library = library
        self.atBottom = atBottom
        self.magazine = magazine
        _resolved = State(initialValue: enabled && magazine == nil ? library.cachedComicMagazine(id: comic.id) : nil)
        _resolvedID = State(initialValue: comic.id)
    }

    private var identity: MagazineIdentity? {
        if comic.isKomifloOriginal == true { return .original }
        if let magazine { return MagazineIdentity.display(comic: comic, in: magazine) }
        return (resolvedID == comic.id ? resolved : nil) ?? MagazineIdentity.display(comic: comic, in: magazine)
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: atBottom ? .bottomLeading : .topLeading) {
            if enabled, let identity {
                MagazineThumbnailLogo(identity: identity, atBottom: atBottom)
            }
        }
        .task(id: comic.id) {
            guard enabled, MagazineIdentity.needsLookup(comic: comic, in: magazine) else { return }
            // 簡略一覧だけ、既存の作品情報と保存済み応答を共用して調べる。
            let identity = await library.comicMagazine(id: comic.id)
            guard !Task.isCancelled else { return }
            resolved = identity
            resolvedID = comic.id
        }
    }
}

/// 雑誌が分かっている表紙にも、同じロゴ枠と透明度を使う。
struct MagazineThumbnailLogo: View {
    let identity: MagazineIdentity
    var atBottom = false
    @AppStorage(MagazineLogoBackground.transparencyKey) private var backgroundTransparency = MagazineLogoBackground.defaultTransparency

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = atBottom ? min(6, geometry.size.width * 0.05) : 6
            let logoWidth = max(0, geometry.size.width - (atBottom ? inset * 2 : 84))
            let logoHeight = atBottom ? min(38, geometry.size.height * 0.2, logoWidth * 0.38) : 38
            let padding: CGFloat = atBottom ? 3 : 4
            Group {
                if MagazineIdentity.rows[identity.slug] != nil {
                    AutomaticMagazineLogo(slug: identity.slug, name: identity.name,
                                          fittingHeight: max(0, logoHeight - padding * 2),
                                          maximumWidth: max(0, logoWidth - padding * 2), fitsContent: true)
                        .padding(padding)
                } else {
                    Text(identity.name).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(padding)
                        .frame(width: logoWidth, height: logoHeight)
                }
            }
            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
            .background {
                MagazineLogoBackground(transparency: backgroundTransparency)
            }
            .padding(inset)
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: atBottom ? .bottomLeading : .topLeading)
        }.allowsHitTesting(false)
    }
}

struct MagazineLogoBackground: View {
    static let transparencyKey = "layout.magazineLogoTransparency"
    static let defaultTransparency: Double = 0.3
    let transparency: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(.thinMaterial)
            .opacity(1 - min(1, max(0, transparency)))
    }
}
