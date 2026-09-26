import SwiftUI

struct ViewerSession: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let start: MediaItem
}

enum SearchScope: Hashable {
    case thisFolder
    case allSubfolders
}

struct FolderScreen: View {
    let folder: URL

    @Environment(AppState.self) private var appState
    @State private var listing: FolderListing?
    @State private var errorMessage: String?
    /// Bumped by Try Again to load the folder again.
    @State private var reloadCount = 0

    /// What the grid shows: this folder's contents, or search results, in the chosen orders.
    @State private var displayedFolders: [FolderEntry] = []
    @State private var groups: [MediaGroup] = []

    @State private var query = ""
    @State private var scope: SearchScope = .thisFolder
    /// Matches from walking all subfolders; nil unless that search is active.
    @State private var deepResults: FolderListing?
    @State private var isSearchingDeep = false

    @State private var viewer: ViewerSession?
    @State private var isSelecting = false
    @State private var selection: [MediaItem] = []
    @State private var confirmingDelete = false
    @State private var showingFavourites = false
    @State private var actions = MediaActions()

    /// The drive's own screen, where the Favourites album sits.
    private var isRoot: Bool { folder == appState.rootURL }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFiltering: Bool {
        !trimmedQuery.isEmpty
    }

    var body: some View {
        Group {
            if let listing {
                if isFiltering && displayedFolders.isEmpty && groups.isEmpty {
                    if isSearchingDeep {
                        ProgressView("Searching Subfolders…")
                    } else {
                        ContentUnavailableView.search(text: trimmedQuery)
                    }
                } else if listing.folders.isEmpty && listing.items.isEmpty {
                    ContentUnavailableView("No Photos or Videos", systemImage: "photo.on.rectangle.angled")
                } else {
                    FolderGridView(
                        folders: displayedFolders,
                        groups: groups,
                        isSelecting: isSelecting,
                        reloadToken: appState.reconnectCount,
                        onOpenFolder: { appState.path.append($0) },
                        onOpenItem: { item in
                            viewer = ViewerSession(items: groups.flatMap(\.items), start: item)
                        },
                        onSelectionChange: { selection = $0 },
                        onRefresh: { await refreshListing() },
                        favouritesCount: isRoot && !isFiltering ? Favourites.shared.count : nil,
                        onOpenFavourites: { showingFavourites = true }
                    )
                    .ignoresSafeArea()
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can't Read Folder", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { reloadCount += 1 }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if isSearchingDeep && !(displayedFolders.isEmpty && groups.isEmpty) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching subfolders…")
                        .font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 24)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by Name")
        .searchScopes($scope, activation: .onSearchPresentation) {
            Text("This Folder").tag(SearchScope.thisFolder)
            Text("All Subfolders").tag(SearchScope.allSubfolders)
        }
        .toolbar {
            if let listing, !(listing.items.isEmpty && listing.folders.isEmpty), !isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            if !groups.isEmpty || isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                    }
                    .fontWeight(isSelecting ? .semibold : .regular)
                }
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    selectionToolbar
                }
            }
        }
        .toolbar(isSelecting ? .visible : .automatic, for: .bottomBar)
        .navigationBarBackButtonHidden(isSelecting)
        .confirmationDialog(
            "Delete \(MediaActions.count(selection.count))?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from Drive", role: .destructive) {
                let doomed = selection
                actions.delete(doomed) { deleted in
                    remove(deleted)
                    isSelecting = false
                }
            }
        } message: {
            Text("This permanently deletes the files from the drive. It can't be undone.")
        }
        .mediaActionsOverlay(actions)
        .navigationDestination(isPresented: $showingFavourites) {
            FavouritesScreen().environment(appState)
        }
        .task(id: LoadKey(folder: folder, reload: reloadCount, reconnect: appState.reconnectCount)) {
            // Already showing this folder: a reconnect doesn't need to rescan it.
            if listing != nil, errorMessage == nil, reloadCount == 0 { return }
            do {
                listing = try await FolderScanner.list(folder)
                errorMessage = nil
                refreshDisplay()
            } catch {
                // Keep showing what was already loaded; only an empty screen shows the error.
                if listing == nil { errorMessage = error.localizedDescription }
            }
        }
        .task(id: SearchKey(query: trimmedQuery, scope: scope)) {
            await runDeepSearch()
        }
        .onChange(of: appState.sort) { _, _ in refreshDisplay() }
        .onChange(of: appState.folderSort) { _, _ in refreshDisplay() }
        .onChange(of: query) { _, _ in refreshDisplay() }
        .onChange(of: scope) { _, _ in refreshDisplay() }
        .fullScreenCover(item: $viewer) { session in
            MediaViewer(items: session.items, start: session.start, onDeleted: remove)
                .environment(appState)
        }
    }

    // MARK: - Display

    /// Rebuilds what the grid shows from the listing (or search results), the search
    /// text and both sort orders.
    private func refreshDisplay() {
        let folders: [FolderEntry]
        let items: [MediaItem]
        if isFiltering && scope == .allSubfolders {
            folders = deepResults?.folders ?? []
            items = deepResults?.items ?? []
        } else if isFiltering {
            let text = trimmedQuery
            folders = (listing?.folders ?? []).filter { $0.name.localizedStandardContains(text) }
            items = (listing?.items ?? []).filter { $0.name.localizedStandardContains(text) }
        } else {
            folders = listing?.folders ?? []
            items = listing?.items ?? []
        }
        displayedFolders = appState.folderSort.sorted(folders)
        groups = appState.sort.groups(for: items)
    }

    private struct LoadKey: Equatable {
        let folder: URL
        let reload: Int
        let reconnect: Int
    }

    private struct SearchKey: Equatable {
        let query: String
        let scope: SearchScope
    }

    /// Walks every folder below this one while "All Subfolders" is searched, restarting
    /// (after a short pause for typing) whenever the text or scope changes.
    private func runDeepSearch() async {
        let text = trimmedQuery
        guard scope == .allSubfolders, !text.isEmpty else {
            deepResults = nil
            isSearchingDeep = false
            return
        }

        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        var found = FolderListing(folders: [], items: [])
        deepResults = found
        isSearchingDeep = true
        refreshDisplay()

        for await batch in FolderScanner.search(in: folder, query: text) {
            guard !Task.isCancelled else { break }
            found.folders += batch.folders
            found.items += batch.items
            deepResults = found
            refreshDisplay()
        }

        if !Task.isCancelled {
            isSearchingDeep = false
        }
    }

    /// Pull to refresh: rescans the folder, for files added or changed on the drive
    /// elsewhere. On failure the grid keeps what it had.
    private func refreshListing() async {
        await FolderScanner.resetCovers()
        guard let fresh = try? await FolderScanner.list(folder) else { return }
        listing = fresh
        errorMessage = nil
        refreshDisplay()
    }

    /// Drops deleted files from this screen without rescanning the drive.
    private func remove(_ deleted: [MediaItem]) {
        let gone = Set(deleted.map(\.url))
        listing?.items.removeAll { gone.contains($0.url) }
        deepResults?.items.removeAll { gone.contains($0.url) }
        refreshDisplay()
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var selectionToolbar: some View {
        Button {
            actions.share(selection)
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(selection.isEmpty)

        Spacer()

        Text(selection.isEmpty ? "Select Items" : "\(MediaActions.count(selection.count)) Selected")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()

        Spacer()

        Button {
            Favourites.shared.toggle(selection)
        } label: {
            Image(systemName: Favourites.shared.areAllFavourite(selection) ? "heart.fill" : "heart")
        }
        .disabled(selection.isEmpty)

        Button {
            actions.saveToPhotos(selection)
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .disabled(selection.isEmpty)

        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .disabled(selection.isEmpty)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Photos & Videos", selection: Binding(
                get: { appState.sort },
                set: { appState.setSort($0) }
            )) {
                ForEach(MediaSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)

            Picker("Folders", selection: Binding(
                get: { appState.folderSort },
                set: { appState.setFolderSort($0) }
            )) {
                ForEach(FolderSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}
