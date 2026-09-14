import Foundation

/// Reads folders on the drive. Each call looks at one folder only (no deep scans).
enum FolderScanner {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey,
    ]

    static func list(_ folder: URL) async throws -> FolderListing {
        try await Task.detached(priority: .userInitiated) {
            try FolderScanner.scan(folder)
        }.value
    }

    /// First photo or video inside a folder (looking up to two levels down), used as its cover.
    static func cover(for folder: URL) async -> MediaItem? {
        if let cached = await CoverCache.shared.value(for: folder) { return cached }
        let found = await Task.detached(priority: .utility) { FolderScanner.findCover(in: folder) }.value
        await CoverCache.shared.store(found, for: folder)
        return found
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
                if values?.isPackage != true { folders.append(FolderEntry(url: url)) }
                continue
            }
            if let item = makeItem(url, values: values) { items.append(item) }
        }

        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        items.sort { $0.modified > $1.modified }
        return FolderListing(folders: folders, items: items)
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
