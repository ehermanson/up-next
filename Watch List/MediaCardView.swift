// SwiftUI view displaying a card for a media item (movie or TV show)
import SwiftData
import SwiftUI

struct MediaCardView: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let networks: [Network]
    let isWatched: Bool
    let watchedToggleAction: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let imageURL = imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.1)
                }
                .frame(width: 70, height: 100)
                .clipShape(.rect(cornerRadius: 14))
                .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 70, height: 100)
                    .clipShape(.rect(cornerRadius: 14))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .fontDesign(.rounded)
                        .lineLimit(2)
                    Spacer()
                    if isWatched {
                        Text("Watched")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .fontDesign(.rounded)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .glassEffect(.regular.tint(.green.opacity(0.3)), in: .capsule)
                            .accessibilityLabel("Watched")
                    }
                }
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                NetworkLogosView(networks: networks, maxVisible: 4, logoSize: 28)
            }
        }
        .padding(.all, 14)
        .glassEffect(.regular.tint(.white.opacity(0.03)).interactive(), in: .rect(cornerRadius: 20))
    }
}

#Preview {
    let sampleNetworks = [
        Network(
            id: 213,
            name: "Netflix",
            logoPath: "/pmvUqkQjmdJeuMkuGIcF1coIIJ1.png",
            originCountry: "US"
        ),
        Network(
            id: 49,
            name: "HBO",
            logoPath: "/tuomPhY2UtuPTqqFnKMVHvSb724.png",
            originCountry: "US"
        ),
    ]
    MediaCardView(
        title: "Example Movie Title",
        subtitle: "2022 \u{00b7} Action, Adventure",
        imageURL: nil,
        networks: sampleNetworks,
        isWatched: true,
        watchedToggleAction: { _ in }
    )
}
