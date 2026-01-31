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
        HStack(alignment: .top, spacing: 12) {
            if let imageURL = imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.1)
                }
                .frame(width: 60, height: 70)
                .clipShape(.rect(cornerRadius: 18))
                .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 70)
                    .clipShape(.rect(cornerRadius: 18))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer()
                    if isWatched {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Watched")
                    }
                }
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                NetworkLogosView(networks: networks, maxVisible: 2, logoSize: 20)
            }
        }
        .padding(.all, 12)
        .glassEffect(in: .rect(cornerRadius: 30))
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
        subtitle: "2022 · Action, Adventure",
        imageURL: nil,
        networks: sampleNetworks,
        isWatched: true,
        watchedToggleAction: { _ in }
    )
}
