import SwiftUI

/// Videos of 500 MB or more, biggest first, with Trim and Compress to shrink them.
struct BigVideosScreen: View {
    @Environment(AppState.self) private var appState
    @State private var editing: MediaItem?
    @State private var compressing: MediaItem?
    @State private var deleting: MediaItem?
    @State private var viewer: ViewerSession?
    @State private var actions = MediaActions()

    private var storage: StorageModel { appState.storage }

    var body: some View {
        Group {
            if storage.bigVideos.isEmpty {
                ContentUnavailableView(
                    "No Big Videos",
                    systemImage: "film.stack",
                    description: Text("No video on the drive is \(ByteFormat.string(CleanupFinder.bigVideoBytes)) or more.")
                )
            } else {
                List {
                    Section {
                        ForEach(storage.bigVideos) { item in
                            row(item)
                        }
                    } footer: {
                        Text("Trim cuts away the parts you don't want without losing quality. Compress makes the whole video smaller. Either way, the original waits in Recently Deleted if you replace it.")
                    }
                }
            }
        }
        .navigationTitle("Big Videos")
        .navigationBarTitleDisplayMode(.inline)
        .mediaActionsOverlay(actions)
        .fullScreenCover(item: $editing) { item in
            MediaEditor(
                item: item,
                replaceOptions: .init(recentlyDeletedRoot: appState.rootURL, keepsDate: true)
            ) { result in
                apply(result, to: item)
            }
        }
        .sheet(item: $compressing) { item in
            CompressSheet(item: item) { result in
                apply(result, to: item)
            }
            .environment(appState)
        }
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
        .confirmationDialog(
            "Delete This Video?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { item in
            Button("Move to Recently Deleted", role: .destructive) { delete(item) }
        } message: { item in
            Text("\(ByteFormat.string(item.fileSize)). You can restore it from Recently Deleted for 30 days.")
        }
    }

    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            Button {
                viewer = ViewerSession(items: storage.bigVideos, start: item)
            } label: {
                HStack(spacing: 12) {
                    ThumbnailView(item: item)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(item.url.deletingLastPathComponent().lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        VideoSizeLine(item: item)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            VStack(spacing: 6) {
                Button("Trim") { editing = item }
                Button("Compress") { compressing = item }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
        }
    }

    /// Updates the lists after a trim or compression was saved.
    private func apply(_ result: EditResult, to original: MediaItem) {
        switch result {
        case .replaced(let new):
            storage.replace(original, with: new)
            let saved = original.fileSize - new.fileSize
            if saved > 0 {
                actions.showToast("Now \(ByteFormat.string(new.fileSize)), \(ByteFormat.string(saved)) smaller")
            }
        case .copy(let new):
            storage.add(new)
            actions.showToast("Saved a copy of \(ByteFormat.string(new.fileSize))")
        case .photos:
            actions.showToast("Saved to Photos")
        }
        appState.driveContentsChanged()
        if let root = appState.rootURL {
            Task { await storage.refreshRecentlyDeleted(root: root) }
        }
    }

    private func delete(_ item: MediaItem) {
        guard let root = appState.rootURL else { return }
        actions.moveToRecentlyDeleted([item], root: root) { moved in
            storage.remove(moved)
            appState.driveContentsChanged()
            Task { await storage.refreshRecentlyDeleted(root: root) }
        }
    }
}

/// "2.4 GB · 12:05"
private struct VideoSizeLine: View {
    let item: MediaItem
    @State private var duration: Double?

    var body: some View {
        Text(duration.map { "\(ByteFormat.string(item.fileSize)) · \(DurationFormat.string(from: $0))" }
             ?? ByteFormat.string(item.fileSize))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .task(id: item.cacheKey) {
                duration = VideoDurationService.shared.cachedDuration(for: item)
                if duration == nil { duration = await VideoDurationService.shared.duration(for: item) }
            }
    }
}
