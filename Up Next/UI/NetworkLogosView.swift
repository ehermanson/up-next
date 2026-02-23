import SwiftUI

struct ProviderLogoView: View {
    let network: Network
    let size: CGFloat

    var body: some View {
        let radius = size * 0.22
        Group {
            if let logoURL = TMDBService.shared.imageURL(path: network.logoPath, size: .w92) {
                CachedAsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.gray.opacity(0.1)
                    }
                }
            } else {
                Color.gray.opacity(0.1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius))
        .glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}

struct NetworkLogosView: View {
    let networks: [Network]
    /// Maximum number of logos to display inline before showing "+N"
    let maxVisible: Int
    /// Logo size in points
    let logoSize: CGFloat
    /// Additional count to add to overflow (e.g., rent/buy options not shown)
    let additionalCount: Int

    init(networks: [Network], maxVisible: Int = 5, logoSize: CGFloat = 36, additionalCount: Int = 0) {
        self.networks = networks
        self.maxVisible = maxVisible
        self.logoSize = logoSize
        self.additionalCount = additionalCount
    }

    var body: some View {
        if !networks.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(networks.prefix(maxVisible)), id: \.id) { network in
                    ProviderLogoView(network: network, size: logoSize)
                }

                let overflow = max(0, networks.count - maxVisible) + additionalCount

                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: logoSize, height: logoSize)
                        .glassEffect(.regular, in: .rect(cornerRadius: logoSize * 0.22))
                }
            }
            .padding(.vertical, 2)
        }
    }
}

#Preview("Network Logos") {
    let networks = [
        Network(id: 213, name: "Netflix", logoPath: "/pmvUqkQjmdJeuMkuGIcF1coIIJ1.png"),
        Network(id: 49, name: "HBO", logoPath: "/tuomPhY2UtuPTqqFnKMVHvSb724.png"),
        Network(id: 1024, name: "Disney+", logoPath: "/gJ8VX6JSu3ciXHuC2dDGAo2lvwM.png"),
        Network(id: 5, name: "Prime", logoPath: "/emthp39XA2YScoYL1p0sdbAH2WA.png"),
        Network(id: 7, name: "Hulu", logoPath: "/pfAZ5Wb1SCTg20Ejig5Dzd7WlsA.png"),
        Network(id: 8, name: "Apple TV+", logoPath: "/4GxA9cugJr2DtiZ80c7t9XsXdlb.png"),
    ]
    return NetworkLogosView(networks: networks)
        .padding()
        .previewLayout(.sizeThatFits)
}

#Preview("Provider Logo") {
    ProviderLogoView(
        network: Network(id: 213, name: "Netflix", logoPath: "/pmvUqkQjmdJeuMkuGIcF1coIIJ1.png"),
        size: 44
    )
    .padding()
}
