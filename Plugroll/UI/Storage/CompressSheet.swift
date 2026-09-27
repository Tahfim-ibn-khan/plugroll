import Observation
import SwiftUI

/// Picks a compression setting for one video, shows roughly what it will come to, and
/// saves the result as a copy or in place of the original.
struct CompressSheet: View {
    let item: MediaItem
    let onSaved: (EditResult) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model = CompressModel()
    @State private var level: CompressionLevel = .medium
    @State private var replaces = true

    private var canReplace: Bool { EditExporter.canReplaceOriginal(item) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Now", value: ByteFormat.string(item.fileSize))
                } header: {
                    Text(item.name)
                }

                Section("Quality") {
                    ForEach(CompressionLevel.allCases) { option in
                        Button {
                            level = option
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(.primary)
                                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let estimate = model.estimates[option] {
                                    Text("about \(ByteFormat.string(estimate))")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(level == option ? 1 : 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Picker("Save", selection: $replaces) {
                        if canReplace { Text("Replace Original").tag(true) }
                        Text("Save as Copy").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Save")
                } footer: {
                    Text(replaces && canReplace
                         ? "The original moves to Recently Deleted, where you can restore it for 30 days. The space is freed once it's gone from there."
                         : "The compressed video is saved next to the original, which stays as it is.")
                }
            }
            .navigationTitle("Compress Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Compress") { start() }
                        .fontWeight(.semibold)
                        .disabled(model.isWorking || !appState.isDriveConnected)
                }
            }
            .overlay { if model.isWorking { progressOverlay } }
            .interactiveDismissDisabled(model.isWorking)
            .alert(
                "Couldn't Compress",
                isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.failure ?? "")
            }
        }
        .onAppear { if !canReplace { replaces = false } }
        .task { await model.loadEstimates(for: item) }
        .onDisappear { model.cancel() }
    }

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Compressing").font(.headline)
                ProgressView(value: model.progress)
                Text("\(Int((model.progress * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { model.cancel() }
                    .buttonStyle(.bordered)
            }
            .padding(22)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func start() {
        let options = EditExporter.ReplaceOptions(recentlyDeletedRoot: appState.rootURL, keepsDate: true)
        model.compress(item, level: level, to: replaces && canReplace ? .replaceOriginal : .copyOnDrive, options: options) { result in
            onSaved(result)
            dismiss()
        }
    }
}

@MainActor
@Observable
final class CompressModel {
    private(set) var estimates: [CompressionLevel: Int64] = [:]
    private(set) var isWorking = false
    private(set) var progress: Double = 0
    var failure: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func loadEstimates(for item: MediaItem) async {
        for level in CompressionLevel.allCases {
            if let bytes = await VideoCompressor.estimatedSize(of: item, level: level) {
                estimates[level] = bytes
            }
        }
    }

    func compress(
        _ item: MediaItem,
        level: CompressionLevel,
        to destination: EditDestination,
        options: EditExporter.ReplaceOptions,
        completion: @escaping (EditResult) -> Void
    ) {
        guard !isWorking else { return }
        isWorking = true
        progress = 0
        task = Task {
            defer { isWorking = false }
            do {
                let batch = try ExportService.makeBatchDirectory()
                defer { ExportService.remove(batch) }
                let output = try await VideoCompressor.compress(item, level: level, in: batch) { fraction in
                    Task { @MainActor [weak self] in self?.progress = fraction }
                }
                try Task.checkCancellation()
                let result = try await EditExporter.save(output, for: item, to: destination, options: options)
                completion(result)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                failure = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
