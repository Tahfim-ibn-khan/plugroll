import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private static let sortKey = "mediaSort"
    private static let folderSortKey = "folderSort"
    private static let bookmarkKey = "driveBookmark"

    private(set) var rootURL: URL?
    var path: [FolderEntry] = []
    var errorMessage: String?
    /// Shared by every folder, and remembered between launches.
    private(set) var sort: MediaSort = .newest
    private(set) var folderSort: FolderSort = .nameAscending

    /// False while the opened drive is unplugged or not answering.
    private(set) var isDriveConnected = true
    /// Goes up each time the drive comes back, so screens that failed can load again.
    private(set) var reconnectCount = 0

    /// Used and free space on the opened drive, for the storage gauge.
    private(set) var driveSpace: DriveSpace?
    /// Goes up when the storage screens delete, restore or replace files, so folder
    /// screens further back pick up the change.
    private(set) var contentVersion = 0
    /// The drive scan behind the Storage screen.
    let storage = StorageModel()

    private var isAccessingRoot = false
    private var monitor: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.sortKey) ?? ""
        sort = MediaSort(rawValue: saved) ?? .newest
        let savedFolderSort = UserDefaults.standard.string(forKey: Self.folderSortKey) ?? ""
        folderSort = FolderSort(rawValue: savedFolderSort) ?? .nameAscending
    }

    /// Starts reading a folder picked with the system folder picker (e.g. the SSD root).
    func open(_ url: URL) {
        closeRoot()
        // Folders outside the app sandbox (like an external drive) need explicit access.
        isAccessingRoot = url.startAccessingSecurityScopedResource()
        rootURL = url
        path = []
        setDriveConnected(true)
        startMonitoring(url)
        saveBookmark(for: url)
        Favourites.shared.setRoot(url)
        storage.reset()
        driveSpace = nil
        refreshSpace()
        Task { [storage] in
            // Files that have waited 30 days in Recently Deleted go for good.
            _ = try? await RecentlyDeleted.purge(root: url)
            guard self.rootURL == url else { return }
            await storage.refreshRecentlyDeleted(root: url)
            self.refreshSpace()
        }
    }

    /// Reads the drive's used and free space again.
    func refreshSpace() {
        guard let root = rootURL else { return }
        Task {
            let space = await DriveSpace.read(root)
            guard rootURL == root, let space else { return }
            if space != driveSpace { driveSpace = space }
        }
    }

    /// Call after files on the drive were deleted, restored or replaced from somewhere
    /// other than the folder screen showing them.
    func driveContentsChanged() {
        contentVersion += 1
        refreshSpace()
    }

    /// Reopens the drive picked last time, if it is plugged in. Otherwise the bookmark is
    /// kept, so a later launch with the drive attached still opens it.
    func restoreLastDrive() async {
        guard rootURL == nil, let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        // Off the main thread and time-limited: resolving can touch the drive.
        let resolved = try? await DriveIO.run(timeout: 5) { () -> URL? in
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &isStale)
            return (try? url.checkResourceIsReachable()) == true ? url : nil
        }
        guard rootURL == nil, let url = resolved ?? nil else { return }
        open(url)
    }

    private func saveBookmark(for url: URL) {
        // Made while access is on; a bookmark to a picked folder carries that access.
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    func closeRoot() {
        Task { await FolderScanner.resetCovers() }
        monitor?.cancel()
        monitor = nil
        if isAccessingRoot, let rootURL {
            // Off the main thread: on an unplugged drive even this can block.
            DriveIO.start { rootURL.stopAccessingSecurityScopedResource() }
        }
        isAccessingRoot = false
        rootURL = nil
        Favourites.shared.setRoot(nil)
        storage.reset()
        driveSpace = nil
        path = []
        setDriveConnected(true)
    }

    /// Checks the drive every couple of seconds. While it's gone, drive work fails at once
    /// instead of hanging, and the UI says so.
    private func startMonitoring(_ url: URL) {
        monitor = Task { @MainActor [weak self] in
            var checks = 0
            while !Task.isCancelled {
                let connected = await DriveIO.probe(url)
                guard !Task.isCancelled else { return }
                self?.setDriveConnected(connected)
                // Free space changes as files are copied on elsewhere; look every 10 seconds.
                checks += 1
                if connected, checks % 5 == 0 { self?.refreshSpace() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func setDriveConnected(_ connected: Bool) {
        DriveIO.isAvailable = connected
        guard connected != isDriveConnected else { return }
        isDriveConnected = connected
        if connected {
            reconnectCount += 1
            refreshSpace()
        }
    }

    func setSort(_ newValue: MediaSort) {
        guard newValue != sort else { return }
        sort = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.sortKey)
    }

    func setFolderSort(_ newValue: FolderSort) {
        guard newValue != folderSort else { return }
        folderSort = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.folderSortKey)
    }
}
