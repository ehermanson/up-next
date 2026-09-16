import SwiftUI

enum MediaType: Identifiable {
    case tvShow
    case movie

    var id: Self { self }
}

/// A single shimmer placeholder row, matching `SearchResultRow`'s image/title/overview
/// layout. Reused both as plain content (`ShimmerLoadingView`) and as `List` rows
/// (`ShimmerRows`) so cold-search and loading-recommendations states look identical.
struct ShimmerRow: View {
    /// Pre-fade opacity for this row; see `ShimmerRows.fadeOpacity(for:count:)`.
    var fadeOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 12) {
            // Match SearchResultRow image dimensions
            RoundedRectangle(cornerRadius: DesignTokens.Radius.poster)
                .fill(.fill.tertiary)
                .frame(width: 60, height: 90)

            VStack(alignment: .leading, spacing: 6) {
                // Title shimmer (2 lines)
                Capsule()
                    .fill(.fill.tertiary)
                    .frame(height: 16)
                    .frame(maxWidth: 180)

                // Overview shimmer (3 lines)
                Capsule()
                    .fill(.fill.tertiary)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Capsule()
                    .fill(.fill.tertiary)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Capsule()
                    .fill(.fill.tertiary)
                    .frame(height: 10)
                    .frame(maxWidth: 200)
            }

            Spacer()
        }
        // Match SearchResultRow padding
        .padding(10)
        .cardSurface()
        .opacity(fadeOpacity)
    }
}

/// `ShimmerRow`s meant to be dropped directly into a `List` as loading placeholders
/// (cold search, loading recommendations). No moving shimmer overlay here — that's
/// reserved for the full-container `ShimmerLoadingView` — but the fade-toward-bottom
/// look is preserved.
struct ShimmerRows: View {
    var count: Int = 6

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            ShimmerRow(fadeOpacity: Self.fadeOpacity(for: index, count: count))
                .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    /// Gradually fades rows toward the bottom.
    static func fadeOpacity(for index: Int, count: Int) -> Double {
        let fadeStart = 2 // Start fading after the 3rd item
        if index < fadeStart {
            return 1.0
        } else {
            let fadeProgress = Double(index - fadeStart) / Double(count - fadeStart)
            return 1.0 - (fadeProgress * 0.8) // Fade to 40% opacity
        }
    }
}

/// Full-container loading placeholder — still used by `MediaListView`. Composes
/// `ShimmerRow` so the look stays identical to the in-`List` placeholder rows.
struct ShimmerLoadingView: View {
    @State private var shimmerOffset: CGFloat = -200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    ShimmerRow(fadeOpacity: ShimmerRows.fadeOpacity(for: index, count: 6))
                }
            }
            .overlay(
                Group {
                    if !reduceMotion {
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.04),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .offset(x: shimmerOffset)
                    }
                }
            )
            .clipped()
        }
        .scrollDisabled(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 400
            }
        }
    }
}

struct SearchResultRowWithImage: View {
    let title: String
    let overview: String?
    let posterPath: String?
    let mediaId: Int
    let mediaType: MediaType
    let isAdded: Bool
    let onAdd: () -> Void
    var onTap: (() -> Void)?
    var voteAverage: Double?
    /// Release/premiere year, e.g. "2021".
    var year: String?

    @State private var imageURL: URL?
    private let service = TMDBService.shared

    var body: some View {
        SearchResultRow(
            title: title,
            overview: overview,
            imageURL: imageURL,
            isAdded: isAdded,
            onAdd: onAdd,
            onTap: onTap,
            voteAverage: voteAverage,
            year: year
        )
        .task {
            if let path = posterPath {
                let url = service.imageURL(path: path)
                imageURL = url
            }
        }
    }
}

struct SearchResultRow: View {
    let title: String
    let overview: String?
    let imageURL: URL?
    let isAdded: Bool
    let onAdd: () -> Void
    var onTap: (() -> Void)?
    var voteAverage: Double?
    /// Release/premiere year, e.g. "2021".
    var year: String?

    var body: some View {
        Group {
            if let onTap {
                HStack(spacing: 12) {
                    Button(action: onTap) {
                        rowContent
                    }
                    .buttonStyle(.plain)

                    addButton
                }
            } else {
                Button {
                    if !isAdded { onAdd() }
                } label: {
                    HStack(spacing: 12) {
                        rowContent
                        addIcon
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .cardSurface()
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 90)
                        .clipShape(.rect(cornerRadius: DesignTokens.Radius.poster))
                        .clipped()
                default:
                    posterPlaceholder
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)

                    if let year, !year.isEmpty {
                        Text(year)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let overview = overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let vote = voteAverage, vote > 0 {
                    StarRatingLabel(vote: vote)
                }
            }

            Spacer()
        }
    }

    private var posterPlaceholder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.poster)
            .fill(.fill.tertiary)
            .frame(width: 60, height: 90)
    }

    private var addButton: some View {
        Button {
            if !isAdded { onAdd() }
        } label: {
            addIcon
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var addIcon: some View {
        if isAdded {
            Image(systemName: "checkmark")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Already added")
        } else {
            Image(systemName: "plus")
                .font(.headline.weight(.semibold))
                .frame(width: 44, height: 44)
                .accessibilityLabel("Add")
        }
    }
}

// MARK: - Previews

#Preview("Shimmer Loading") {
    ShimmerLoadingView()
}

#Preview("Search Result — Not Added") {
    SearchResultRow(
        title: "Breaking Bad",
        overview: "A chemistry teacher diagnosed with inoperable lung cancer turns to manufacturing and selling methamphetamine.",
        imageURL: nil,
        isAdded: false,
        onAdd: {},
        voteAverage: 8.9,
        year: "2008"
    )
    .padding()
}

#Preview("Search Result — Added") {
    SearchResultRow(
        title: "The Shawshank Redemption",
        overview: "Two imprisoned men bond over a number of years, finding solace and eventual redemption through acts of common decency.",
        imageURL: nil,
        isAdded: true,
        onAdd: {},
        voteAverage: 8.7,
        year: "1994"
    )
    .padding()
}
