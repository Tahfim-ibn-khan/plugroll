import AVFoundation
import ImageIO
import UIKit

final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    private let memory = NSCache<NSURL, UIImage>()
    private let diskDirectory: URL
    private let limiter = AsyncLimiter(limit: 4)
    private let thumbnailPixelSize: CGFloat = 400

    private init() {
        // A 400pt thumbnail costs ~640 KB decoded, so cap the cache by bytes as well
        // as by count: a folder of a few thousand photos would otherwise fill memory.
        memory.countLimit = 600
        memory.totalCostLimit = 96 * 1024 * 1024
        // ~30 KB a thumbnail, so this keeps roughly 15,000 of them.
        diskDirectory = CacheDirectory.make(named: "Thumbnails", sizeLimit: 500 * 1024 * 1024)
    }

    /// Instant lookup for already-loaded thumbnails (no disk or drive access).
    func cachedThumbnail(for item: MediaItem) -> UIImage? {
        memory.object(forKey: item.url as NSURL)
    }

    /// Memory cache → on-phone disk cache → generate from the file on the drive.
    func thumbnail(for item: MediaItem) async -> UIImage? {
        if let image = cachedThumbnail(for: item) { return image }

        let diskURL = diskCacheURL(for: item)
        if let data = try? Data(contentsOf: diskURL),
           let image = await UIImage(data: data)?.byPreparingForDisplay() {
            store(image, for: item)
            return image
        }

        if Task.isCancelled || !DriveIO.isAvailable { return nil }
        await limiter.acquire()
        if Task.isCancelled {
            await limiter.release()
            return nil
        }
        let cgImage = await Self.makeThumbnail(for: item, maxPixel: thumbnailPixelSize)
        await limiter.release()

        guard let cgImage else { return nil }
        let image = UIImage(cgImage: cgImage)
        store(image, for: item)
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: diskURL, options: .atomic)
        }
        return image
    }

    private func store(_ image: UIImage, for item: MediaItem) {
        let bytes = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(image, forKey: item.url as NSURL, cost: bytes)
    }

    /// Screen-sized image for the full-screen viewer. Generous enough to stay sharp
    /// when zoomed in, small enough that a few pages can be in memory at once.
    static func displayImage(for item: MediaItem, maxPixel: CGFloat = 3000) async -> UIImage? {
        let image = try? await DriveIO.run(timeout: 30) {
            ThumbnailService.decodeImage(at: item.url, maxPixel: maxPixel, preferEmbeddedPreview: false)
                .map { UIImage(cgImage: $0) }
        }
        return image ?? nil
    }

    private static func makeThumbnail(for item: MediaItem, maxPixel: CGFloat) async -> CGImage? {
        switch item.kind {
        case .photo:
            // RAW files carry a large embedded JPEG preview; decoding the RAW itself is slow.
            let image = try? await DriveIO.run(timeout: 15) {
                ThumbnailService.decodeImage(at: item.url, maxPixel: maxPixel, preferEmbeddedPreview: item.isRAW)
            }
            return image ?? nil
        case .video:
            return try? await DriveIO.withTimeout(15) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
                generator.requestedTimeToleranceBefore = .positiveInfinity
                generator.requestedTimeToleranceAfter = .positiveInfinity
                return try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            }
        }
    }

    private static func decodeImage(at url: URL, maxPixel: CGFloat, preferEmbeddedPreview: Bool) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let createKey = preferEmbeddedPreview
            ? kCGImageSourceCreateThumbnailFromImageIfAbsent
            : kCGImageSourceCreateThumbnailFromImageAlways
        let options: [CFString: Any] = [
            createKey: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func diskCacheURL(for item: MediaItem) -> URL {
        diskDirectory.appendingPathComponent(item.cacheKey + ".jpg")
    }
}
