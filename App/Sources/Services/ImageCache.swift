import ImageIO
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
    /// In-flight loads keyed by cache key — concurrent requests for the same
    /// URL share one disk read instead of each triggering their own.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB decoded budget
    }

    /// Cache-hit check only — safe on the main thread. Never does I/O.
    func peek(_ url: URL) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: cacheKey(for: url))
    }

    /// Resolve a cached image for a URL, decoding if necessary. Async (the
    /// network fetch-through awaits) — callers must still be OFF the main
    /// actor for the synchronous disk read + decode parts.
    func image(for url: URL) async -> UIImage? {
        if let cached = peek(url) { return cached }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            // Only https may be fetched: markdown is user input, and an
            // arbitrary scheme (file:, data:, custom) must not be turned
            // into a fetch by the preview's read-through cache. Plain http
            // is excluded too — ATS blocks it, so accepting the scheme only
            // produced silent failures.
            guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
                Log.shared.error("Web image skipped (not https): \(url.absoluteString.prefix(120))")
                return nil
            }
            // Remote: disk-backed store first (persists across launches —
            // Storage's gallery browses these files too), then a byte-capped
            // fetch-through on a miss. Awaiting the fetch instead of parking
            // a cooperative thread on a semaphore (the old 15 s wait) — the
            // cap also stops a huge URL from buffering the whole file in RAM.
            if let disk = RemoteImageStore.loadData(for: url) {
                data = disk
            } else {
                guard let fetched = await RemoteImageStore.fetchCapped(url) else { return nil }
                RemoteImageStore.store(fetched, for: url)
                data = fetched
            }
        }
        guard let data, let decoded = Self.downsampledImage(data) else {
            // Bytes arrived but nothing decoded — a webp/avif the ImageIO
            // decoder here cannot read, or an HTML error page served with a
            // 200. The reason is invisible otherwise.
            Log.shared.error("Web image decode failed (\(data.count) bytes, not an image the decoder reads): \(url.absoluteString.prefix(120))")
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        // Cost in DECODED bytes (compressed bytes * 4–30× undercount and
        // the 64 MB totalCostLimit would hold hundreds of MB of bitmaps).
        let pixelSize = (decoded.cgImage?.bytesPerRow ?? 0) * (decoded.cgImage?.height ?? 0)
        let cost = max(pixelSize, data.count)
        cache.setObject(decoded, forKey: cacheKey(for: url), cost: cost)
        return decoded
    }

    /// Long-edge cap for the DECODE. The preview renders at screen width
    /// (max ~1000pt logical, thumbnail source 1200px), so a 6000×4000 photo
    /// was being built as a full-size bitmap (≈96 MB) and then scaled down
    /// by SwiftUI at draw time — pure render cost on every frame and the
    /// single biggest in-app memory spike. Image I/O already decodes at
    /// `ImageDecoder`'s requested point size for far less then that
    /// (`CGImageSourceCreateThumbnailAtIndex`), so nothing visible changes.
    private static let decodeLongEdgePixels = 1200

    private static func downsampledImage(_ data: Data) -> UIImage? {
        if Thread.isMainThread {
            // Callers today are off the main actor (CachedImage.load awaits
            // ImageCache.load on a detached task); keep the decode itself
            // main-safe so an accidental main-thread call cannot be worse
            // than it was.
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeLongEdgePixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data)
    }

    /// Async load with in-flight deduplication. Multiple callers awaiting the
    /// same URL share a single disk read + decode.
    func load(_ url: URL) async -> UIImage? {
        let key = cacheKey(for: url) as String
        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            let image = await self.image(for: url)
            self.lock.lock()
            self.inFlight.removeValue(forKey: key)
            self.lock.unlock()
            return image
        }
        inFlight[key] = task
        lock.unlock()
        return await task.value
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
/// Renders at full available width so images fill the screen horizontally
/// (Joplin parity) with NO height cap — tall images get as tall as the
/// aspect ratio requires (user request, was 400pt panorama guard).
struct CachedImage: View {
    let url: URL
    let alt: String
    let zoomable: Bool
    /// Closure fired when the user taps the image (only if `zoomable`).
    var onTap: (() -> Void)? = nil

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        Group {
            switch phase {
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .success(let img):
                let content = img.resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
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
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        // Cheap cache-hit check — no I/O — so warm images appear synchronously.
        if let warmed = ImageCache.shared.peek(url) {
            phase = .success(Image(uiImage: warmed))
            return
        }
        // Miss: read + decode strictly off the main actor, with in-flight
        // dedup so concurrent loads for the same URL share one disk read.
        let decoded = await ImageCache.shared.load(url)
        if let decoded {
            phase = .success(Image(uiImage: decoded))
        } else {
            phase = .failure(URLError(.badServerResponse))
        }
    }
}
