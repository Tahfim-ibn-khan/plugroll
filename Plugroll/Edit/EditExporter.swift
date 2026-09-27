import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Where an edited photo or video goes. The editor asks every time.
enum EditDestination: Sendable {
    /// A new file next to the original, e.g. "IMG_1234 (Edited).jpg".
    case copyOnDrive
    /// The edit replaces the file on the drive.
    case replaceOriginal
    /// The drive is left alone; the edit goes into the photo library.
    case photos
}

enum EditResult: Sendable {
    case copy(MediaItem)
    case replaced(MediaItem)
    case photos
}

enum EditExportError: LocalizedError {
    case cantRead
    case cantWrite
    case cantReplace
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .cantRead: return "The file couldn't be read."
        case .cantWrite: return "The edited file couldn't be created."
        case .cantReplace: return "This file can't be replaced with the edit, since it would change format. Save a copy instead."
        case .exportFailed: return "The video couldn't be exported."
        }
    }
}

/// Renders edits at full quality and saves them where the user picked.
enum EditExporter {
    // MARK: - Formats

    /// The edited file's extension: the original's where it can be written back as is,
    /// otherwise JPEG for photos (RAW, TIFF, GIF…) and QuickTime for videos.
    static func outputExtension(for item: MediaItem) -> String {
        let ext = item.url.pathExtension
        switch (item.kind, ext.lowercased()) {
        case (.photo, "jpg"), (.photo, "jpeg"), (.photo, "heic"), (.photo, "heif"), (.photo, "png"): return ext
        case (.photo, _): return "jpg"
        case (.video, "mov"), (.video, "mp4"), (.video, "m4v"): return ext
        case (.video, _): return "mov"
        }
    }

    /// Only when the edit keeps the original's format: replacing a RAW file with a
    /// JPEG would quietly throw the RAW data away.
    static func canReplaceOriginal(_ item: MediaItem) -> Bool {
        outputExtension(for: item) == item.url.pathExtension
    }

    private static func imageType(forExtension ext: String) -> UTType {
        switch ext.lowercased() {
        case "heic", "heif": return .heic
        case "png": return .png
        default: return .jpeg
        }
    }

    static func videoType(forExtension ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mp4": return .mp4
        case "m4v": return .m4v
        default: return .mov
        }
    }

    // MARK: - Rendering

    /// Renders an edited photo at full size into `batch`, keeping its date, place and
    /// camera details. The original is copied off the drive first, then read locally.
    static func renderPhoto(_ item: MediaItem, edits: Edits, autoFilters: [CIFilter], in batch: URL) async throws -> URL {
        let staged = try await ExportService.stageCopy(of: item, index: 0, in: batch)
        defer { ExportService.remove(staged.deletingLastPathComponent()) }
        try Task.checkCancellation()

        let ext = outputExtension(for: item)
        let output = batch.appendingPathComponent("edited.\(ext)")
        try render(photoAt: staged, isRAW: item.isRAW, edits: edits, autoFilters: autoFilters, to: output, type: imageType(forExtension: ext))
        return output
    }

    static func render(photoAt source: URL, isRAW: Bool, edits: Edits, autoFilters: [CIFilter], to output: URL, type: UTType) throws {
        let input: CIImage?
        if isRAW {
            input = CIRAWFilter(imageURL: source)?.outputImage
        } else {
            input = CIImage(contentsOf: source, options: [.applyOrientationProperty: true])
        }
        guard let input else { throw EditExportError.cantRead }

        let edited = EditRenderer.apply(edits, to: input, autoFilters: autoFilters)
        let colorSpace = isRAW ? EditRenderer.displayColorSpace : (input.colorSpace ?? EditRenderer.displayColorSpace)
        guard let cgImage = EditRenderer.context.createCGImage(edited, from: edited.extent, format: .RGBA8, colorSpace: colorSpace),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil)
        else { throw EditExportError.cantWrite }

        var properties = keptMetadata(from: source)
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditExportError.cantWrite }
    }

    /// Date, place, camera and caption details. The orientation is now baked into the
    /// pixels, so it's reset, and size fields are left for the writer to fill in.
    static func keptMetadata(from source: URL) -> [String: Any] {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let all = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        else { return [kCGImagePropertyOrientation as String: 1] }

        var kept: [String: Any] = [kCGImagePropertyOrientation as String: 1]
        if var exif = all[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            kept[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = all[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            kept[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = all[key as String] { kept[key as String] = value }
        }
        return kept
    }

    /// Exports an edited video into `batch`. `progress` gets 0...1 while it runs.
    static func renderVideo(
        _ item: MediaItem,
        edits: Edits,
        in batch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard DriveIO.isAvailable else { throw DriveError.disconnected }
        let source = AVURLAsset(url: item.url)
        return try await render(videoFrom: source, edits: edits, to: batch, ext: outputExtension(for: item), progress: progress)
    }

    static func render(
        videoFrom source: AVAsset,
        edits: Edits,
        to batch: URL,
        ext: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let trimmed = try await VideoEditing.trimmedAsset(from: source, edits: edits)
        let fileType = videoType(forExtension: ext)
        let session: AVAssetExportSession
        if edits.isTrimOnly, let passthrough = await passthroughSession(for: trimmed, fileType: fileType) {
            // Only cut: the frames are copied as they are, which is fast and loses nothing.
            session = passthrough
        } else {
            let videoComposition = try await VideoEditing.composition(for: trimmed, edits: edits)
            let preset = await VideoEditing.isHEVC(source) ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            guard let encoding = AVAssetExportSession(asset: trimmed, presetName: preset) else {
                throw EditExportError.exportFailed
            }
            encoding.videoComposition = videoComposition
            session = encoding
        }
        // Keeps the recording date and place.
        session.metadata = (try? await source.load(.metadata)) ?? []

        return try await export(session, to: batch.appendingPathComponent("edited.\(ext)"), as: fileType, progress: progress)
    }

    /// A session that copies the frames without re-encoding, if the file type allows it.
    static func passthroughSession(for asset: AVAsset, fileType: AVFileType) async -> AVAssetExportSession? {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              await session.compatibleFileTypes.contains(fileType)
        else { return nil }
        return session
    }

    /// Runs an export session, reporting 0...1 to `progress`.
    static func export(
        _ session: AVAssetExportSession,
        to output: URL,
        as fileType: AVFileType,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let states = session.states(updateInterval: 0.2)
        let watcher = Task {
            for await state in states {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: output, as: fileType)
        progress(1)
        return output
    }

    // MARK: - Saving

    /// What happens to the original when an edit replaces it.
    struct ReplaceOptions: Sendable {
        /// Set to the drive's root to move the original into Recently Deleted instead of
        /// removing it.
        var recentlyDeletedRoot: URL?
        /// Gives the new file the original's date, so it stays in its place in the grid.
        var keepsDate = false
    }

    /// Puts a rendered file where the user asked. The rendered file is used up.
    static func save(
        _ rendered: URL,
        for item: MediaItem,
        to destination: EditDestination,
        options: ReplaceOptions = ReplaceOptions()
    ) async throws -> EditResult {
        switch destination {
        case .photos:
            let name = item.url.deletingPathExtension().lastPathComponent + "." + rendered.pathExtension
            try await ExportService.addToPhotoLibrary(rendered, name: name, kind: item.kind)
            return .photos

        case .copyOnDrive:
            let folder = item.url.deletingLastPathComponent()
            let stem = item.url.deletingPathExtension().lastPathComponent
            let ext = rendered.pathExtension
            let target = try await DriveIO.run(timeout: 10) {
                uniqueEditedURL(in: folder, stem: stem, ext: ext) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
            }
            try await ExportService.copy(from: rendered, to: target)
            return .copy(try await mediaItem(at: target, kind: item.kind))

        case .replaceOriginal:
            guard canReplaceOriginal(item) else { throw EditExportError.cantReplace }
            try await replace(
                item.url,
                with: rendered,
                keepingIn: options.recentlyDeletedRoot.map { ($0, item) },
                date: options.keepsDate ? item.modified : nil
            )
            return .replaced(try await mediaItem(at: item.url, kind: item.kind))
        }
    }

    /// "IMG_1234 (Edited).jpg", or "IMG_1234 (Edited 2).jpg" and so on if that's taken.
    static func uniqueEditedURL(in folder: URL, stem: String, ext: String, exists: (URL) -> Bool) -> URL {
        var number = 1
        while true {
            let label = number == 1 ? "Edited" : "Edited \(number)"
            let candidate = folder.appendingPathComponent("\(stem) (\(label)).\(ext)")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    /// Copies the edit onto the drive under a hidden name first, then swaps it in by
    /// renaming, so a failed copy never leaves the original half-overwritten.
    /// With `keepingIn`, the original goes to that drive's Recently Deleted rather than
    /// being removed; if that fails, the swap is undone. `date` sets the new file's date.
    static func replace(
        _ original: URL,
        with rendered: URL,
        keepingIn recentlyDeleted: (root: URL, item: MediaItem)? = nil,
        date: Date? = nil
    ) async throws {
        let folder = original.deletingLastPathComponent()
        let token = UUID().uuidString
        let incoming = folder.appendingPathComponent(".\(original.lastPathComponent).\(token).plugroll-edit")
        let outgoing = folder.appendingPathComponent(".\(original.lastPathComponent).\(token).plugroll-old")

        try await ExportService.copy(from: rendered, to: incoming)
        try await DriveIO.run(timeout: 30) {
            let files = FileManager.default
            do {
                try files.moveItem(at: original, to: outgoing)
            } catch {
                try? files.removeItem(at: incoming)
                throw error
            }
            do {
                try files.moveItem(at: incoming, to: original)
            } catch {
                // Put the original back where it was.
                try? files.moveItem(at: outgoing, to: original)
                try? files.removeItem(at: incoming)
                throw error
            }
            if let date {
                try? files.setAttributes([.modificationDate: date], ofItemAtPath: original.path)
            }
            if let recentlyDeleted {
                do {
                    _ = try RecentlyDeleted.moveIn(
                        file: outgoing,
                        recordingAs: original,
                        root: recentlyDeleted.root,
                        modified: recentlyDeleted.item.modified,
                        size: recentlyDeleted.item.fileSize
                    )
                } catch {
                    // Swap back, so the original is never lost.
                    try? files.removeItem(at: original)
                    try? files.moveItem(at: outgoing, to: original)
                    throw error
                }
            } else {
                try? files.removeItem(at: outgoing)
            }
        }
    }

    private static func mediaItem(at url: URL, kind: MediaKind) async throws -> MediaItem {
        try await DriveIO.run(timeout: 10) {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            let values = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return MediaItem(
                url: url,
                kind: MediaKind(url: url) ?? kind,
                modified: values.contentModificationDate ?? Date(),
                fileSize: values.fileSize ?? 0
            )
        }
    }
}
