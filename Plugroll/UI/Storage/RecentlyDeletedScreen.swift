import SwiftUI

/// Files moved to Recently Deleted by the storage screens. Restore puts them back where
/// they were; Delete and Empty remove them from the drive for good.
struct RecentlyDeletedScreen: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [DeletedEntry] = []
    @State private var hasLoaded = false
    @State private var isSelecting = false
    @State private var selection: Set<URL> = []
    @State private var confirmingDelete = false
    @State private var confirmingEmpty = false
    @State private var isWorking = false
    @State private var viewer: ViewerSession?
    @State private var actions = MediaActions()

    /// Each entry with the file as it sits in Recently Deleted.
    private var rows: [(entry: DeletedEntry, item: MediaItem)] {
        guard let root = appState.rootURL else { return [] }
        return entries.compactMap { entry in RecentlyDeleted.item(for: entry, root: root).map { (entry, $0) } }
    }

    private var selectedEntries: [DeletedEntry] {
        rows.filter { selection.contains($0.item.url) }.map(\.entry)
    }

    var body: some View {
        Group {
            if !rows.isEmpty {
                let lookup = Dictionary(uniqueKeysWithValues: rows.map { ($0.item.url, $0.entry) })
                SelectableGrid(
                    items: rows.map(\.item),
                    isSelecting: isSelecting,
                    selection: $selection,
                    badge: { item in lookup[item.url].map { daysLabel($0.daysLeft()) } },
                    onOpen: { viewer = ViewerSession(items: rows.map(\.item), start: $0) }
                )
            } else if hasLoaded {
                ContentUnavailableView(
                    "No Recently Deleted Items",
                    systemImage: "trash",
                    description: Text("Files you delete from the Storage screens wait here for 30 days.")
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !rows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selection = [] }
                    }
                    .fontWeight(isSelecting ? .semibold : .regular)
                }
            }
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    let allSelected = selection.count == rows.count
                    Button(allSelected ? "Deselect All" : "Select All") {
                        selection = allSelected ? [] : Set(rows.map(\.item.url))
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Restore") { restore(selectedEntries) }
                        .disabled(selectedEntries.isEmpty)
                    Spacer()
                    Text(selectedEntries.isEmpty ? "Select Items" : "\(MediaActions.count(selectedEntries.count)) Selected")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .disabled(selectedEntries.isEmpty)
                }
            } else if !rows.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Restore All") { restore(entries) }
                    Spacer()
                    Text(ByteFormat.string(entries.reduce(0) { $0 + $1.fileSize }))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Spacer()
                    Button("Empty", role: .destructive) { confirmingEmpty = true }
                }
            }
        }
        .toolbar(rows.isEmpty ? .automatic : .visible, for: .bottomBar)
        .navigationBarBackButtonHidden(isSelecting)
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView().controlSize(.large) } }
        .confirmationDialog(
            "Delete \(MediaActions.count(selectedEntries.count)) for Good?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from Drive", role: .destructive) { deletePermanently(selectedEntries) }
        } message: {
            Text("This permanently deletes the files from the drive. It can't be undone.")
        }
        .confirmationDialog("Empty Recently Deleted?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Delete \(MediaActions.count(entries.count))", role: .destructive) { deletePermanently(entries) }
        } message: {
            Text("This permanently deletes every file here from the drive, freeing \(ByteFormat.string(entries.reduce(0) { $0 + $1.fileSize })). It can't be undone.")
        }
        .mediaActionsOverlay(actions)
        .fullScreenCover(item: $viewer) { session in
            MediaViewer(
                items: session.items,
                start: session.start,
                onDeleted: { _ in Task { await load() } },
                onEdited: { Task { await load() } }
            )
            .environment(appState)
        }
        .task(id: appState.reconnectCount) { await load() }
    }

    private func daysLabel(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    private func load() async {
        guard let root = appState.rootURL else { return }
        entries = (try? await RecentlyDeleted.entries(root: root)) ?? entries
        hasLoaded = true
        let present = Set(rows.map(\.item.url))
        selection.formIntersection(present)
    }

    private func restore(_ chosen: [DeletedEntry]) {
        guard let root = appState.rootURL, !chosen.isEmpty else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let restored = try await RecentlyDeleted.restore(chosen, root: root)
                for item in restored { appState.storage.add(item) }
                actions.showToast("Restored \(MediaActions.count(restored.count))")
            } catch {
                actions.failure = .init(title: "Couldn't Restore", message: error.localizedDescription)
            }
            await finishChange(root: root)
        }
    }

    private func deletePermanently(_ chosen: [DeletedEntry]) {
        guard let root = appState.rootURL, !chosen.isEmpty else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await RecentlyDeleted.deletePermanently(chosen, root: root)
                // Gone for good, so they leave the favourites too.
                let originals = chosen.compactMap { entry -> MediaItem? in
                    let url = RecentlyDeleted.originalURL(for: entry, root: root)
                    return MediaKind(url: url).map { MediaItem(url: url, kind: $0, modified: entry.modified, fileSize: entry.fileSize) }
                }
                Favourites.shared.setFavourite(false, for: originals)
                actions.showToast("Deleted \(MediaActions.count(chosen.count))")
            } catch {
                actions.failure = .init(title: "Couldn't Delete", message: error.localizedDescription)
            }
            await finishChange(root: root)
        }
    }

    private func finishChange(root: URL) async {
        isSelecting = false
        selection = []
        await load()
        await appState.storage.refreshRecentlyDeleted(root: root)
        appState.driveContentsChanged()
    }
}
