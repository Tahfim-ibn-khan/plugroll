import Foundation
import Observation

/// The photos and videos marked as favourites, remembered per drive.
///
/// Files are stored as paths relative to the opened root, so a drive that comes back at
/// a different mount point keeps its favourites.
@MainActor
@Observable
final class Favourites {
    static let shared = Favourites()

    /// Most recently favourited first.
    private(set) var paths: [String] = []

    @ObservationIgnored private var lookup: Set<String> = []
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var storageKey: String?

    var count: Int { paths.count }

    /// Switches to the favourites of the drive that was just opened (none if it closed).
    func setRoot(_ url: URL?) {
        root = url
        // Named after the drive, so each drive keeps its own list.
        storageKey = url.map { "favourites.\($0.lastPathComponent)" }
        paths = storageKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? []
        lookup = Set(paths)
    }

    func isFavourite(_ item: MediaItem) -> Bool {
        guard let path = relativePath(for: item.url) else { return false }
        return lookup.contains(path)
    }

    func areAllFavourite(_ items: [MediaItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { isFavourite($0) }
    }

    /// Favourites everything, unless it all is already, in which case it un-favourites.
    func toggle(_ items: [MediaItem]) {
        setFavourite(!areAllFavourite(items), for: items)
    }

    func setFavourite(_ on: Bool, for items: [MediaItem]) {
        let changed = items.compactMap { relativePath(for: $0.url) }
        guard !changed.isEmpty else { return }
        if on {
            for path in changed.reversed() where !lookup.contains(path) {
                paths.insert(path, at: 0)
                lookup.insert(path)
            }
        } else {
            let gone = Set(changed)
            paths.removeAll { gone.contains($0) }
            lookup.subtract(gone)
        }
        if let storageKey { UserDefaults.standard.set(paths, forKey: storageKey) }
    }

    /// The favourites still on the drive. Ones it can't read (deleted elsewhere, or a
    /// drive that isn't answering) are left out but stay on the list.
    func items() async -> [MediaItem] {
        guard let root else { return [] }
        let wanted = paths
        let found = try? await DriveIO.run(timeout: 20) { () -> [MediaItem] in
            wanted.compactMap { path in
                let url = root.appendingPathComponent(path)
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let kind = MediaKind(url: url)
                else { return nil }
                return MediaItem(
                    url: url,
                    kind: kind,
                    modified: values.contentModificationDate ?? .distantPast,
                    fileSize: values.fileSize ?? 0
                )
            }
        }
        return found ?? []
    }

    private func relativePath(for url: URL) -> String? {
        guard let root else { return nil }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(base) else { return nil }
        return String(url.path.dropFirst(base.count))
    }
}
