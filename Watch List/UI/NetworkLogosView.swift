import SwiftUI

struct NetworkLogosView: View {
    let networks: [Network]
    /// Maximum number of logos to display inline before showing "+N"
    let maxVisible: Int
    /// Logo size in points
    let logoSize: CGFloat

    init(networks: [Network], maxVisible: Int = 5, logoSize: CGFloat = 32) {
        self.networks = networks
        self.maxVisible = maxVisible
        self.logoSize = logoSize
    }

    var body: some View {
        if networks.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                ForEach(Array(networks.prefix(maxVisible)), id: \.id) { network in
                    if let logoURL = TMDBService.shared.imageURL(
                        path: network.logoPath, size: .w92)
                    {
                        AsyncImage(url: logoURL) { phase in
                            switch phase {
                            case .empty:
                                Color.gray.opacity(0.1)
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                Color.gray.opacity(0.1)
                            @unknown default:
                                Color.gray.opacity(0.1)
                            }
                        }
                        .frame(width: logoSize, height: logoSize)
                        .clipShape(.rect(cornerRadius: logoSize * 0.19))
                    }
                }
                if networks.count > maxVisible {
                    Text("+\(networks.count - maxVisible) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
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

