import SwiftUI

struct SimilarMediaItem: Identifiable {
    let id: Int
    let title: String
    let posterPath: String?
    let voteAverage: Double?
    let mediaType: MediaType
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
    /// lists. This merges them into one "More Like This" feed: recommendations first (TMDB ranks
    /// them better), then similar, deduped by TMDB id keeping the first (better-ranked) occurrence,
    /// with the current title and anything already added dropped. `existingIDs` must be the set
    /// captured when the sheet opened — not a live-updating one — so a title the user adds while
    /// browsing keeps its green checkmark instead of disappearing out from under their finger.
    static func mergedMoreLikeThis(
        recommended: [SimilarMediaItem],
        similar: [SimilarMediaItem],
        currentKey: String,
        existingIDs: Set<String>
    ) -> [SimilarMediaItem] {
        var seenKeys: Set<String> = []
        var merged: [SimilarMediaItem] = []
        for item in recommended + similar {
            let key = MediaIDKey.make(item.mediaType, item.id)
            guard key != currentKey, !existingIDs.contains(key), !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            merged.append(item)
        }
        return Array(merged.prefix(12))
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
                    Button {
                        if !isAdded { onAdd() }
                    } label: {
                        // Drawn over artwork, so the white tint and shadow are intentional.
                        Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(isAdded ? .green : .white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .padding(6)
                            .checkmarkPop(isOn: isAdded)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isAdded ? "\(title) is already added" : "Add \(title)")
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
                        ForEach(items) { item in
                            PosterCard(
                                posterPath: item.posterPath,
                                title: item.title,
                                isAdded: isAdded(item),
                                onTap: onTap.map { tap in { tap(item) } },
                                onAdd: onAdd.map { add in { add(item) } },
                                transitionSource: transitionNamespace.map {
                                    (id: "\(transitionIDPrefix):" + MediaIDKey.make(item.mediaType, item.id), namespace: $0)
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

    private func isAdded(_ item: SimilarMediaItem) -> Bool {
        existingIDs.contains(MediaIDKey.make(item.mediaType, item.id))
    }
}
