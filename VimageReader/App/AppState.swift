import Foundation
import Observation

@Observable
final class AppState {
    private static let sortKey = "mediaSort"

    private(set) var rootURL: URL?
    var path: [FolderEntry] = []
    var errorMessage: String?
    /// Shared by every folder, and remembered between launches.
    private(set) var sort: MediaSort = .newest

    private var isAccessingRoot = false

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.sortKey) ?? ""
        sort = MediaSort(rawValue: saved) ?? .newest
    }

    /// Starts reading a folder picked with the system folder picker (e.g. the SSD root).
    func open(_ url: URL) {
        closeRoot()
        // Folders outside the app sandbox (like an external drive) need explicit access.
        isAccessingRoot = url.startAccessingSecurityScopedResource()
        rootURL = url
        path = []
    }

    func closeRoot() {
        if isAccessingRoot, let rootURL {
            rootURL.stopAccessingSecurityScopedResource()
        }
        isAccessingRoot = false
        rootURL = nil
        path = []
    }

    func setSort(_ newValue: MediaSort) {
        guard newValue != sort else { return }
        sort = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.sortKey)
    }
}
