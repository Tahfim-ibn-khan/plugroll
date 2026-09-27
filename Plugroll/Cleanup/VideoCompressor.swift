import AVFoundation

/// How hard Compress squeezes a video.
enum CompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case high
    case medium
    case small

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "High Quality"
        case .medium: return "Balanced"
        case .small: return "Smallest"
        }
    }

    var detail: String {
        switch self {
        case .high: return "HEVC at full resolution, up to 4K"
        case .medium: return "HEVC at up to 1080p"
        case .small: return "H.264 at up to 720p"
        }
    }

    var preset: String {
        switch self {
        case .high: return AVAssetExportPresetHEVC3840x2160
        case .medium: return AVAssetExportPresetHEVC1920x1080
        case .small: return AVAssetExportPreset1280x720
        }
    }
}

enum VideoCompressorError: LocalizedError {
    case notSmaller
    case notEnoughPhoneSpace(needed: Int64)

    var errorDescription: String? {
        switch self {
        case .notSmaller:
            return "This video is already about as small as this setting makes it, so it was left as it is."
        case .notEnoughPhoneSpace(let needed):
            return "The video is made on the iPhone before it goes back to the drive, and that needs about \(ByteFormat.string(needed)) free on the iPhone."
        }
    }
}

/// Re-encodes a big video to take less room. The result is saved like an edit, through
/// `EditExporter.save`.
enum VideoCompressor {
    /// AVFoundation's guess of the new size, or nil if it can't tell.
    static func estimatedSize(of item: MediaItem, level: CompressionLevel) async -> Int64? {
        guard DriveIO.isAvailable else { return nil }
        let result = try? await DriveIO.withTimeout(15) { () -> Int64? in
            let asset = AVURLAsset(url: item.url)
            guard let session = AVAssetExportSession(asset: asset, presetName: level.preset) else { return nil }
            session.outputFileType = EditExporter.videoType(forExtension: EditExporter.outputExtension(for: item))
            let bytes = try await session.estimatedOutputFileLengthInBytes
            return bytes > 0 ? bytes : nil
        }
        return result ?? nil
    }

    /// Compresses into `batch` and returns the new file. Throws `notSmaller` rather than
    /// hand back a file that saves nothing.
    static func compress(
        _ item: MediaItem,
        level: CompressionLevel,
        in batch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard DriveIO.isAvailable else { throw DriveError.disconnected }
        let estimate = await estimatedSize(of: item, level: level) ?? Int64(item.fileSize)
        if let free = DriveSpace.phoneAvailable(), free < estimate + 200 * 1024 * 1024 {
            throw VideoCompressorError.notEnoughPhoneSpace(needed: estimate)
        }

        let asset = AVURLAsset(url: item.url)
        guard let session = AVAssetExportSession(asset: asset, presetName: level.preset) else {
            throw EditExportError.exportFailed
        }
        // Keeps the recording date and place.
        session.metadata = (try? await asset.load(.metadata)) ?? []
        session.shouldOptimizeForNetworkUse = false

        let ext = EditExporter.outputExtension(for: item)
        let output = try await EditExporter.export(
            session,
            to: batch.appendingPathComponent("compressed.\(ext)"),
            as: EditExporter.videoType(forExtension: ext),
            progress: progress
        )
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Anything under 95% is worth it; less than that isn't worth the lost quality.
        guard size > 0, Double(size) < Double(item.fileSize) * 0.95 else {
            ExportService.remove(output)
            throw VideoCompressorError.notSmaller
        }
        return output
    }
}
