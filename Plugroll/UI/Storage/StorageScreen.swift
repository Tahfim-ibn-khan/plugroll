import SwiftUI

/// How full the drive is, and the ways to free up room on it.
struct StorageScreen: View {
    @Environment(AppState.self) private var appState

    private var storage: StorageModel { appState.storage }

    var body: some View {
        List {
            Section {
                StorageBar(space: appState.driveSpace, recentlyDeletedBytes: storage.recentlyDeletedBytes)
            }

            Section {
                scanRow
            } footer: {
                Text("The scan looks through every photo and video on the drive. The first one takes a while on a big drive; after that only new files are looked at.")
            }

            Section("Clean Up") {
                groupRow(.duplicates, groups: storage.duplicates)
                groupRow(.similarPhotos, groups: storage.similarPhotos)
                groupRow(.similarVideos, groups: storage.similarVideos)
                listRow(.screenshots, items: storage.screenshots, needsAnalysis: true)
                listRow(.blurry, items: storage.blurry + storage.dark, needsAnalysis: true)
            }

            Section("Big Files") {
                NavigationLink {
                    BigVideosScreen()
                } label: {
                    row(
                        title: "Big Videos",
                        symbol: "film.stack",
                        color: .purple,
                        detail: storage.hasIndex ? itemsAndSize(storage.bigVideos) : nil
                    )
                }
                .disabled(!storage.hasIndex)

                listRow(.largest, items: storage.largest, needsAnalysis: false)

                NavigationLink {
                    FolderSizesScreen()
                } label: {
                    row(
                        title: "Folders by Size",
                        symbol: "folder",
                        color: .blue,
                        detail: storage.hasIndex ? "\(storage.folderSizes.count) folders" : nil
                    )
                }
                .disabled(!storage.hasIndex)
            }

            Section {
                NavigationLink {
                    RecentlyDeletedScreen()
                } label: {
                    row(
                        title: "Recently Deleted",
                        symbol: "trash",
                        color: .gray,
                        detail: "\(MediaActions.count(storage.recentlyDeletedCount)) · \(ByteFormat.string(storage.recentlyDeletedBytes))"
                    )
                }
            } footer: {
                Text("Files deleted here wait in Recently Deleted for 30 days, then go for good. Their space comes back once they're gone.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            appState.refreshSpace()
            if let root = appState.rootURL { await storage.refreshRecentlyDeleted(root: root) }
        }
        .task {
            appState.refreshSpace()
            if let root = appState.rootURL { await storage.refreshRecentlyDeleted(root: root) }
        }
    }

    // MARK: - Scan

    @ViewBuilder
    private var scanRow: some View {
        switch storage.phase {
        case .indexing, .hashing, .analyzing, .grouping:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(progressTitle).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Stop", role: .cancel) { storage.cancel() }
                        .buttonStyle(.borderless)
                }
                if let fraction = progressFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(progressDetail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .idle, .finished, .failed:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if let root = appState.rootURL { storage.scan(root: root) }
                } label: {
                    Label(storage.hasIndex ? "Scan Again" : "Scan Drive", systemImage: "magnifyingglass")
                }
                .disabled(!appState.isDriveConnected)
                if case .failed(let message) = storage.phase {
                    Text("The scan stopped: \(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let lastScan = storage.lastScan {
                    Text(storage.hasAnalysis
                         ? "Last scanned \(lastScan.formatted(.relative(presentation: .named)))"
                         : "Stopped early. Scan again to find copies and look-alikes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var progressTitle: String {
        switch storage.phase {
        case .indexing: return "Finding photos and videos"
        case .hashing: return "Checking for exact copies"
        case .analyzing: return "Looking for look-alikes"
        default: return "Sorting results"
        }
    }

    private var progressDetail: String {
        switch storage.phase {
        case .indexing(let found): return "\(found.formatted()) found so far"
        case .hashing(let done, let total), .analyzing(let done, let total):
            return "\(done.formatted()) of \(total.formatted())"
        default: return "Almost done"
        }
    }

    private var progressFraction: Double? {
        switch storage.phase {
        case .hashing(let done, let total), .analyzing(let done, let total):
            return total > 0 ? Double(done) / Double(total) : 1
        default: return nil
        }
    }

    // MARK: - Rows

    private func groupRow(_ kind: GroupKind, groups: [CleanupGroup]) -> some View {
        NavigationLink {
            GroupReviewScreen(kind: kind)
        } label: {
            row(
                title: kind.title,
                symbol: kind.symbol,
                color: kind.color,
                detail: storage.hasAnalysis
                    ? (groups.isEmpty ? "None" : "\(groups.count) sets · \(ByteFormat.string(groups.reduce(0) { $0 + $1.reclaimableBytes })) to free")
                    : nil
            )
        }
        .disabled(!storage.hasAnalysis)
    }

    private func listRow(_ kind: CleanupListKind, items: [MediaItem], needsAnalysis: Bool) -> some View {
        let ready = needsAnalysis ? storage.hasAnalysis : storage.hasIndex
        return NavigationLink {
            CleanupGridScreen(kind: kind)
        } label: {
            row(
                title: kind.title,
                symbol: kind.symbol,
                color: kind.color,
                detail: ready ? (items.isEmpty ? "None" : itemsAndSize(items)) : nil
            )
        }
        .disabled(!ready)
    }

    /// A Settings-style row. No detail means the scan hasn't found it out yet.
    private func row(title: String, symbol: String, color: Color, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer()
            Text(detail ?? "Scan to find")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
