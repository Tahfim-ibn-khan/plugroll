import Foundation
import Observation
import Vision

/// The drive scan behind the Storage screen, and what it found. Owned by `AppState`, so
/// leaving the screen and coming back doesn't scan again. Screens that delete, restore
/// or replace files tell it, so the lists stay right without a rescan.
@MainActor
@Observable
final class StorageModel {
    enum Phase: Equatable {
        case idle
        case indexing(found: Int)
        case hashing(done: Int, total: Int)
        case analyzing(done: Int, total: Int)
        case grouping
        case finished
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .indexing, .hashing, .analyzing, .grouping: return true
            case .idle, .finished, .failed: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var lastScan: Date?

    // From the drive walk, available as soon as it ends.
    private(set) var items: [MediaItem] = []
    private(set) var bigVideos: [MediaItem] = []
    private(set) var largest: [MediaItem] = []
    private(set) var folderSizes: [FolderSize] = []

    // From looking inside the files; only complete once `hasAnalysis` is true.
    private(set) var hasAnalysis = false
    private(set) var duplicates: [CleanupGroup] = []
    private(set) var similarPhotos: [CleanupGroup] = []
    private(set) var similarVideos: [CleanupGroup] = []
    private(set) var screenshots: [MediaItem] = []
    private(set) var blurry: [MediaItem] = []
    private(set) var dark: [MediaItem] = []
    private(set) var facts: [URL: MediaFacts] = [:]

    private(set) var recentlyDeletedCount = 0
    private(set) var recentlyDeletedBytes = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    var hasIndex: Bool { lastScan != nil || !items.isEmpty }

    // MARK: - Scanning

    func scan(root: URL) {
        guard !phase.isRunning else { return }
        task = Task { await runScan(root: root) }
    }

    func cancel() {
        task?.cancel()
    }

    /// Forgets everything, when a different drive is opened.
    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        lastScan = nil
        items = []
        bigVideos = []
        largest = []
        folderSizes = []
        hasAnalysis = false
        duplicates = []
        similarPhotos = []
        similarVideos = []
        screenshots = []
        blurry = []
        dark = []
        facts = [:]
        recentlyDeletedCount = 0
        recentlyDeletedBytes = 0
    }

    private func runScan(root: URL) async {
        do {
            phase = .indexing(found: 0)
            hasAnalysis = false
            let index = try await DriveIndex.scan(root: root) { found in
                Task { @MainActor [weak self] in
                    guard let self, case .indexing = self.phase else { return }
                    self.phase = .indexing(found: found)
                }
            }
            items = index.items
            folderSizes = index.folderSizes
            updateFileLists()
            lastScan = Date()

            // Exact copies: only files sharing a size are worth reading in full.
            let candidates = CleanupFinder.sameSizeCandidates(index.items).flatMap { $0 }
            let hashes = try await runEach(candidates, width: 2, phase: { .hashing(done: $0, total: $1) }) { item in
                await MediaAnalyzer.shared.contentHash(for: item)
            }

            let found = try await runEach(index.items, width: 4, phase: { .analyzing(done: $0, total: $1) }) { item in
                await MediaAnalyzer.shared.facts(for: item)
            }

            phase = .grouping
            let favourites = Set(index.items.filter { Favourites.shared.isFavourite($0) }.map(\.url))
            let result = await Task.detached(priority: .userInitiated) {
                Self.findGroups(items: index.items, hashes: hashes, facts: found, favourites: favourites)
            }.value
            try Task.checkCancellation()

            facts = found
            duplicates = result.duplicates
            similarPhotos = result.similarPhotos
            similarVideos = result.similarVideos
            screenshots = result.screenshots
            blurry = result.blurry
            dark = result.dark
            hasAnalysis = true
            phase = .finished
        } catch is CancellationError {
            // What the walk found stays; the look-inside lists wait for a full scan.
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
        await refreshRecentlyDeleted(root: root)
    }

    /// Runs `work` on every item, `width` at a time, keeping the non-nil results and
    /// reporting progress. Stops when cancelled or when the drive goes away.
    private func runEach<T: Sendable>(
        _ items: [MediaItem],
        width: Int,
        phase makePhase: @escaping (Int, Int) -> Phase,
        work: @escaping @Sendable (MediaItem) async -> T?
    ) async throws -> [URL: T] {
        var results: [URL: T] = [:]
        var done = 0
        phase = makePhase(0, items.count)
        try await withThrowingTaskGroup(of: (URL, T?).self) { group in
            var pending = items.makeIterator()
            for _ in 0..<width {
                guard let item = pending.next() else { break }
                group.addTask { (item.url, await work(item)) }
            }
            while let (url, value) = try await group.next() {
                try Task.checkCancellation()
                guard DriveIO.isAvailable else { throw DriveError.disconnected }
                if let value { results[url] = value }
                done += 1
                phase = makePhase(done, items.count)
                if let item = pending.next() {
                    group.addTask { (item.url, await work(item)) }
                }
            }
        }
        return results
    }

    private struct Groups: Sendable {
        var duplicates: [CleanupGroup] = []
        var similarPhotos: [CleanupGroup] = []
        var similarVideos: [CleanupGroup] = []
        var screenshots: [MediaItem] = []
        var blurry: [MediaItem] = []
        var dark: [MediaItem] = []
    }

    private nonisolated static func findGroups(
        items: [MediaItem],
        hashes: [URL: String],
        facts: [URL: MediaFacts],
        favourites: Set<URL>
    ) -> Groups {
        let isFavourite = { (item: MediaItem) in favourites.contains(item.url) }
        var groups = Groups()

        let duplicateSets = CleanupFinder.duplicateGroups(items, hashes: hashes)
        groups.duplicates = CleanupFinder.makeGroups(duplicateSets, facts: facts, isFavourite: isFavourite)
        // Exact copies are dealt with there; look-alikes are about different files.
        let copies = Set(duplicateSets.flatMap { $0 }.map(\.url))
        let rest = items.filter { !copies.contains($0.url) }

        var prints: [URL: VNFeaturePrintObservation] = [:]
        for item in rest {
            if let data = facts[item.url]?.featurePrint, let print = MediaAnalyzer.featurePrint(from: data) {
                prints[item.url] = print
            }
        }
        let alike = { (a: MediaItem, b: MediaItem, threshold: Float) -> Bool in
            var featureDistance: Float?
            if let printA = prints[a.url], let printB = prints[b.url] {
                var value: Float = 0
                if (try? printA.computeDistance(&value, to: printB)) != nil { featureDistance = value }
            }
            var hashDistance: Int?
            if let hashA = facts[a.url]?.pictureHash, let hashB = facts[b.url]?.pictureHash {
                hashDistance = (hashA ^ hashB).nonzeroBitCount
            }
            return CleanupFinder.looksAlike(featureDistance: featureDistance, hashDistance: hashDistance, threshold: threshold)
        }

        let photos = rest.filter { $0.kind == .photo }
        let videos = rest.filter { $0.kind == .video }
        groups.similarPhotos = CleanupFinder.makeGroups(
            CleanupFinder.similarPhotoGroups(photos) { alike($0, $1, CleanupFinder.similarPhotoDistance) },
            facts: facts,
            isFavourite: isFavourite
        )
        let durations = facts.compactMapValues(\.duration)
        groups.similarVideos = CleanupFinder.makeGroups(
            CleanupFinder.similarVideoGroups(videos, durations: durations) { alike($0, $1, CleanupFinder.similarVideoDistance) },
            facts: facts,
            isFavourite: isFavourite
        )

        let photoFacts = items.filter { $0.kind == .photo }.compactMap { item in facts[item.url].map { (item, $0) } }
        groups.screenshots = photoFacts.filter { $0.1.isScreenshot }.map(\.0).sorted { $0.modified > $1.modified }
        let notScreenshots = photoFacts.filter { !$0.1.isScreenshot }
        groups.blurry = notScreenshots.filter { CleanupFinder.isBlurry($0.1) }.map(\.0).sorted { $0.modified > $1.modified }
        groups.dark = notScreenshots.filter { CleanupFinder.isDark($0.1) }.map(\.0).sorted { $0.modified > $1.modified }
        return groups
    }

    private func updateFileLists() {
        bigVideos = CleanupFinder.bigVideos(items)
        largest = CleanupFinder.largest(items)
    }

    // MARK: - Keeping up with changes

    /// Drops files that were deleted or moved to Recently Deleted from every list.
    func remove(_ removed: [MediaItem]) {
        guard !removed.isEmpty else { return }
        let gone = Set(removed.map(\.url))
        guard items.contains(where: { gone.contains($0.url) }) else { return }

        for item in removed {
            guard let bucket = folderSizes.firstIndex(where: { contains($0, item.url) }) else { continue }
            folderSizes[bucket].bytes = max(0, folderSizes[bucket].bytes - item.fileSize)
            folderSizes[bucket].mediaCount = max(0, folderSizes[bucket].mediaCount - 1)
        }
        folderSizes.sort { $0.bytes > $1.bytes }

        items.removeAll { gone.contains($0.url) }
        updateFileLists()
        duplicates = prune(duplicates, removing: gone)
        similarPhotos = prune(similarPhotos, removing: gone)
        similarVideos = prune(similarVideos, removing: gone)
        screenshots.removeAll { gone.contains($0.url) }
        blurry.removeAll { gone.contains($0.url) }
        dark.removeAll { gone.contains($0.url) }
    }

    /// A file was trimmed or compressed in place: it has a new size and cache key.
    func replace(_ old: MediaItem, with new: MediaItem) {
        let difference = old.fileSize - new.fileSize
        if let bucket = folderSizes.firstIndex(where: { contains($0, old.url) }) {
            folderSizes[bucket].bytes = max(0, folderSizes[bucket].bytes - difference)
            folderSizes.sort { $0.bytes > $1.bytes }
        }
        items = items.map { $0.url == old.url ? new : $0 }
        updateFileLists()
        // Its old fingerprints no longer apply; the next scan works them out again.
        let gone: Set<URL> = [old.url]
        duplicates = prune(duplicates, removing: gone)
        similarPhotos = prune(similarPhotos, removing: gone)
        similarVideos = prune(similarVideos, removing: gone)
    }

    /// Adds a file made by an edit or compression (a copy next to the original).
    func add(_ item: MediaItem) {
        guard hasIndex, !items.contains(where: { $0.url == item.url }) else { return }
        items.append(item)
        if let bucket = folderSizes.firstIndex(where: { contains($0, item.url) }) {
            folderSizes[bucket].bytes += item.fileSize
            folderSizes[bucket].mediaCount += 1
            folderSizes.sort { $0.bytes > $1.bytes }
        }
        updateFileLists()
    }

    func refreshRecentlyDeleted(root: URL) async {
        let entries = (try? await RecentlyDeleted.entries(root: root)) ?? []
        recentlyDeletedCount = entries.count
        recentlyDeletedBytes = entries.reduce(0) { $0 + $1.fileSize }
    }

    private func prune(_ groups: [CleanupGroup], removing gone: Set<URL>) -> [CleanupGroup] {
        groups.compactMap { group in
            let left = group.items.filter { !gone.contains($0.url) }
            guard left.count > 1 else { return nil }
            if left.count == group.items.count { return group }
            let keeper = left.contains(group.keeper)
                ? group.keeper
                : CleanupFinder.keeper(of: left, facts: facts, isFavourite: { Favourites.shared.isFavourite($0) })
            return CleanupGroup(items: left, keeper: keeper)
        }
    }

    private func contains(_ folder: FolderSize, _ url: URL) -> Bool {
        if folder.isTopLevelFiles {
            return url.deletingLastPathComponent().standardizedFileURL.path == folder.url.standardizedFileURL.path
        }
        let base = folder.url.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
