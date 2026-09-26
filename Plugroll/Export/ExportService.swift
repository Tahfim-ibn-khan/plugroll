import Photos
import UIKit
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case notAFile

    var errorDescription: String? {
        switch self {
        case .notAFile: return "It isn't a regular file, so it was left alone."
        }
    }
}

/// File work behind Share, Save to Photos and Delete.
enum ExportService {
    /// Files are copied off the drive before handing them to Photos or the share sheet:
    /// those run in other processes, which may not be allowed to read the drive directly.
    static let outbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("Outbox", isDirectory: true)

    static func clearOutbox() {
        try? FileManager.default.removeItem(at: outbox)
    }

    static func makeBatchDirectory() throws -> URL {
        let batch = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        return batch
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Copies one file into the batch, keeping its original name. Each file gets its own
    /// subfolder, so two files with the same name (from different folders) can't collide.
    static func stageCopy(of item: MediaItem, index: Int, in batch: URL) async throws -> URL {
        let folder = batch.appendingPathComponent(String(index), isDirectory: true)
        let destination = folder.appendingPathComponent(item.name)
        try await copy(from: item.url, to: destination)
        return destination
    }

    /// Copies a file to or from the drive. No timeout: copying a large video legitimately
    /// takes a while. Cancelling the task stops it between chunks instead.
    static func copy(from source: URL, to destination: URL) async throws {
        let cancelled = LockedValue(false)
        try await withTaskCancellationHandler {
            try await DriveIO.run {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try copyFile(from: source, to: destination, isCancelled: { cancelled.value })
            }
        } onCancel: {
            cancelled.value = true
        }
    }

    /// Copies in chunks, checking `isCancelled` between them. A cancelled or failed copy
    /// leaves no partial file behind.
    private static func copyFile(from source: URL, to destination: URL, isCancelled: () -> Bool) throws {
        let chunkSize = 4 * 1024 * 1024
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while true {
                if isCancelled() { throw CancellationError() }
                guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // Keep the original date, as copyItem did: some apps show it for shared files.
        if let modified = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        }
    }

    /// Adds a staged copy to the photo library, moving the file in rather than copying it again.
    static func addToPhotoLibrary(_ fileURL: URL, item: MediaItem) async throws {
        try await addToPhotoLibrary(fileURL, name: item.name, kind: item.kind)
    }

    static func addToPhotoLibrary(_ fileURL: URL, name: String, kind: MediaKind) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.originalFilename = name
            // Spelling out the type helps Photos with formats it can't guess from the
            // name alone, camera RAW especially.
            options.uniformTypeIdentifier = UTType(filenameExtension: fileURL.pathExtension.lowercased())?.identifier
            PHAssetCreationRequest.forAsset().addResource(
                with: kind == .video ? .video : .photo,
                fileURL: fileURL,
                options: options
            )
        }
    }

    /// Permanently deletes the file from the drive.
    static func deleteFile(_ item: MediaItem) async throws {
        do {
            try await DriveIO.run(timeout: 15) {
                // Looked up fresh, right before deleting: removeItem would also take a whole
                // folder with it, so anything other than a plain file is refused.
                var fresh = item.url
                fresh.removeAllCachedResourceValues()
                guard try fresh.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw ExportError.notAFile
                }
                try FileManager.default.removeItem(at: fresh)
            }
        } catch DriveError.notResponding {
            // The delete keeps going on the drive after the wait gives up, so it may have
            // happened anyway. Only report a failure if the file is really still there.
            let stillThere = try? await DriveIO.run(timeout: 3) {
                FileManager.default.fileExists(atPath: item.url.path)
            }
            if stillThere != false { throw DriveError.notResponding }
        }
        await FolderScanner.forgetCovers(showing: item.url)
    }

    @MainActor
    static func presentShareSheet(for urls: [URL], onFinish: @escaping () -> Void) {
        guard let presenter = topViewController() else {
            onFinish()
            return
        }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80, width: 1, height: 1)
        }
        presenter.present(controller, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
