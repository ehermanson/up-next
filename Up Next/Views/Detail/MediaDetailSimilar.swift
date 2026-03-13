import SwiftUI

struct SimilarMediaItem: Identifiable {
    let id: Int
    let title: String
    let posterPath: String?
    let voteAverage: Double?
    let mediaType: MediaType
}

struct CollectionSection: View {
    let collectionName: String?
    let parts: [TMDBCollectionPart]
    var currentMovieID: Int?
    var existingIDs: Set<String> = []
    var onAdd: ((TMDBCollectionPart) -> Void)?
    var onTap: ((TMDBCollectionPart) -> Void)?

    private let cardWidth: CGFloat = 120
    private let posterHeight: CGFloat = 170

    var body: some View {
        if let name = collectionName, !parts.isEmpty {
            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.headline)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(parts) { part in
                            collectionCard(for: part)
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
        existingIDs.contains(String(part.id))
    }

    private func collectionCard(for part: TMDBCollectionPart) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                posterImage(path: part.posterPath)
                    .frame(width: cardWidth, height: posterHeight)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        if isCurrent(part) {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.white.opacity(0.5), lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isCurrent(part) { onTap?(part) }
                    }

                if let onAdd, !isCurrent(part) {
                    let added = isAdded(part)
                    Button {
                        if !added { onAdd(part) }
                    } label: {
                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(added ? .green : .white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(part.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isCurrent(part) ? .primary : .primary)
                .onTapGesture {
                    if !isCurrent(part) { onTap?(part) }
                }

            if let year = part.releaseYear {
                Text(year)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private func posterImage(path: String?) -> some View {
        if let url = TMDBService.shared.imageURL(path: path, size: .w342) {
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
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

struct SimilarSection: View {
    let title: String
    let items: [SimilarMediaItem]
    var existingIDs: Set<String> = []
    var onAdd: ((SimilarMediaItem) -> Void)?
    var onTap: ((SimilarMediaItem) -> Void)?

    private let cardWidth: CGFloat = 120
    private let posterHeight: CGFloat = 170

    var body: some View {
        if !items.isEmpty {
            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            similarCard(for: item)
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
        existingIDs.contains(String(item.id))
    }

    private func similarCard(for item: SimilarMediaItem) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                posterImage(path: item.posterPath)
                    .frame(width: cardWidth, height: posterHeight)
                    .clipShape(.rect(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?(item) }

                if let onAdd {
                    let added = isAdded(item)
                    Button {
                        if !added { onAdd(item) }
                    } label: {
                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(added ? .green : .white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(item.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .onTapGesture { onTap?(item) }
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private func posterImage(path: String?) -> some View {
        if let url = TMDBService.shared.imageURL(path: path, size: .w342) {
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
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}
