import SwiftUI

/// A 2×2 poster grid (Apple Music playlist style) summarizing a collection's first four items.
/// Falls back gracefully as the collection fills up: one poster fills the whole square, two or
/// three fill the remaining cells with a neutral placeholder, and zero is four placeholder cells —
/// an empty collection keeps the same shape as a full one.
struct PosterMosaicView: View {
    let posterURLs: [URL?]
    var size: CGFloat = 64

    private var cellSize: CGFloat { (size - 1) / 2 }

    var body: some View {
        if posterURLs.count == 1 {
            poster(posterURLs[0])
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.cell))
        } else {
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    cell(at: 0)
                    cell(at: 1)
                }
                GridRow {
                    cell(at: 2)
                    cell(at: 3)
                }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.cell))
        }
    }

    private func cell(at index: Int) -> some View {
        Group {
            if index < posterURLs.count {
                poster(posterURLs[index])
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
        .frame(width: cellSize, height: cellSize)
        .clipped()
    }

    private func poster(_ url: URL?) -> some View {
        CachedAsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .transition(Motion.posterAppear)
            default:
                Rectangle().fill(.fill.tertiary)
            }
        }
    }
}
