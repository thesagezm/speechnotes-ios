import SwiftUI

/// In-memory image cache for the markdown preview.
///
/// Joplin's mobile app keeps its images in a `resourceDir` keyed by hash and
/// loads them synchronously from disk (no re-fetch). We mirror that: once a
/// local file or remote URL is decoded once, we hold the decoded `Image` so
/// preview toggles, scrolling, and table-of-contents jumps don't re-hit disk
/// or network.
///
/// Backed by `NSCache`, so the system evicts under memory pressure. Two keys
/// are kept — the on-disk file path for local images, the absolute remote URL
/// for downloads — so the same `UIImage` is never decoded twice for the same
/// source.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB decoded budget
    }

    /// Resolve a cached image for a URL, decoding if necessary. Synchronous
    /// — callers already off the main actor for file/remote IO.
    func image(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: url), let decoded = UIImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key, cost: data.count)
        return decoded
    }

    /// Pre-seed a known image under its URL key (used after fresh downloads).
    func insert(_ image: UIImage, for url: URL, cost: Int) {
        lock.lock()
        defer { lock.unlock() }
        cache.setObject(image, forKey: cacheKey(for: url), cost: cost)
    }

    func remove(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeObject(forKey: cacheKey(for: url))
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAllObjects()
    }

    private func cacheKey(for url: URL) -> NSString {
        // file:// URLs hash their path; remote URLs hash absoluteString.
        NSString(string: url.isFileURL ? url.path : url.absoluteString)
    }
}

/// SwiftUI image that reads from `ImageCache` first. Falls back to aProgressView
/// placeholder while the decode runs off-main.
struct CachedImage: View {
    let url: URL
    let alt: String
    let zoomable: Bool
    var maxHeight: CGFloat = 220
    /// Closure fired when the user taps the image (only if `zoomable`).
    var onTap: (() -> Void)? = nil

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        Group {
            switch phase {
            case .empty:
                ProgressView()
            case .success(let img):
                let content = img.resizable().scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if zoomable {
                    Button { onTap?() } label: { content }
                        .buttonStyle(.plain)
                } else {
                    content
                }
            case .failure:
                Image(systemName: "photo").foregroundStyle(.secondary)
            @unknown default:
                Image(systemName: "photo")
            }
        }
        .accessibilityLabel(alt.isEmpty ? "image" : alt)
        .frame(maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        // Try the in-memory cache first.
        if let cached = ImageCache.shared.image(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }
        // Otherwise decode on a background task and seed the cache.
        if let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            ImageCache.shared.image(for: url)
        }.value {
            ImageCache.shared.insert(decoded, for: url, cost: Int(decoded.size.width * decoded.size.height * 4))
            phase = .success(Image(uiImage: decoded))
        } else {
            phase = .failure(URLError(.badServerResponse))
        }
    }
}
