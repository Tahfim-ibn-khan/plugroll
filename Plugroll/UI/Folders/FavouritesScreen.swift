import SwiftUI

/// Every favourite on the drive, in one grid. Works like a folder screen, except the
/// items come from the favourites list rather than from one folder.
struct FavouritesScreen: View {
    @Environment(AppState.self) private var appState
    @State private var items: [MediaItem] = []
    @State private var groups: [MediaGroup] = []
    @State private var hasLoaded = false
    @State private var viewer: ViewerSession?
    @State private var isSelecting = false
    @State private var selection: [MediaItem] = []
    @State private var confirmingDelete = false
    @State private var actions = MediaActions()

    var body: some View {
        Group {
            if !groups.isEmpty {
                FolderGridView(
                    folders: [],
                    groups: groups,
                    isSelecting: isSelecting,
                    reloadToken: appState.reconnectCount,
                    onOpenFolder: { _ in },
                    onOpenItem: { item in
                        viewer = ViewerSession(items: groups.flatMap(\.items), start: item)
                    },
                    onSelectionChange: { selection = $0 },
                    onRefresh: { await load() }
                )
                .ignoresSafeArea()
            } else if hasLoaded {
                ContentUnavailableView {
                    Label("No Favourites", systemImage: "heart")
                } description: {
                    Text("Tap the heart on a photo or video to keep it here.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Favourites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !groups.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Cancel" : "Select") { isSelecting.toggle() }
                        .fontWeight(isSelecting ? .semibold : .regular)
                }
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) { selectionToolbar }
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
                actions.delete(selection) { deleted in
                    remove(deleted)
                    isSelecting = false
                }
            }
        } message: {
            Text("This permanently deletes the files from the drive. It can't be undone.")
        }
        .mediaActionsOverlay(actions)
        .task(id: appState.reconnectCount) { await load() }
        .onChange(of: appState.sort) { _, _ in refreshDisplay() }
        .fullScreenCover(item: $viewer) { session in
            MediaViewer(items: session.items, start: session.start, onDeleted: remove)
                .environment(appState)
        }
    }

    private func load() async {
        items = await Favourites.shared.items()
        hasLoaded = true
        refreshDisplay()
    }

    private func refreshDisplay() {
        groups = appState.sort.groups(for: items)
    }

    /// Drops items that were deleted from the drive, or un-favourited here.
    private func remove(_ removed: [MediaItem]) {
        let gone = Set(removed.map(\.url))
        items.removeAll { gone.contains($0.url) }
        refreshDisplay()
    }

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
            let unfavourited = selection
            Favourites.shared.setFavourite(false, for: unfavourited)
            remove(unfavourited)
            isSelecting = false
        } label: {
            Image(systemName: "heart.slash")
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
}
