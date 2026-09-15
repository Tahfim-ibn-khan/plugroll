import Foundation

/// On-phone cache folders for things made from the drive's files (thumbnails, durations).
///
/// Thumbnails are small copies of private photos, so the folder is kept encrypted while
/// the phone is locked, and trimmed to a size limit instead of growing forever.
enum CacheDirectory {
    static func make(named name: String, sizeLimit: Int) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            // New files inherit this: unreadable while locked, but still writable.
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: directory.path
        )
        DispatchQueue.global(qos: .utility).async {
            trim(directory, to: sizeLimit)
        }
        return directory
    }

    /// Deletes the least recently used files until the folder is well under `limit` bytes.
    /// Also moves files written before the folder was protected into the protected class.
    private static func trim(_ directory: URL, to limit: Int) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int, used: Date)] = []
        var total = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let size = values.totalFileAllocatedSize ?? 0
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            files.append((url, size, used))
            total += size
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path
            )
        }
        guard total > limit else { return }

        // Down to 80%, so the next few launches don't each trim a handful of files.
        let target = limit * 8 / 10
        for file in files.sorted(by: { $0.used < $1.used }) {
            guard total > target else { break }
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }
}
