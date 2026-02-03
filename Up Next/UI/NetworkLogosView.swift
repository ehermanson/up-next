import SwiftUI

struct NetworkLogosView: View {
    let networks: [Network]
    /// Maximum number of logos to display inline before showing "+N"
    let maxVisible: Int
    /// Logo size in points
    let logoSize: CGFloat
    /// Number of providers hidden by user settings (not included in networks)
    let hiddenCount: Int

    init(networks: [Network], maxVisible: Int = 5, logoSize: CGFloat = 36, hiddenCount: Int = 0) {
        self.networks = networks
        self.maxVisible = maxVisible
        self.logoSize = logoSize
        self.hiddenCount = hiddenCount
    }

    var body: some View {
        if networks.isEmpty && hiddenCount > 0 {
            Text("Available on \(hiddenCount) provider\(hiddenCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } else if !networks.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(networks.prefix(maxVisible)), id: \.id) { network in
                    if let logoURL = TMDBService.shared.imageURL(
                        path: network.logoPath, size: .w92)
                    {
                        CachedAsyncImage(url: logoURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .padding(4)
                            default:
                                Color.gray.opacity(0.1)
                            }
                        }
                        .frame(width: logoSize, height: logoSize)
                        .background(Color.white.opacity(0.85), in: .rect(cornerRadius: logoSize * 0.19))
                        .glassEffect(.regular, in: .rect(cornerRadius: logoSize * 0.19))
                    }
                }

                let overflowFromMax = networks.count > maxVisible ? networks.count - maxVisible : 0
                let totalOverflow = overflowFromMax + hiddenCount

                if totalOverflow > 0 {
                    Text("+\(totalOverflow)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: logoSize, height: logoSize)
                        .glassEffect(.regular, in: .rect(cornerRadius: logoSize * 0.19))
                }
            }
            .padding(.vertical, 2)
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
