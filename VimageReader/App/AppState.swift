import Foundation
import Observation

@Observable
final class AppState {
    private static let sortKey = "mediaSort"
    private static let folderSortKey = "folderSort"

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
    }

    func closeRoot() {
        monitor?.cancel()
        monitor = nil
        if isAccessingRoot, let rootURL {
            // Off the main thread: on an unplugged drive even this can block.
            DriveIO.start { rootURL.stopAccessingSecurityScopedResource() }
        }
        isAccessingRoot = false
        rootURL = nil
        path = []
        setDriveConnected(true)
    }

    /// Checks the drive every couple of seconds. While it's gone, drive work fails at once
    /// instead of hanging, and the UI says so.
    private func startMonitoring(_ url: URL) {
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let connected = await DriveIO.probe(url)
                guard !Task.isCancelled else { return }
                self?.setDriveConnected(connected)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func setDriveConnected(_ connected: Bool) {
        DriveIO.isAvailable = connected
        guard connected != isDriveConnected else { return }
        isDriveConnected = connected
        if connected { reconnectCount += 1 }
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
