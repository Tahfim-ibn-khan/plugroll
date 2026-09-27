import AVFoundation
import CoreML
import CryptoKit
import ImageIO
import UIKit
import Vision

/// What the cleanup scan needs to know about one photo or video.
struct MediaFacts: Codable, Equatable, Sendable {
    /// Bumped when the way facts are worked out changes, so old cached ones are redone.
    static let currentVersion = 2

    var version = MediaFacts.currentVersion
    var pixelWidth = 0
    var pixelHeight = 0
    /// Seconds, for videos.
    var duration: Double?
    /// An archived Vision feature print of the thumbnail, for finding look-alikes.
    var featurePrint: Data?
    /// A 64-bit difference hash of the thumbnail: a second, simpler look-alike check.
    var pictureHash: UInt64?
    /// Higher is sharper. Photos only.
    var blurScore: Double?
    /// Average brightness, 0 (black) to 1 (white). Photos only.
    var brightness: Double?
    var isScreenshot = false

    var pixelCount: Int { pixelWidth * pixelHeight }
}

/// Works out `MediaFacts` and content hashes, and remembers them on the phone so a second
/// scan only looks at new or changed files. Entries are keyed by `MediaItem.cacheKey`,
/// which changes when a file does.
final class MediaAnalyzer: @unchecked Sendable {
    static let shared = MediaAnalyzer()

    private let directory: URL
    private let limiter = AsyncLimiter(limit: 4)

    private init() {
        directory = CacheDirectory.make(named: "Analysis", sizeLimit: 200 * 1024 * 1024)
    }

    /// For tests: a cache in a folder of their own.
    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Facts

    /// Nil when the file can't be read right now (the drive went away); that isn't
    /// remembered, so the next scan tries again.
    func facts(for item: MediaItem) async -> MediaFacts? {
        let cacheURL = directory.appendingPathComponent(item.cacheKey + ".json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(MediaFacts.self, from: data),
           cached.version == MediaFacts.currentVersion {
            return cached
        }
        if Task.isCancelled || !DriveIO.isAvailable { return nil }

        guard let thumbnail = await ThumbnailService.shared.thumbnail(for: item)?.cgImage else { return nil }
        await limiter.acquire()
        let facts = await Self.makeFacts(for: item, thumbnail: thumbnail)
        await limiter.release()

        guard let facts, !Task.isCancelled else { return nil }
        if let data = try? JSONEncoder().encode(facts) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return facts
    }

    private static func makeFacts(for item: MediaItem, thumbnail: CGImage) async -> MediaFacts? {
        var facts = MediaFacts()
        facts.featurePrint = featurePrintData(for: thumbnail)
        facts.pictureHash = differenceHash(of: thumbnail)

        switch item.kind {
        case .photo:
            guard let header = try? await DriveIO.run(timeout: 10, { PhotoHeader.read(item.url) }) else { return nil }
            facts.pixelWidth = header.width
            facts.pixelHeight = header.height
            facts.isScreenshot = looksLikeScreenshot(
                name: item.name,
                userComment: header.userComment,
                pixelWidth: header.width,
                pixelHeight: header.height
            )
            let measured = sharpnessAndBrightness(of: thumbnail)
            facts.blurScore = measured.sharpness
            facts.brightness = measured.brightness

        case .video:
            guard let size = try? await DriveIO.withTimeout(10, {
                try await VideoEditing.orientedSize(of: AVURLAsset(url: item.url))
            }) else { return nil }
            facts.pixelWidth = Int(size.width)
            facts.pixelHeight = Int(size.height)
            facts.duration = await VideoDurationService.shared.duration(for: item)
        }
        return facts
    }

    // MARK: - Content hash

    /// SHA-256 of the whole file, to tell true duplicates from files that only happen to
    /// be the same size. Only asked for files that share a size with another.
    func contentHash(for item: MediaItem) async -> String? {
        let cacheURL = directory.appendingPathComponent(item.cacheKey + ".sha256")
        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8), cached.count == 64 {
            return cached
        }
        if Task.isCancelled || !DriveIO.isAvailable { return nil }

        let cancelled = LockedValue(false)
        let hash = try? await withTaskCancellationHandler {
            // No timeout: hashing a big video takes as long as reading it.
            try await DriveIO.run { try Self.sha256(of: item.url, isCancelled: { cancelled.value }) }
        } onCancel: {
            cancelled.value = true
        }
        guard let hash else { return nil }
        try? hash.write(to: cacheURL, atomically: true, encoding: .utf8)
        return hash
    }

    static func sha256(of url: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { throw CancellationError() }
            guard let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Measuring

    static func featurePrintData(for image: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        #if targetEnvironment(simulator)
        // The simulator has no Neural Engine; without this Vision can hang there.
        let cpu = MLComputeDevice.allComputeDevices.first { if case .cpu = $0 { return true } else { return false } }
        if let cpu { request.setComputeDevice(cpu, for: .main) }
        #endif
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    static func featurePrint(from data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Shrinks the picture to 9×8 greys and records, for each pair of neighbours, whether
    /// the left one is brighter. Retakes and re-saves come out nearly the same; different
    /// pictures differ in many bits.
    static func differenceHash(of image: CGImage) -> UInt64 {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var hash: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                hash <<= 1
                if pixels[y * width + x] > pixels[y * width + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    /// Sharpness is the variance of the Laplacian (how strongly neighbouring pixels differ)
    /// on a small grey copy; blurry and out-of-focus shots score low. Brightness is the
    /// average grey level.
    static func sharpnessAndBrightness(of image: CGImage) -> (sharpness: Double, brightness: Double) {
        let scale = min(1, 256 / Double(max(image.width, image.height, 1)))
        let width = max(3, Int((Double(image.width) * scale).rounded()))
        let height = max(3, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)

        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0) }

        var total = 0.0
        for value in pixels { total += Double(value) }
        let brightness = total / Double(pixels.count) / 255

        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let centre = Double(pixels[row + x]) * 4
                let around = Double(pixels[row + x - 1]) + Double(pixels[row + x + 1])
                    + Double(pixels[row - width + x]) + Double(pixels[row + width + x])
                let laplacian = centre - around
                sum += laplacian
                sumOfSquares += laplacian * laplacian
                count += 1
            }
        }
        guard count > 0 else { return (0, brightness) }
        let mean = sum / count
        return (sumOfSquares / count - mean * mean, brightness)
    }

    /// iPhone screen sizes in pixels, portrait. Screenshots are saved as PNGs at exactly these.
    private static let screenSizes: Set<[Int]> = [
        [640, 960], [640, 1136], [750, 1334], [828, 1792], [1080, 1920], [1080, 2340],
        [1125, 2436], [1170, 2532], [1179, 2556], [1206, 2622], [1242, 2208], [1242, 2688],
        [1260, 2736], [1284, 2778], [1290, 2796], [1320, 2868],
    ]

    static func looksLikeScreenshot(name: String, userComment: String?, pixelWidth: Int, pixelHeight: Int) -> Bool {
        // iPhone writes this into every screenshot's EXIF.
        if userComment?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Screenshot") == .orderedSame {
            return true
        }
        let lowered = name.lowercased()
        if lowered.contains("screenshot") || lowered.contains("screen shot") || lowered.contains("screen_shot") {
            return true
        }
        guard (name as NSString).pathExtension.lowercased() == "png" else { return false }
        let sides = [min(pixelWidth, pixelHeight), max(pixelWidth, pixelHeight)]
        return screenSizes.contains(sides)
    }
}

/// The few header fields the scan reads from a photo without decoding it.
private struct PhotoHeader: Sendable {
    let width: Int
    let height: Int
    let userComment: String?

    static func read(_ url: URL) -> PhotoHeader {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return PhotoHeader(width: 0, height: 0, userComment: nil) }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return PhotoHeader(
            width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            userComment: exif?[kCGImagePropertyExifUserComment] as? String
        )
    }
}
