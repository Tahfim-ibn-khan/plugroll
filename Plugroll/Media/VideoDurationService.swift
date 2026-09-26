import AVFoundation
import Foundation

/// Video lengths for the grid's duration labels. Reading one only touches the file's
/// header, but it is still a trip to the drive, so results are cached like thumbnails.
final class VideoDurationService: @unchecked Sendable {
    static let shared = VideoDurationService()

    private let memory = NSCache<NSString, NSNumber>()
    private let diskDirectory: URL
    private let limiter = AsyncLimiter(limit: 4)

    private init() {
        memory.countLimit = 5000
        diskDirectory = CacheDirectory.make(named: "Durations", sizeLimit: 50 * 1024 * 1024)
    }

    /// Instant lookup (no disk or drive access), in seconds.
    func cachedDuration(for item: MediaItem) -> Double? {
        memory.object(forKey: item.cacheKey as NSString)?.doubleValue
    }

    /// Memory cache → on-phone disk cache → read from the file on the drive.
    func duration(for item: MediaItem) async -> Double? {
        guard item.kind == .video else { return nil }
        if let seconds = cachedDuration(for: item) { return seconds }

        let diskURL = diskDirectory.appendingPathComponent(item.cacheKey + ".txt")
        if let text = try? String(contentsOf: diskURL, encoding: .utf8), let seconds = Double(text) {
            memory.setObject(NSNumber(value: seconds), forKey: item.cacheKey as NSString)
            return seconds
        }

        if Task.isCancelled || !DriveIO.isAvailable { return nil }
        await limiter.acquire()
        if Task.isCancelled {
            await limiter.release()
            return nil
        }
        let seconds = try? await DriveIO.withTimeout(10) {
            try await AVURLAsset(url: item.url).load(.duration).seconds
        }
        await limiter.release()

        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        memory.setObject(NSNumber(value: seconds), forKey: item.cacheKey as NSString)
        try? String(seconds).write(to: diskURL, atomically: true, encoding: .utf8)
        return seconds
    }
}
