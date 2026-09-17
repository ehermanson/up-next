import SwiftUI
import UIKit

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

private actor ImageDownloader {
    static let shared = ImageDownloader()
    private var inFlight: [URL: Task<Data, any Error>] = [:]

    func download(from url: URL) async throws -> Data {
        if let existing = inFlight[url] {
            return try await existing.value
        }
        let task = Task {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        inFlight[url] = task
        defer { inFlight.removeValue(forKey: url) }
        return try await task.value
    }
}

struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    /// Optional hook handed the decoded `UIImage` whenever one loads (cache hit or fresh
    /// download) — lets a caller derive something from the pixels (e.g. a dominant-color tint)
    /// without re-fetching. Existing call sites stay source-compatible since this defaults to nil.
    var onLoad: ((UIImage) -> Void)? = nil
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                await load()
            }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }

        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            onLoad?(cached)
            return
        }

        phase = .empty

        do {
            let data = try await ImageDownloader.shared.download(from: url)
            guard let uiImage = UIImage(data: data) else {
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }
            ImageCache.shared.store(uiImage, for: url)
            phase = .success(Image(uiImage: uiImage))
            onLoad?(uiImage)
        } catch {
            phase = .failure(error)
        }
    }
}
