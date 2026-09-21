import SwiftUI

/// The detail sheet's read-only content sections: overall description (with its soft line
/// limit), genre chips, the cast row, and the two link-out controls.

struct DescriptionSection: View {
    let isLoading: Bool
    let descriptionText: String?
    let errorMessage: String?
    /// Re-runs the detail fetch. A failure costs the description *and* the cast, trailer and
    /// "More Like This" rows, so the error needs a way out rather than a bare message.
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading details…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't Load Details",
                    subtitle: errorMessage
                ) {
                    Button("Try Again", action: onRetry)
                        .buttonStyle(.glassProminent)
                }
                .padding(.vertical, 12)
            } else if let descriptionText, !descriptionText.isEmpty {
                ClampedDescriptionText(text: descriptionText)
            } else {
                Text("No description available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A soft line limit: reveal the full passage if it needs only one extra line.
/// Longer passages keep the original limit and offer expansion. Measurements share
/// the rendered font and width, so the decision adapts to Dynamic Type and iPad layouts.
struct ClampedDescriptionText: View {
    let text: String
    var lineLimit: Int = 4
    var font: Font = .body
    var color: Color = .secondary
    /// Previews inside navigation buttons get the same soft limit without a nested button.
    var allowsExpansion = true

    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var relaxedHeight: CGFloat = 0

    private var needsExpansion: Bool {
        fullHeight > relaxedHeight + 1 && relaxedHeight > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            description

            if needsExpansion && allowsExpansion {
                Button {
                    isExpanded.toggle()
                } label: {
                    Text(isExpanded ? "less" : "more")
                        .font(font)
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Show less description" : "Show full description")
            }
        }
        .onChange(of: text) { isExpanded = false }
    }

    private var description: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(needsExpansion && !(isExpanded && allowsExpansion) ? lineLimit : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                // Separate backgrounds prevent one measuring copy from widening the other.
                Text(text)
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    .accessibilityHidden(true)
            }
            .background(alignment: .topLeading) {
                Text(text)
                    .font(font)
                    .lineLimit(lineLimit + 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { relaxedHeight = $0 }
                    .accessibilityHidden(true)
            }
    }
}

struct GenreSection: View {
    let genres: [String]

    var body: some View {
        if !genres.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(genres, id: \.self) { genre in
                        Chip(text: genre)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct CastSection: View {
    let cast: [String]
    let castImagePaths: [String]
    let castCharacters: [String]

    private let imageSize: CGFloat = 64
    private let itemWidth: CGFloat = 80

    var body: some View {
        if cast.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast")
                    .font(.headline)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(cast.prefix(10).enumerated()), id: \.offset) { index, member in
                            castItem(index: index, name: member)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func castItem(index: Int, name: String) -> some View {
        VStack(spacing: 6) {
            castImage(index: index)
                .frame(width: imageSize, height: imageSize)
                .clipShape(Circle())

            Text(name)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            let character = index < castCharacters.count ? castCharacters[index] : ""
            if !character.isEmpty {
                Text(character)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: itemWidth)
        // Name and character are one person, not two labels to swipe through.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func castImage(index: Int) -> some View {
        let path = index < castImagePaths.count ? castImagePaths[index] : ""
        if let url = TMDBService.shared.imageURL(path: path.isEmpty ? nil : path, size: .w185) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    castPlaceholder
                }
            }
        } else {
            castPlaceholder
        }
    }

    private var castPlaceholder: some View {
        Image(systemName: "person.fill")
            .font(.title2)
            .foregroundStyle(.tertiary)
            .frame(width: imageSize, height: imageSize)
            .background(.fill.tertiary, in: .circle)
    }
}

/// Glass action button for the title's YouTube trailer, when TMDB lists one. Owns the Safari
/// presentation so the detail sheet doesn't carry state for it.
struct TrailerButton: View {
    let trailerKey: String?

    @State private var isShowingTrailer = false

    var body: some View {
        if let trailerKey {
            Button { isShowingTrailer = true } label: {
                Label("Trailer", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .sheet(isPresented: $isShowingTrailer) {
                if let url = URL(string: "https://www.youtube.com/watch?v=\(trailerKey)") {
                    SafariView(url: url)
                        .ignoresSafeArea()
                }
            }
        }
    }
}

/// Small caption-style link at the very bottom of the content column — the TMDB page is a
/// reference, not an action, so it doesn't belong in the glass control row.
struct TMDBFooterLink: View {
    let url: URL

    @State private var isShowingPage = false

    var body: some View {
        Button {
            isShowingPage = true
        } label: {
            Text("View on TMDB")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingPage) {
            SafariView(url: url)
                .ignoresSafeArea()
        }
    }
}
