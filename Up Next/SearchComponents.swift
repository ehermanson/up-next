import SwiftUI

enum MediaType: Identifiable {
    case tvShow
    case movie

    var id: Self { self }
}

struct ShimmerLoadingView: View {
    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { index in
                        HStack(spacing: 12) {
                            // Match SearchResultRow image dimensions
                            Color.clear
                                .frame(width: 60, height: 90)
                                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                            
                            VStack(alignment: .leading, spacing: 6) {
                                // Title shimmer (2 lines)
                                Color.clear
                                    .frame(height: 16)
                                    .frame(maxWidth: 180)
                                    .glassEffect(.regular, in: .capsule)
                                
                                // Overview shimmer (3 lines)
                                Color.clear
                                    .frame(height: 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .glassEffect(.regular, in: .capsule)
                                
                                Color.clear
                                    .frame(height: 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .glassEffect(.regular, in: .capsule)
                                
                                Color.clear
                                    .frame(height: 10)
                                    .frame(maxWidth: 200)
                                    .glassEffect(.regular, in: .capsule)
                                
                            }
                            
                            Spacer()
                        }
                        // Match SearchResultRow padding
                        .padding(10)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .opacity(fadeOpacity(for: index))
                    }
                }
            }
            .overlay(
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
            )
            .clipped()
        }
        .scrollDisabled(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 400
            }
        }
    }
    
    private func fadeOpacity(for index: Int) -> Double {
        // Gradually fade out items toward the bottom
        let fadeStart = 2 // Start fading after the 3rd item
        if index < fadeStart {
            return 1.0
        } else {
            let fadeProgress = Double(index - fadeStart) / Double(6 - fadeStart)
            return 1.0 - (fadeProgress * 0.8) // Fade to 40% opacity
        }
    }
}

struct SearchResultRowWithImage: View {
    let title: String
    let overview: String?
    let posterPath: String?
    let isAdded: Bool
    let onAdd: () -> Void

    @State private var imageURL: URL?
    private let service = TMDBService.shared

    var body: some View {
        SearchResultRow(
            title: title,
            overview: overview,
            imageURL: imageURL,
            isAdded: isAdded,
            onAdd: onAdd
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

    var body: some View {
        Button {
            if !isAdded {
                onAdd()
            }
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 60, height: 90)
                            .clipShape(.rect(cornerRadius: 10))
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 90)
                            .clipShape(.rect(cornerRadius: 10))
                            .clipped()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 60, height: 90)
                            .clipShape(.rect(cornerRadius: 10))
                    @unknown default:
                        EmptyView()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fontDesign(.rounded)
                        .lineLimit(2)

                    if let overview = overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                Spacer()

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
                        .accessibilityLabel("Add to list")
                }
            }
        }
        .buttonStyle(.plain)
        .padding(10)
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 20))
    }
}
