import SwiftUI

enum GroupKind {
    case duplicates
    case similarPhotos
    case similarVideos

    var title: String {
        switch self {
        case .duplicates: return "Duplicates"
        case .similarPhotos: return "Similar Photos"
        case .similarVideos: return "Similar Videos"
        }
    }

    var symbol: String {
        switch self {
        case .duplicates: return "plus.square.on.square"
        case .similarPhotos: return "square.on.square.squareshape.controlhandles"
        case .similarVideos: return "play.square.stack"
        }
    }

    var color: Color {
        switch self {
        case .duplicates: return .orange
        case .similarPhotos: return .teal
        case .similarVideos: return .indigo
        }
    }

    var explanation: String {
        switch self {
        case .duplicates:
            return "These files are exact copies. All but the best copy are marked; tap to change. Nothing is deleted until you confirm."
        case .similarPhotos:
            return "These photos look alike, like bursts and retakes. Tap the ones to delete, or use Keep Best."
        case .similarVideos:
            return "These videos are the same length and look alike. Tap the ones to delete, or use Keep Best."
        }
    }
}

/// Sets of copies or look-alikes. Tap a file to mark it for deletion; at least one in every
/// set always stays. The marked files go to Recently Deleted only after you confirm.
struct GroupReviewScreen: View {
    let kind: GroupKind

    @Environment(AppState.self) private var appState
    @State private var marked: Set<URL> = []
    @State private var hasPreselected = false
    @State private var confirmingDelete = false
    @State private var viewer: ViewerSession?
    @State private var actions = MediaActions()

    private var storage: StorageModel { appState.storage }

    private var groups: [CleanupGroup] {
        switch kind {
        case .duplicates: return storage.duplicates
        case .similarPhotos: return storage.similarPhotos
        case .similarVideos: return storage.similarVideos
        }
    }

    /// Marked files still in a group, in group order.
    private var markedItems: [MediaItem] {
        groups.flatMap(\.items).filter { marked.contains($0.url) }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView("No \(kind.title)", systemImage: kind.symbol, description: Text("Nothing to clean up here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Text(kind.explanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        ForEach(groups) { group in
                            groupCard(group)
                        }
                    }
                    .padding(.vertical)
                }
                .safeAreaInset(edge: .bottom) { deleteBar }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !groups.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Keep Best in Every Set", systemImage: "star") { keepBestEverywhere() }
                        Button("Unmark All", systemImage: "circle") { marked = [] }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .onAppear {
            // Exact copies lose nothing, so they start out marked; look-alikes don't.
            guard !hasPreselected else { return }
            hasPreselected = true
            if kind == .duplicates { keepBestEverywhere() }
        }
        .confirmationDialog(
            "Delete \(MediaActions.count(markedItems.count))?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) { deleteMarked() }
        } message: {
            Text("\(ByteFormat.string(markedItems.reduce(0) { $0 + $1.fileSize })) will be freed when Recently Deleted is emptied. You can restore them until then, for up to 30 days.")
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

    // MARK: - Groups

    private func groupCard(_ group: CleanupGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(itemsAndSize(group.items))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Button("Keep Best") { keepBest(in: group) }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(group.items) { item in
                        tile(item, in: group)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func tile(_ item: MediaItem, in group: CleanupGroup) -> some View {
        let isMarked = marked.contains(item.url)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                toggle(item, in: group)
            } label: {
                ThumbnailView(item: item)
                    .frame(width: 124, height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        if isMarked {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.35))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isMarked ? Color.red : Color.clear, lineWidth: 3)
                    }
                    .overlay(alignment: .topLeading) {
                        if item.url == group.keeper.url {
                            Label("Best", systemImage: "star.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.green, in: Capsule())
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: isMarked ? "trash.circle.fill" : "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isMarked ? Color.red : Color.green)
                            .shadow(radius: 2)
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.name)
            .accessibilityValue(isMarked ? "Will be deleted" : "Kept")
            .contextMenu {
                Button("View", systemImage: "eye") { viewer = ViewerSession(items: group.items, start: item) }
                Button(isMarked ? "Keep" : "Mark for Deletion", systemImage: isMarked ? "checkmark.circle" : "trash") {
                    toggle(item, in: group)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    viewer = ViewerSession(items: group.items, start: item)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .padding(6)
                .accessibilityLabel("View \(item.name)")
            }

            Text(ByteFormat.string(item.fileSize))
                .font(.caption.weight(.medium))
                .monospacedDigit()
            if let detail = detail(for: item) {
                Text(detail)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(item.url.deletingLastPathComponent().lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 124, alignment: .leading)
    }

    /// Resolution, and length for videos.
    private func detail(for item: MediaItem) -> String? {
        guard let facts = storage.facts[item.url], facts.pixelCount > 0 else { return nil }
        let size = "\(facts.pixelWidth)×\(facts.pixelHeight)"
        if let duration = facts.duration { return "\(size) · \(DurationFormat.string(from: duration))" }
        return size
    }

    // MARK: - Marking

    private func toggle(_ item: MediaItem, in group: CleanupGroup) {
        if marked.contains(item.url) {
            marked.remove(item.url)
            return
        }
        var next = marked
        next.insert(item.url)
        guard group.allows(marking: next) else {
            actions.showToast("One file in every set is always kept")
            return
        }
        marked = next
    }

    private func keepBest(in group: CleanupGroup) {
        marked.remove(group.keeper.url)
        for item in group.others { marked.insert(item.url) }
    }

    private func keepBestEverywhere() {
        for group in groups { keepBest(in: group) }
    }

    // MARK: - Deleting

    private var deleteBar: some View {
        let items = markedItems
        return Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            Text(items.isEmpty
                 ? "Tap Files to Mark Them"
                 : "Delete \(MediaActions.count(items.count)) · \(ByteFormat.string(items.reduce(0) { $0 + $1.fileSize }))")
                .font(.headline)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(items.isEmpty || actions.isBusy)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func deleteMarked() {
        guard let root = appState.rootURL else { return }
        // A last check: never every file of a set, even if the lists changed meanwhile.
        let doomed = groups.flatMap { group in
            group.allows(marking: marked) ? group.items.filter { marked.contains($0.url) } : []
        }
        actions.moveToRecentlyDeleted(doomed, root: root) { moved in
            storage.remove(moved)
            marked.subtract(moved.map(\.url))
            appState.driveContentsChanged()
            Task { await storage.refreshRecentlyDeleted(root: root) }
        }
    }
}
