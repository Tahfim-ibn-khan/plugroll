import SwiftUI

struct ViewerSession: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let start: MediaItem
}

struct FolderScreen: View {
    let folder: URL

    @Environment(AppState.self) private var appState
    @State private var listing: FolderListing?
    @State private var groups: [MediaGroup] = []
    @State private var errorMessage: String?
    @State private var viewer: ViewerSession?
    @State private var isSelecting = false
    @State private var selection: [MediaItem] = []
    @State private var confirmingDelete = false
    @State private var actions = MediaActions()

    var body: some View {
        Group {
            if let listing {
                if listing.folders.isEmpty && listing.items.isEmpty {
                    ContentUnavailableView("No Photos or Videos", systemImage: "photo.on.rectangle.angled")
                } else {
                    FolderGridView(
                        folders: listing.folders,
                        groups: groups,
                        isSelecting: isSelecting,
                        onOpenFolder: { appState.path.append($0) },
                        onOpenItem: { item in
                            viewer = ViewerSession(items: groups.flatMap(\.items), start: item)
                        },
                        onSelectionChange: { selection = $0 }
                    )
                    .ignoresSafeArea()
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Can't Read Folder",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let listing, !listing.items.isEmpty {
                if !isSelecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        sortMenu
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                    }
                    .fontWeight(isSelecting ? .semibold : .regular)
                }
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
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
        .task(id: folder) {
            do {
                let loaded = try await FolderScanner.list(folder)
                listing = loaded
                groups = appState.sort.groups(for: loaded.items)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: appState.sort) { _, newSort in
            groups = newSort.groups(for: listing?.items ?? [])
        }
        .fullScreenCover(item: $viewer) { session in
            MediaViewer(items: session.items, start: session.start, onDeleted: remove)
        }
    }

    /// Drops deleted files from this screen without rescanning the drive.
    private func remove(_ deleted: [MediaItem]) {
        let gone = Set(deleted.map(\.url))
        listing?.items.removeAll { gone.contains($0.url) }
        groups = appState.sort.groups(for: listing?.items ?? [])
    }

    private var sortMenu: some View {
        Menu {
            ForEach(MediaSort.allCases) { option in
                Button {
                    appState.setSort(option)
                } label: {
                    if option == appState.sort {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}
