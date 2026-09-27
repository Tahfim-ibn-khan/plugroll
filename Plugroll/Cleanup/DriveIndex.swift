import Foundation

/// How much room one folder at the top of the drive takes, counting everything inside it.
struct FolderSize: Identifiable, Hashable, Sendable {
    let url: URL
    /// True for the files lying loose at the top of the drive, outside any folder.
    let isTopLevelFiles: Bool
    var bytes: Int
    var mediaCount: Int

    var id: URL { url }
    var name: String { isTopLevelFiles ? "Files at Top Level" : url.lastPathComponent }
}

/// Every photo and video on the drive, from one walk, plus the size of each top folder.
struct DriveIndex: Sendable {
    var items: [MediaItem] = []
    var folderSizes: [FolderSize] = []

    /// Walks everything below `root`. Hidden files and folders (Recently Deleted
    /// among them) are left out. `progress` gets the number of photos and videos so far.
    static func build(
        root: URL,
        isCancelled: () -> Bool = { false },
        progress: (Int) -> Void = { _ in }
    ) throws -> DriveIndex {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return DriveIndex() }

        var index = DriveIndex()
        var sizes: [String: FolderSize] = [:]
        let loose = FolderSize(url: root, isTopLevelFiles: true, bytes: 0, mediaCount: 0)
        var lastReport = Date()

        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true || values?.isPackage == true else { continue }
            guard values?.isRegularFile == true || values?.isPackage == true else { continue }

            let top = topFolderName(of: url, root: root)
            let bucketKey = top ?? ""
            var bucket = sizes[bucketKey] ?? (top.map {
                FolderSize(url: root.appendingPathComponent($0, isDirectory: true), isTopLevelFiles: false, bytes: 0, mediaCount: 0)
            } ?? loose)
            bucket.bytes += values?.fileSize ?? 0

            if let item = FolderScanner.makeItem(url, values: values) {
                index.items.append(item)
                bucket.mediaCount += 1
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    progress(index.items.count)
                    lastReport = Date()
                }
            }
            sizes[bucketKey] = bucket
        }
        progress(index.items.count)
        index.folderSizes = sizes.values.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        return index
    }

    /// Runs `build` on the drive queue. Cancelling the task stops the walk; an unplugged
    /// drive stops it too, with an error.
    static func scan(root: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> DriveIndex {
        guard DriveIO.isAvailable else { throw DriveError.disconnected }
        let cancelled = LockedValue(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DriveIO.start {
                    do {
                        let index = try build(
                            root: root,
                            isCancelled: { cancelled.value || !DriveIO.isAvailable },
                            progress: progress
                        )
                        continuation.resume(returning: index)
                    } catch {
                        let reason: Error = cancelled.value ? CancellationError()
                            : (DriveIO.isAvailable ? error : DriveError.disconnected)
                        continuation.resume(throwing: reason)
                    }
                }
            }
        } onCancel: {
            cancelled.value = true
        }
    }

    /// The first folder under the root that `url` is inside, or nil for a loose file.
    private static func topFolderName(of url: URL, root: URL) -> String? {
        guard let relative = RecentlyDeleted.relativePath(of: url, root: root) else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count > 1 ? String(parts[0]) : nil
    }
}
