import Foundation

/// Reads folders on the drive. Each call looks at one folder only (no deep scans).
enum FolderScanner {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey,
    ]

    static func list(_ folder: URL) async throws -> FolderListing {
        // Generous: a folder of thousands of files on a slow drive takes a while.
        try await DriveIO.run(timeout: 30) {
            try FolderScanner.scan(folder)
        }
    }

    /// First photo or video inside a folder (looking up to two levels down), used as its cover.
    static func cover(for folder: URL) async -> MediaItem? {
        if let cached = await CoverCache.shared.value(for: folder) { return cached }
        do {
            let found = try await DriveIO.run(timeout: 10) { FolderScanner.findCover(in: folder) }
            await CoverCache.shared.store(found, for: folder)
            return found
        } catch {
            // Not cached, so the cover is looked for again once the drive is back.
            return nil
        }
    }

    private static func scan(_ folder: URL) throws -> FolderListing {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles] // also skips macOS "._" junk files on exFAT drives
        )

        var folders: [FolderEntry] = []
        var items: [MediaItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if values?.isPackage != true { folders.append(makeFolder(url, values: values)) }
                continue
            }
            if let item = makeItem(url, values: values) { items.append(item) }
        }

        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        items.sort { $0.modified > $1.modified }
        return FolderListing(folders: folders, items: items)
    }

    /// Finds folders, photos and videos whose names contain `query`, anywhere below
    /// `folder`. Matches arrive in small batches as the walk goes, so results show up
    /// while a big drive is still being searched. Cancelling the consumer stops the walk.
    static func search(in folder: URL, query: String) -> AsyncStream<FolderListing> {
        AsyncStream { continuation in
            let cancelled = LockedValue(false)
            continuation.onTermination = { _ in cancelled.value = true }
            guard DriveIO.isAvailable else {
                continuation.finish()
                return
            }
            DriveIO.start {
                let shouldStop = { cancelled.value || !DriveIO.isAvailable }
                FolderScanner.walk(folder, matching: query, isCancelled: shouldStop) { batch in
                    continuation.yield(batch)
                }
                continuation.finish()
            }
        }
    }

    private static func walk(
        _ folder: URL,
        matching query: String,
        isCancelled: () -> Bool,
        emit: (FolderListing) -> Void
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var batch = FolderListing(folders: [], items: [])
        var lastEmit = Date()

        for case let url as URL in enumerator {
            if isCancelled() { return }
            guard url.lastPathComponent.localizedStandardContains(query) else { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if values?.isPackage != true { batch.folders.append(makeFolder(url, values: values)) }
            } else if let item = makeItem(url, values: values) {
                batch.items.append(item)
            }

            if batch.folders.count + batch.items.count >= 50 || Date().timeIntervalSince(lastEmit) > 0.3 {
                emit(batch)
                batch = FolderListing(folders: [], items: [])
                lastEmit = Date()
            }
        }
        if !batch.folders.isEmpty || !batch.items.isEmpty { emit(batch) }
    }

    private static func makeFolder(_ url: URL, values: URLResourceValues?) -> FolderEntry {
        FolderEntry(url: url, modified: values?.contentModificationDate ?? .distantPast)
    }

    private static func findCover(in folder: URL) -> MediaItem? {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                // Descend one level below this folder, no further: skipping has to be
                // asked for on the directory itself, not on a file already inside it.
                if enumerator.level >= 2 { enumerator.skipDescendants() }
                continue
            }
            if let item = makeItem(url, values: values) { return item }
        }
        return nil
    }

    private static func makeItem(_ url: URL, values: URLResourceValues?) -> MediaItem? {
        guard let kind = MediaKind(url: url) else { return nil }
        return MediaItem(
            url: url,
            kind: kind,
            modified: values?.contentModificationDate ?? .distantPast,
            fileSize: values?.fileSize ?? 0
        )
    }
}

private actor CoverCache {
    static let shared = CoverCache()
    // Stores nil too, so folders without media aren't searched again.
    private var covers: [URL: MediaItem?] = [:]

    func value(for folder: URL) -> MediaItem?? { covers[folder] }
    func store(_ item: MediaItem?, for folder: URL) { covers[folder] = .some(item) }
}
