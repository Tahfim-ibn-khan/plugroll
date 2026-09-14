import Observation
import Photos
import SwiftUI

/// Runs Share, Save to Photos and Delete for a screen, and publishes progress and
/// results for `mediaActionsOverlay` to show. Each screen owns its own instance.
@MainActor
@Observable
final class MediaActions {
    struct Progress: Equatable {
        let title: String
        var completed: Int
        let total: Int
    }

    struct Failure: Equatable {
        let title: String
        let message: String
    }

    private(set) var progress: Progress?
    private(set) var toast: String?
    var failure: Failure?

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    var isBusy: Bool { progress != nil }

    func cancel() {
        work?.cancel()
    }

    func share(_ items: [MediaItem]) {
        guard !items.isEmpty, !isBusy else { return }
        progress = Progress(title: "Preparing to Share", completed: 0, total: items.count)

        work = Task {
            var batch: URL?
            do {
                let directory = try ExportService.makeBatchDirectory()
                batch = directory
                var urls: [URL] = []
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    urls.append(try await ExportService.stageCopy(of: item, index: index, in: directory))
                    progress?.completed = index + 1
                }
                try Task.checkCancellation()
                progress = nil
                ExportService.presentShareSheet(for: urls) {
                    ExportService.remove(directory)
                }
            } catch {
                progress = nil
                if let batch { ExportService.remove(batch) }
                if !(error is CancellationError) {
                    failure = Failure(title: "Couldn't Share", message: error.localizedDescription)
                }
            }
        }
    }

    func saveToPhotos(_ items: [MediaItem]) {
        guard !items.isEmpty, !isBusy else { return }

        work = Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                failure = Failure(
                    title: "No Access to Photos",
                    message: "Allow vimage to add photos in Settings → Apps → vimage → Photos."
                )
                return
            }

            progress = Progress(title: "Saving to Photos", completed: 0, total: items.count)
            var saved = 0
            var failed = 0
            var lastError: Error?

            do {
                let batch = try ExportService.makeBatchDirectory()
                // One file at a time: copy, then move into Photos, so big videos
                // never sit on the phone twice. Cancelled items count as neither.
                for (index, item) in items.enumerated() {
                    if Task.isCancelled { break }
                    do {
                        let copy = try await ExportService.stageCopy(of: item, index: index, in: batch)
                        try await ExportService.addToPhotoLibrary(copy, item: item)
                        saved += 1
                    } catch {
                        failed += 1
                        lastError = error
                    }
                    progress?.completed = index + 1
                }
                ExportService.remove(batch)
            } catch {
                failed = items.count
                lastError = error
            }

            progress = nil
            if failed > 0, let lastError {
                failure = Failure(
                    title: saved > 0 ? "Saved \(Self.count(saved))" : "Couldn't Save",
                    message: "\(Self.count(failed)) couldn't be saved. \(lastError.localizedDescription)"
                )
            } else if saved > 0 {
                showToast("Saved \(Self.count(saved)) to Photos")
            }
        }
    }

    func delete(_ items: [MediaItem], onDeleted: @escaping ([MediaItem]) -> Void) {
        guard !items.isEmpty, !isBusy else { return }
        progress = Progress(title: "Deleting", completed: 0, total: items.count)

        work = Task {
            var deleted: [MediaItem] = []
            var failed = 0
            var lastError: Error?
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                do {
                    try await ExportService.deleteFile(item)
                    deleted.append(item)
                } catch {
                    failed += 1
                    lastError = error
                }
                progress?.completed = index + 1
            }

            progress = nil
            if !deleted.isEmpty { onDeleted(deleted) }
            if let lastError {
                failure = Failure(
                    title: "Couldn't Delete",
                    message: "\(Self.count(failed)) couldn't be deleted. The drive may be read-only (for example NTFS). \(lastError.localizedDescription)"
                )
            } else if !deleted.isEmpty {
                showToast("Deleted \(Self.count(deleted.count))")
            }
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    static func count(_ n: Int) -> String {
        n == 1 ? "1 item" : "\(n) items"
    }
}

private struct MediaActionsOverlay: ViewModifier {
    let actions: MediaActions

    func body(content: Content) -> some View {
        content
            .overlay {
                if let progress = actions.progress {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 14) {
                            Text(progress.title)
                                .font(.headline)
                            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                            Text("\(min(progress.completed + 1, progress.total)) of \(progress.total)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("Cancel", role: .cancel) { actions.cancel() }
                                .buttonStyle(.bordered)
                        }
                        .padding(22)
                        .frame(maxWidth: 280)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = actions.toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 90)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: actions.progress)
            .animation(.spring(duration: 0.3), value: actions.toast)
            .alert(
                actions.failure?.title ?? "",
                isPresented: Binding(
                    get: { actions.failure != nil },
                    set: { if !$0 { actions.failure = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.failure?.message ?? "")
            }
    }
}

extension View {
    func mediaActionsOverlay(_ actions: MediaActions) -> some View {
        modifier(MediaActionsOverlay(actions: actions))
    }
}
