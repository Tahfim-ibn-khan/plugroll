import Foundation

/// One file waiting in Recently Deleted.
struct DeletedEntry: Codable, Identifiable, Hashable, Sendable {
    /// Also the name of the entry's folder inside Recently Deleted.
    let id: String
    /// Where the file was, relative to the drive's root.
    let originalPath: String
    let deletedAt: Date
    let modified: Date
    let fileSize: Int

    var name: String { (originalPath as NSString).lastPathComponent }

    /// Days until it is deleted for good, like Photos shows.
    func daysLeft(now: Date = Date()) -> Int {
        let remaining = deletedAt.addingTimeInterval(RecentlyDeleted.retention).timeIntervalSince(now)
        return max(0, Int((remaining / 86_400).rounded(.up)))
    }
}

enum RecentlyDeletedError: LocalizedError {
    case outsideDrive

    var errorDescription: String? {
        switch self {
        case .outsideDrive: return "The file isn't on the opened drive."
        }
    }
}

/// A hidden folder at the top of the drive that deleted files are moved into, so they
/// can be restored for 30 days. Moving is a rename on the same drive, so it is instant
/// and needs no free space; the space comes back when the folder is emptied.
///
/// Each file sits in its own folder under its own name (so two "IMG_0001.JPG" from
/// different folders can't collide), and `manifest.json` remembers where it came from.
enum RecentlyDeleted {
    /// The dot hides it from the grid, scans and searches.
    static let folderName = ".Plugroll Recently Deleted"
    static let retention: TimeInterval = 30 * 86_400
    private static let manifestName = "manifest.json"
    /// Every change reads, edits and writes the manifest; one at a time.
    private static let lock = NSLock()

    static func folder(in root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The file as it sits in Recently Deleted, for thumbnails and the viewer.
    static func item(for entry: DeletedEntry, root: URL) -> MediaItem? {
        let url = folder(in: root)
            .appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.name)
        guard let kind = MediaKind(url: url) else { return nil }
        return MediaItem(url: url, kind: kind, modified: entry.modified, fileSize: entry.fileSize)
    }

    /// Where the file was before it was deleted.
    static func originalURL(for entry: DeletedEntry, root: URL) -> URL {
        root.appendingPathComponent(entry.originalPath)
    }

    // MARK: - Async API (through DriveIO)

    static func trash(_ items: [MediaItem], root: URL) async throws -> [DeletedEntry] {
        var moved: [DeletedEntry] = []
        for item in items {
            try Task.checkCancellation()
            moved.append(try await trash(item, root: root))
        }
        return moved
    }

    static func trash(_ item: MediaItem, root: URL) async throws -> DeletedEntry {
        let entry = try await DriveIO.run(timeout: 15) {
            // Looked up fresh, like Delete: only a plain file may be moved.
            var fresh = item.url
            fresh.removeAllCachedResourceValues()
            guard try fresh.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ExportError.notAFile
            }
            return try moveIn(file: item.url, recordingAs: item.url, root: root, modified: item.modified, size: item.fileSize)
        }
        await FolderScanner.forgetCovers(showing: item.url)
        return entry
    }

    /// Entries whose file is still there, newest first.
    static func entries(root: URL) async throws -> [DeletedEntry] {
        try await DriveIO.run(timeout: 20) { entriesSync(root: root) }
    }

    /// Puts files back where they were. Returns the restored files, at their new places.
    static func restore(_ entries: [DeletedEntry], root: URL) async throws -> [MediaItem] {
        try await DriveIO.run(timeout: 30) {
            try entries.compactMap { try restoreSync($0, root: root) }
        }
    }

    static func deletePermanently(_ entries: [DeletedEntry], root: URL) async throws {
        try await DriveIO.run(timeout: 60) { try deleteSync(entries, root: root) }
    }

    static func empty(root: URL) async throws {
        try await DriveIO.run(timeout: 120) { try deleteSync(entriesSync(root: root), root: root) }
    }

    /// Deletes for good whatever has been waiting longer than 30 days.
    @discardableResult
    static func purge(root: URL, now: Date = Date()) async throws -> [DeletedEntry] {
        try await DriveIO.run(timeout: 60) { try purgeSync(root: root, now: now) }
    }

    static func totalSize(root: URL) async -> Int {
        let entries = (try? await entries(root: root)) ?? []
        return entries.reduce(0) { $0 + $1.fileSize }
    }

    // MARK: - Blocking work (call on the drive queue)

    /// Moves `file` into Recently Deleted, remembering it as having been at `original`.
    /// They differ while an edit replaces a file: the old version has already been renamed.
    static func moveIn(file: URL, recordingAs original: URL, root: URL, modified: Date, size: Int, now: Date = Date()) throws -> DeletedEntry {
        guard let relative = relativePath(of: original, root: root) else { throw RecentlyDeletedError.outsideDrive }
        let files = FileManager.default
        let id = UUID().uuidString
        let entryFolder = folder(in: root).appendingPathComponent(id, isDirectory: true)

        return try lock.withLock {
            try files.createDirectory(at: entryFolder, withIntermediateDirectories: true)
            do {
                try files.moveItem(at: file, to: entryFolder.appendingPathComponent(original.lastPathComponent))
            } catch {
                try? files.removeItem(at: entryFolder)
                throw error
            }
            let entry = DeletedEntry(id: id, originalPath: relative, deletedAt: now, modified: modified, fileSize: size)
            var manifest = readManifest(root: root)
            manifest.insert(entry, at: 0)
            try writeManifest(manifest, root: root)
            return entry
        }
    }

    static func entriesSync(root: URL) -> [DeletedEntry] {
        lock.withLock {
            readManifest(root: root).filter { entry in
                item(for: entry, root: root).map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false
            }
        }
    }

    static func restoreSync(_ entry: DeletedEntry, root: URL) throws -> MediaItem? {
        guard let trashed = item(for: entry, root: root) else { return nil }
        let files = FileManager.default
        return try lock.withLock {
            let wanted = originalURL(for: entry, root: root)
            let target = uniqueRestoreURL(for: wanted) { files.fileExists(atPath: $0.path) }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: trashed.url, to: target)
            try? files.removeItem(at: trashed.url.deletingLastPathComponent())
            var manifest = readManifest(root: root)
            manifest.removeAll { $0.id == entry.id }
            try writeManifest(manifest, root: root)
            return MediaItem(url: target, kind: trashed.kind, modified: entry.modified, fileSize: entry.fileSize)
        }
    }

    static func deleteSync(_ entries: [DeletedEntry], root: URL) throws {
        guard !entries.isEmpty else { return }
        let files = FileManager.default
        try lock.withLock {
            let base = folder(in: root)
            var gone: Set<String> = []
            var lastError: Error?
            for entry in entries {
                let entryFolder = base.appendingPathComponent(entry.id, isDirectory: true)
                do {
                    if files.fileExists(atPath: entryFolder.path) { try files.removeItem(at: entryFolder) }
                    gone.insert(entry.id)
                } catch {
                    lastError = error
                }
            }
            var manifest = readManifest(root: root)
            manifest.removeAll { gone.contains($0.id) }
            try writeManifest(manifest, root: root)
            if let lastError { throw lastError }
        }
    }

    static func purgeSync(root: URL, now: Date) throws -> [DeletedEntry] {
        let expired = lock.withLock {
            readManifest(root: root).filter { now.timeIntervalSince($0.deletedAt) >= retention }
        }
        try deleteSync(expired, root: root)
        return expired
    }

    /// "IMG_1.jpg", or "IMG_1 (Restored).jpg", "IMG_1 (Restored 2).jpg"… if that's taken.
    static func uniqueRestoreURL(for wanted: URL, exists: (URL) -> Bool) -> URL {
        guard exists(wanted) else { return wanted }
        let folder = wanted.deletingLastPathComponent()
        let stem = wanted.deletingPathExtension().lastPathComponent
        let ext = wanted.pathExtension
        var number = 1
        while true {
            let label = number == 1 ? "Restored" : "Restored \(number)"
            let name = ext.isEmpty ? "\(stem) (\(label))" : "\(stem) (\(label)).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    static func relativePath(of url: URL, root: URL) -> String? {
        let base = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base), path.count > base.count else { return nil }
        return String(path.dropFirst(base.count))
    }

    // MARK: - Manifest

    private static func manifestURL(root: URL) -> URL {
        folder(in: root).appendingPathComponent(manifestName)
    }

    private static func readManifest(root: URL) -> [DeletedEntry] {
        guard let data = try? Data(contentsOf: manifestURL(root: root)) else { return [] }
        return (try? JSONDecoder().decode([DeletedEntry].self, from: data)) ?? []
    }

    private static func writeManifest(_ entries: [DeletedEntry], root: URL) throws {
        try FileManager.default.createDirectory(at: folder(in: root), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: manifestURL(root: root), options: .atomic)
    }
}
