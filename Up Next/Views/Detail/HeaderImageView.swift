import SwiftUI

/// Detail-sheet header. With a TMDB backdrop it renders full-bleed 16:9 artwork with the poster
/// floating over its bottom-leading edge; without one it falls back to the poster as the header.
struct HeaderImageView: View {
    @Environment(\.colorScheme) private var colorScheme
    let backdropPath: String?
    let posterURL: URL?
    let title: String
    /// Reports the artwork's dominant color upward whenever it's computed, so the presenting
    /// sheet can wash the same tint over its own background. Nil until the first image loads.
    var onTintChange: ((DominantTint?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Width of the view itself — only consulted at regular width, to scale the backdrop.
    @State private var availableWidth: CGFloat = 0
    /// Dominant color of whichever image is showing (backdrop, or poster in the fallback
    /// header) — drives `bottomFade` here and is mirrored to `onTintChange`.
    @State private var tint: DominantTint?

    private let compactBackdropHeight: CGFloat = 260
    /// Ceiling for the backdrop at regular width. Letting 16:9 run free in a 1000pt-wide page
    /// sheet would hand back a 560pt hero and push everything else below the fold.
    private let maxBackdropHeight: CGFloat = 420
    private let posterWidth: CGFloat = 100
    private let posterHeight: CGFloat = 150
    /// How far the floating poster hangs below the backdrop.
    private let posterOverhang: CGFloat = 60
    private let posterHeaderHeight: CGFloat = 420

    /// Fixed on iPhone; on wider layouts the artwork grows toward 16:9 but stops at the cap.
    private var backdropHeight: CGFloat {
        guard horizontalSizeClass == .regular, availableWidth > 0 else { return compactBackdropHeight }
        return min(availableWidth * 9 / 16, maxBackdropHeight)
    }

    private var backdropURL: URL? {
        TMDBService.shared.imageURL(path: backdropPath, size: .w780)
    }

    var body: some View {
        Group {
            if let backdropURL {
                backdropHeader(url: backdropURL)
            } else {
                posterHeader
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
    }

    // MARK: - Backdrop layout

    private func backdropHeader(url: URL) -> some View {
        ZStack(alignment: .topLeading) {
            parallaxImage(url: url, height: backdropHeight)
                .overlay(alignment: .bottom) { bottomFade(height: 170) }

            VStack(alignment: .leading, spacing: 0) {
                // Reserve the backdrop's height minus the overlap, so the poster row lands
                // across the header's bottom edge without an offset hack.
                Color.clear
                    .frame(height: backdropHeight - posterOverhang)

                HStack(alignment: .bottom, spacing: 14) {
                    posterThumbnail

                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(3)
                        .padding(.bottom, 6)

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Poster-only fallback

    private var posterHeader: some View {
        Group {
            if let posterURL {
                parallaxImage(url: posterURL, height: posterHeaderHeight)
            } else {
                imagePlaceholder
                    .frame(height: posterHeaderHeight)
            }
        }
        .overlay(alignment: .bottom) { bottomFade(height: 260) }
        .overlay(alignment: .bottomLeading) {
            Text(title)
                .font(.title)
                .fontWeight(.bold)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func parallaxImage(url: URL, height: CGFloat) -> some View {
        CachedAsyncImage(url: url, onLoad: applyTint) { phase in
            switch phase {
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            case .success(let image):
                if reduceMotion {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .clipped()
                } else {
                    GeometryReader { geo in
                        let minY = geo.frame(in: .scrollView).minY
                        let overscroll = max(minY, 0)
                        let scrollOffset = max(-minY, 0)

                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(
                                width: geo.size.width,
                                height: height + overscroll,
                                alignment: .top
                            )
                            .clipped()
                            .offset(y: -scrollOffset * 0.3 - overscroll)
                    }
                    .frame(height: height)
                }
            case .failure:
                imagePlaceholder
                    .frame(height: height)
            @unknown default:
                EmptyView()
            }
        }
        // Decorative: the title sits beside it and the sheet's content carries everything else.
        .accessibilityHidden(true)
    }

    private var posterThumbnail: some View {
        Group {
            if let posterURL {
                CachedAsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        imagePlaceholder
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(width: posterWidth, height: posterHeight)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.poster))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 10, y: 6)
        .accessibilityHidden(true)
    }

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .overlay {
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
    }

    /// Runs off the main actor (dominant-color extraction renders through a `CIContext`), then
    /// applies the result to `tint` and reports it to the presenting sheet. Animated unless
    /// Reduce Motion is on — the tint value itself is unaffected, only how it arrives.
    private func applyTint(from image: UIImage) {
        let animated = !reduceMotion
        Task.detached(priority: .utility) {
            let color = image.dominantTint()
            await MainActor.run {
                if animated {
                    // Report upward inside the same transaction so the sheet's top wash fades in
                    // with this fade rather than snapping.
                    withAnimation(.easeInOut(duration: 0.6)) {
                        tint = color
                        onTintChange?(color)
                    }
                } else {
                    tint = color
                    onTintChange?(color)
                }
            }
        }
    }

    /// Fades the artwork into the app background so the header has no hard edge. The middle
    /// stops blend toward the artwork's dominant color when known; the final stop is always the
    /// exact sheet background so the fade never shows a seam against it.
    private func bottomFade(height: CGFloat) -> some View {
        let base = DesignTokens.Colors.backgroundBase(for: colorScheme)
        let mid = tint.map { base.mixed(with: $0.color(for: colorScheme), amount: colorScheme == .dark ? 0.75 : 0.6) } ?? base
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0.0),
                .init(color: mid.opacity(0.45), location: 0.4),
                .init(color: mid.opacity(0.88), location: 0.75),
                .init(color: base, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
    }
}
