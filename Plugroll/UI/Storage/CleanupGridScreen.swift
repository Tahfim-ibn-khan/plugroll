import SwiftUI

enum CleanupListKind {
    case largest
    case screenshots
    case blurry

    var title: String {
        switch self {
        case .largest: return "Largest Files"
        case .screenshots: return "Screenshots"
        case .blurry: return "Blurry & Dark"
        }
    }

    var symbol: String {
        switch self {
        case .largest: return "arrow.up.right.square"
        case .screenshots: return "camera.viewfinder"
        case .blurry: return "camera.aperture"
        }
    }

    var color: Color {
        switch self {
        case .largest: return .pink
        case .screenshots: return .cyan
        case .blurry: return .brown
        }
    }
}

/// One of the single-file cleanup lists. Select files, then move them to Recently Deleted.
struct CleanupGridScreen: View {
    let kind: CleanupListKind

    private enum BlurFilter: Hashable {
        case blurry, dark
    }

    @Environment(AppState.self) private var appState
    @State private var isSelecting = false
    @State private var selection: Set<URL> = []
    @State private var blurFilter: BlurFilter = .blurry
    @State private var confirmingDelete = false
    @State private var viewer: ViewerSession?
    @State private var actions = MediaActions()

    private var storage: StorageModel { appState.storage }

    private var items: [MediaItem] {
        switch kind {
        case .largest: return storage.largest
        case .screenshots: return storage.screenshots
        case .blurry: return blurFilter == .blurry ? storage.blurry : storage.dark
        }
    }

    private var selectedItems: [MediaItem] {
        items.filter { selection.contains($0.url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if kind == .blurry {
                Picker("Show", selection: $blurFilter) {
                    Text("Blurry (\(storage.blurry.count))").tag(BlurFilter.blurry)
                    Text("Dark (\(storage.dark.count))").tag(BlurFilter.dark)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if items.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: kind.symbol, description: Text("Nothing to clean up in this list."))
                    .frame(maxHeight: .infinity)
            } else {
                SelectableGrid(
                    items: items,
                    isSelecting: isSelecting,
                    selection: $selection,
                    badge: { kind == .largest ? ByteFormat.string($0.fileSize) : nil },
                    onOpen: { viewer = ViewerSession(items: items, start: $0) }
                )
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: blurFilter) { _, _ in selection = [] }
        .toolbar {
            if !items.isEmpty {
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
                    let allSelected = selection.count == items.count
                    Button(allSelected ? "Deselect All" : "Select All") {
                        selection = allSelected ? [] : Set(items.map(\.url))
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Text(selectedItems.isEmpty ? "Select Items" : itemsAndSize(selectedItems))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Spacer()
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedItems.isEmpty)
                }
            }
        }
        .toolbar(isSelecting ? .visible : .automatic, for: .bottomBar)
        .navigationBarBackButtonHidden(isSelecting)
        .confirmationDialog(
            "Delete \(MediaActions.count(selectedItems.count))?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) { deleteSelected() }
        } message: {
            Text("You can restore them from Recently Deleted for 30 days.")
        }
        .mediaActionsOverlay(actions)
        .fullScreenCover(item: $viewer) { session in
            MediaViewer(
                items: session.items,
                start: session.start,
                onDeleted: { deleted in
                    storage.remove(deleted)
                    appState.driveContentsChanged()
                },
                onEdited: { appState.driveContentsChanged() }
            )
            .environment(appState)
        }
    }

    private func deleteSelected() {
        guard let root = appState.rootURL else { return }
        actions.moveToRecentlyDeleted(selectedItems, root: root) { moved in
            storage.remove(moved)
            selection.subtract(moved.map(\.url))
            isSelecting = false
            appState.driveContentsChanged()
            Task { await storage.refreshRecentlyDeleted(root: root) }
        }
    }
}
