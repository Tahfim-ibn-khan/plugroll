import Photos
import UIKit

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
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: item.url, to: destination)
        }.value
        return destination
    }

    /// Adds a staged copy to the photo library, moving the file in rather than copying it again.
    static func addToPhotoLibrary(_ fileURL: URL, item: MediaItem) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.originalFilename = item.name
            PHAssetCreationRequest.forAsset().addResource(
                with: item.kind == .video ? .video : .photo,
                fileURL: fileURL,
                options: options
            )
        }
    }

    /// Permanently deletes the file from the drive.
    static func deleteFile(_ item: MediaItem) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(at: item.url)
        }.value
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
