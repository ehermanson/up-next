import SwiftUI

struct SimilarMediaItem: Identifiable {
    /// TMDB's numeric id, valid only within its own media-type namespace.
    let tmdbID: Int
    let title: String
    let posterPath: String?
    let voteAverage: Double?
    let mediaType: MediaType

    /// Type-namespaced key (`"tv:123"` / `"movie:456"`) — stable ForEach identity and animation key,
    /// since TMDB gives movies and shows overlapping numeric ids that the raw id can't tell apart.
    var transitionKey: String { MediaIDKey.make(mediaType, tmdbID) }

    /// `Identifiable` conformance has to carry the namespace too: a movie and a show sharing a
    /// numeric id would otherwise collide in any collection holding both.
    var id: String { transitionKey }
}

/// TMDB gives movies and TV shows separate ID namespaces, so any set holding both
/// has to key on the media type too — otherwise a movie and a show that happen to
/// share a numeric ID look like the same title.
enum MediaIDKey {
    static func make(_ mediaType: MediaType, _ id: String) -> String {
        "\(mediaType == .tvShow ? "tv" : "movie"):\(id)"
    }

    static func make(_ mediaType: MediaType, _ id: Int) -> String {
        make(mediaType, String(id))
    }

    /// Namespaces a set of raw IDs that are all known to be one media type.
    static func makeSet(_ mediaType: MediaType, _ ids: Set<String>) -> Set<String> {
        Set(ids.map { make(mediaType, $0) })
    }

    /// Inverse of `makeSet`: the raw IDs of one media type within a namespaced set.
    static func rawIDs(_ mediaType: MediaType, in keys: Set<String>) -> Set<String> {
        let prefix = make(mediaType, "")
        return Set(keys.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
    }
}

extension MediaDetailView {
    /// TMDB serves "similar" and "recommendations" as two separately-ranked, heavily-overlapping
    /// lists. This merges them into one "More Like This" pool: recommendations first (TMDB ranks
    /// them better), then similar, deduped by TMDB id keeping the first (better-ranked) occurrence,
    /// with the current title and anything already added dropped. `existingIDs` must be the set
    /// captured when the sheet opened — not a live-updating one — so adds made during the session are
    /// handled by `addedSimilarIDs` instead (the view drops an added title and slides the next
    /// pool entry up into its place). The pool is kept deeper than the 12 shown so there's a reserve
    /// to refill from.
    static func mergedMoreLikeThis(
        recommended: [SimilarMediaItem],
        similar: [SimilarMediaItem],
        currentKey: String,
        existingIDs: Set<String>
    ) -> [SimilarMediaItem] {
        var seenKeys: Set<String> = []
        var merged: [SimilarMediaItem] = []
        for item in recommended + similar {
            let key = item.transitionKey
            guard key != currentKey, !existingIDs.contains(key), !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            merged.append(item)
        }
        return Array(merged.prefix(24))
    }
}

// MARK: - Shared card

/// One poster card in the detail sheet's horizontal carousels (Similar, Recommended, Collection).
struct PosterCard: View {
    let posterPath: String?
    let title: String
    var subtitle: String?
    /// The title this detail sheet is already showing — not tappable, outlined instead.
    var isCurrent: Bool = false
    var isAdded: Bool = false
    var onTap: (() -> Void)?
    var onAdd: (() -> Void)?
    /// Zoom-transition source for the nested detail sheet `onTap` opens.
    var transitionSource: (id: String, namespace: Namespace.ID)?

    private let cardWidth: CGFloat = 120
    private let posterHeight: CGFloat = 170

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button {
                    onTap?()
                } label: {
                    posterImage
                        .frame(width: cardWidth, height: posterHeight)
                        .clipShape(.rect(cornerRadius: DesignTokens.Radius.posterCard))
                        .overlay {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.posterCard)
                                    .strokeBorder(.white.opacity(0.5), lineWidth: 2)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isCurrent || onTap == nil)
                .accessibilityLabel(title)
                .modifier(TransitionSourceModifier(source: isCurrent ? nil : transitionSource))

                if let onAdd {
                    PosterAddButton(
                        isAdded: isAdded,
                        accessibilityLabel: isAdded ? "\(title) is already added" : "Add \(title)",
                        size: 36,
                        action: onAdd
                    )
                    // Disabled once added so VoiceOver doesn't offer a no-op action; the check is
                    // status, not an affordance, so it keeps full opacity.
                    .disabled(isAdded)
                    .opacity(1)
                }
            }

            Button {
                onTap?()
            } label: {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isCurrent || onTap == nil)
            .accessibilityHidden(true)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private var posterImage: some View {
        if let url = TMDBService.shared.imageURL(path: posterPath, size: .w342) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    posterPlaceholder
                }
            }
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

// MARK: - Sections

struct CollectionSection: View {
    let collectionName: String?
    let parts: [TMDBCollectionPart]
    var currentMovieID: Int?
    var existingIDs: Set<String> = []
    var onAdd: ((TMDBCollectionPart) -> Void)?
    var onTap: ((TMDBCollectionPart) -> Void)?
    /// Zoom-transition namespace/id-prefix for the nested detail sheet `onTap` opens — see
    /// `MediaDetailView`'s `selectedSimilarSourceID`.
    var transitionNamespace: Namespace.ID?
    var transitionIDPrefix: String = ""

    var body: some View {
        if let name = collectionName, !parts.isEmpty {
            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.headline)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(parts) { part in
                            PosterCard(
                                posterPath: part.posterPath,
                                title: part.title,
                                subtitle: part.releaseYear,
                                isCurrent: isCurrent(part),
                                isAdded: isAdded(part),
                                onTap: onTap.map { tap in { tap(part) } },
                                onAdd: isCurrent(part) ? nil : onAdd.map { add in { add(part) } },
                                transitionSource: transitionNamespace.map {
                                    (id: "\(transitionIDPrefix):" + MediaIDKey.make(.movie, part.id), namespace: $0)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func isCurrent(_ part: TMDBCollectionPart) -> Bool {
        part.id == currentMovieID
    }

    private func isAdded(_ part: TMDBCollectionPart) -> Bool {
        existingIDs.contains(MediaIDKey.make(.movie, part.id))
    }
}

struct SimilarSection: View {
    let title: String
    let items: [SimilarMediaItem]
    /// `transitionKey` of the card currently animating its collapse before it's dropped — see
    /// `MediaDetailView.collapsingSimilarID`.
    var collapsingKey: String? = nil
    var existingIDs: Set<String> = []
    var onAdd: ((SimilarMediaItem) -> Void)?
    var onTap: ((SimilarMediaItem) -> Void)?
    /// Zoom-transition namespace/id-prefix for the nested detail sheet `onTap` opens — see
    /// `MediaDetailView`'s `selectedSimilarSourceID`.
    var transitionNamespace: Namespace.ID?
    var transitionIDPrefix: String = ""

    var body: some View {
        if !items.isEmpty {
            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items, id: \.transitionKey) { item in
                            let isCollapsing = collapsingKey == item.transitionKey
                            PosterCard(
                                posterPath: item.posterPath,
                                title: item.title,
                                isAdded: isAdded(item),
                                onTap: onTap.map { tap in { tap(item) } },
                                onAdd: onAdd.map { add in { add(item) } },
                                transitionSource: transitionNamespace.map {
                                    (id: "\(transitionIDPrefix):" + item.transitionKey, namespace: $0)
                                }
                            )
                            // Added card shrinks/fades in place, then the parent drops it and the
                            // reserve slides up. Animating the card's own geometry is reliable where a
                            // `ForEach` removal transition inside a horizontal `ScrollView` is not.
                            .scaleEffect(isCollapsing ? 0.6 : 1, anchor: .center)
                            .opacity(isCollapsing ? 0 : 1)
                            .frame(width: isCollapsing ? 0 : nil)
                            .clipped()
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func isAdded(_ item: SimilarMediaItem) -> Bool {
        existingIDs.contains(item.transitionKey)
    }
}
