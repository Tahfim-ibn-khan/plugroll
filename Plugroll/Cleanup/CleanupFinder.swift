import Foundation

/// A set of copies or look-alikes, with the one the app suggests keeping.
struct CleanupGroup: Identifiable, Hashable, Sendable {
    let items: [MediaItem]
    let keeper: MediaItem

    /// Stable while the group's files don't change.
    var id: String { items.map(\.url.path).sorted().joined(separator: "|") }
    var totalBytes: Int { items.reduce(0) { $0 + $1.fileSize } }
    /// What deleting all but the suggested one would free.
    var reclaimableBytes: Int { totalBytes - keeper.fileSize }
    var others: [MediaItem] { items.filter { $0.url != keeper.url } }

    /// A group may never lose every file: at least one must stay unmarked.
    func allows(marking marked: Set<URL>) -> Bool {
        items.contains { !marked.contains($0.url) }
    }
}

/// The rules behind the cleanup lists. Kept free of file and drive access so they can be
/// tested on their own; `StorageModel` feeds them what the scan found.
enum CleanupFinder {
    /// Videos at least this big are listed under Big Videos.
    static let bigVideoBytes = 500 * 1024 * 1024
    /// Photos whose sharpness score is below this are listed as blurry.
    static let blurThreshold = 40.0
    /// Photos darker than this on average (0...1) are listed as dark.
    static let darkThreshold = 0.07
    /// Feature-print distances at or below these count as look-alikes.
    static let similarPhotoDistance: Float = 0.45
    static let similarVideoDistance: Float = 0.4
    /// Difference-hash bits (of 64) that may differ between look-alikes. Both checks
    /// must agree, so one misjudging never puts different pictures together.
    static let similarHashBits = 20
    /// Without a feature print, the hash alone has to be much closer.
    static let hashOnlyBits = 8

    /// Whether two pictures look alike, from what the scan measured.
    static func looksAlike(featureDistance: Float?, hashDistance: Int?, threshold: Float) -> Bool {
        guard let hashDistance else { return false }
        guard let featureDistance else { return hashDistance <= hashOnlyBits }
        return featureDistance <= threshold && hashDistance <= similarHashBits
    }
    /// Only photos taken this close together are compared, the way bursts and retakes
    /// happen. It also keeps a big drive from needing every photo checked against every other.
    static let similarWindow: TimeInterval = 60 * 60
    /// And at most this many neighbours each, for folders of thousands shot in an hour.
    static let maxNeighbours = 40
    /// Videos this close in length are compared.
    static let durationTolerance: Double = 1

    // MARK: - Duplicates

    /// Files sharing a size with another: the only ones worth hashing.
    static func sameSizeCandidates(_ items: [MediaItem]) -> [[MediaItem]] {
        Dictionary(grouping: items.filter { $0.fileSize > 0 }, by: \.fileSize)
            .values
            .filter { $0.count > 1 }
            .map { $0 }
    }

    /// Files with the same size and the same content.
    static func duplicateGroups(_ items: [MediaItem], hashes: [URL: String]) -> [[MediaItem]] {
        var byContent: [String: [MediaItem]] = [:]
        for item in items {
            guard let hash = hashes[item.url] else { continue }
            byContent["\(item.fileSize)-\(hash)", default: []].append(item)
        }
        return byContent.values.filter { $0.count > 1 }.map { $0 }
    }

    // MARK: - Look-alikes

    /// Photos taken within `window` of each other whose pictures are close enough.
    /// Look-alikes of look-alikes join the same group.
    static func similarPhotoGroups(
        _ photos: [MediaItem],
        window: TimeInterval = similarWindow,
        isSimilar: (MediaItem, MediaItem) -> Bool
    ) -> [[MediaItem]] {
        let ordered = photos.sorted { $0.modified < $1.modified }
        var links = UnionFind(count: ordered.count)
        for i in ordered.indices {
            var checked = 0
            var j = i + 1
            while j < ordered.count, checked < maxNeighbours,
                  ordered[j].modified.timeIntervalSince(ordered[i].modified) <= window {
                if isSimilar(ordered[i], ordered[j]) { links.union(i, j) }
                checked += 1
                j += 1
            }
        }
        return links.groups().map { $0.map { ordered[$0] } }
    }

    /// Videos of about the same length whose pictures are close enough. Dates are
    /// ignored: a copy exported elsewhere often has a new one.
    static func similarVideoGroups(
        _ videos: [MediaItem],
        durations: [URL: Double],
        isSimilar: (MediaItem, MediaItem) -> Bool
    ) -> [[MediaItem]] {
        let ordered = videos
            .compactMap { video in durations[video.url].map { (video, $0) } }
            .sorted { $0.1 < $1.1 }
        var links = UnionFind(count: ordered.count)
        for i in ordered.indices {
            var j = i + 1
            while j < ordered.count, ordered[j].1 - ordered[i].1 <= durationTolerance {
                if isSimilar(ordered[i].0, ordered[j].0) { links.union(i, j) }
                j += 1
            }
        }
        return links.groups().map { $0.map { ordered[$0].0 } }
    }

    // MARK: - Choosing what to keep

    /// A favourite first, then the most pixels, the biggest file, the oldest, and the
    /// shortest name (copies tend to be called "IMG_1 copy" or "IMG_1 (1)").
    static func keeper(of items: [MediaItem], facts: [URL: MediaFacts], isFavourite: (MediaItem) -> Bool) -> MediaItem {
        items.max { a, b in
            let favA = isFavourite(a), favB = isFavourite(b)
            if favA != favB { return !favA }
            let pixA = facts[a.url]?.pixelCount ?? 0, pixB = facts[b.url]?.pixelCount ?? 0
            if pixA != pixB { return pixA < pixB }
            if a.fileSize != b.fileSize { return a.fileSize < b.fileSize }
            if a.modified != b.modified { return a.modified > b.modified }
            if a.name.count != b.name.count { return a.name.count > b.name.count }
            return a.url.path > b.url.path
        }!
    }

    /// Groups with their keepers, the ones that free the most first.
    static func makeGroups(_ raw: [[MediaItem]], facts: [URL: MediaFacts], isFavourite: (MediaItem) -> Bool) -> [CleanupGroup] {
        raw.filter { $0.count > 1 }
            .map { items in
                let sorted = items.sorted { $0.modified < $1.modified }
                return CleanupGroup(items: sorted, keeper: keeper(of: sorted, facts: facts, isFavourite: isFavourite))
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    // MARK: - Single-file lists

    static func bigVideos(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { $0.kind == .video && $0.fileSize >= bigVideoBytes }
            .sorted { $0.fileSize > $1.fileSize }
    }

    static func largest(_ items: [MediaItem], limit: Int = 200) -> [MediaItem] {
        Array(items.sorted { $0.fileSize > $1.fileSize }.prefix(limit))
    }

    static func isBlurry(_ facts: MediaFacts) -> Bool {
        guard let score = facts.blurScore else { return false }
        // A nearly black picture has no edges either; that's "dark", not "blurry".
        return score < blurThreshold && !isDark(facts)
    }

    static func isDark(_ facts: MediaFacts) -> Bool {
        guard let brightness = facts.brightness else { return false }
        return brightness < darkThreshold
    }
}

/// Joins indices into groups: anything linked, directly or through others, ends up together.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a), rootB = find(b)
        if rootA != rootB { parent[rootB] = rootA }
    }

    /// Groups of two or more, each in index order.
    mutating func groups() -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for index in parent.indices {
            byRoot[find(index), default: []].append(index)
        }
        return byRoot.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }
}
