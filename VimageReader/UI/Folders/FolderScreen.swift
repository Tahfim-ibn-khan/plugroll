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

    var body: some View {
        Group {
            if let listing {
                if listing.folders.isEmpty && listing.items.isEmpty {
                    ContentUnavailableView("No Photos or Videos", systemImage: "photo.on.rectangle.angled")
                } else {
                    FolderGridView(
                        folders: listing.folders,
                        groups: groups,
                        onOpenFolder: { appState.path.append($0) },
                        onOpenItem: { item in
                            viewer = ViewerSession(items: groups.flatMap(\.items), start: item)
                        }
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
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
        }
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
            MediaViewer(items: session.items, start: session.start)
        }
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
