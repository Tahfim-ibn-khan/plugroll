import AVFoundation
import SwiftUI

/// Photos-style editor for one photo or video: crop and straighten, light and colour,
/// filters, and for videos trim and mute. Asks where to save when you tap Done.
struct MediaEditor: View {
    let onSaved: (EditResult) -> Void

    @State private var model: EditorModel
    @State private var choosingDestination = false
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(item: MediaItem, onSaved: @escaping (EditResult) -> Void) {
        self.init(model: EditorModel(item: item), onSaved: onSaved)
    }

    /// With a model set up beforehand (a chosen tool or edits), for previews and tests.
    init(model: EditorModel, onSaved: @escaping (EditResult) -> Void = { _ in }) {
        self.onSaved = onSaved
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            previewArea
            panel
                .frame(height: 150)
            modePicker
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .task { await model.load() }
        // Redraws after every change, dropping stale frames while a slider moves.
        .task(id: PreviewKey(edits: model.edits, cropping: model.mode == .crop, loaded: model.isLoaded)) {
            guard model.isLoaded else { return }
            await model.refresh()
        }
        .task(id: FilterKey(edits: model.mode == .filters ? model.edits : nil, loaded: model.isLoaded)) {
            guard model.mode == .filters, model.isLoaded else { return }
            await model.renderFilterThumbnails()
        }
        .onDisappear { model.tearDown() }
        .confirmationDialog("Save Edit", isPresented: $choosingDestination, titleVisibility: .visible) {
            Button("Save as Copy on Drive") { save(.copyOnDrive) }
            if model.canReplaceOriginal {
                Button("Replace Original", role: .destructive) { save(.replaceOriginal) }
            }
            Button("Save to Photos") { save(.photos) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.canReplaceOriginal
                 ? "A copy keeps the original as it is. Replacing it can't be undone."
                 : "This format can't be written back, so the original stays as it is.")
        }
        .confirmationDialog("Discard Changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert(
            "Couldn't Save",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
        .overlay { if model.isSaving { savingOverlay } }
    }

    private struct FilterKey: Equatable {
        let edits: Edits?
        let loaded: Bool
    }

    private struct PreviewKey: Equatable {
        let edits: Edits
        let cropping: Bool
        let loaded: Bool
    }

    private func save(_ destination: EditDestination) {
        model.save(to: destination) { result in
            onSaved(result)
            dismiss()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") {
                if model.hasChanges { confirmingDiscard = true } else { dismiss() }
            }
            Spacer()
            if model.hasChanges {
                Button("Revert") { withAnimation { model.revert() } }
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Done") {
                if model.hasChanges { choosingDestination = true } else { dismiss() }
            }
            .fontWeight(.semibold)
            .foregroundStyle(model.hasChanges ? Color.yellow : Color.white)
        }
        .font(.body)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 50)
        .disabled(model.isSaving)
    }

    // MARK: - Preview

    private var previewArea: some View {
        GeometryReader { geometry in
            let fitted = Self.fit(model.previewSize, in: geometry.size.insetBy(28))
            ZStack {
                if let error = model.loadError {
                    ContentUnavailableView("Can't Edit", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if !model.isLoaded {
                    ProgressView()
                } else {
                    Group {
                        if let player = model.player {
                            PlayerLayerView(player: player)
                        } else if let preview = model.preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .interpolation(.high)
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .overlay {
                        if model.mode == .crop {
                            CropOverlay(crop: $model.edits.crop, ratio: model.cropRatio, size: fitted)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture {
                if model.isVideo && model.mode != .crop { model.togglePlayback() }
            }
        }
    }

    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    // MARK: - Panels

    @ViewBuilder
    private var panel: some View {
        if model.isLoaded && model.loadError == nil {
            switch model.mode {
            case .trim: trimPanel
            case .adjust: adjustPanel
            case .filters: filterPanel
            case .crop: cropPanel
            }
        } else {
            Color.clear
        }
    }

    private var trimPanel: some View {
        VStack(spacing: 14) {
            TrimBar(
                frames: model.filmstrip,
                duration: model.duration,
                start: $model.edits.trimStart,
                end: $model.edits.trimEnd,
                playhead: model.currentTime,
                onSeek: { model.seek(to: $0) }
            )
            .padding(.horizontal, 16)

            HStack(spacing: 28) {
                Text(DurationFormat.string(from: model.trimEnd - model.edits.trimStart))
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                Button {
                    model.edits.muted.toggle()
                } label: {
                    Image(systemName: model.edits.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(model.edits.muted ? Color.yellow : Color.white)
                        .frame(width: 60, height: 44)
                }
                .accessibilityLabel(model.edits.muted ? "Sound Off" : "Sound On")
            }
        }
    }

    private var adjustPanel: some View {
        VStack(spacing: 12) {
            let adjustment = model.selectedAdjustment
            HStack {
                Text(model.edits.autoEnhance && !model.isVideo ? "\(adjustment.title) · Auto" : adjustment.title)
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text("\(Int((model.edits.value(adjustment) * 100).rounded()))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            Slider(
                value: Binding(
                    get: { model.edits.value(adjustment) },
                    set: { model.edits.set(adjustment, to: $0) }
                ),
                in: adjustment.range
            )
            .tint(.yellow)
            .padding(.horizontal, 24)

            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    if !model.isVideo {
                        adjustmentButton(
                            symbol: "wand.and.stars",
                            label: "Auto",
                            isSelected: model.edits.autoEnhance,
                            ring: model.edits.autoEnhance ? 1 : 0
                        ) {
                            model.toggleAuto()
                        }
                    }
                    ForEach(Adjustment.allCases) { item in
                        let value = model.edits.value(item)
                        adjustmentButton(
                            symbol: item.symbol,
                            label: item.title,
                            isSelected: item == model.selectedAdjustment,
                            ring: abs(value) / max(abs(item.range.lowerBound), item.range.upperBound)
                        ) {
                            model.selectedAdjustment = item
                        }
                        // Double-tap puts one slider back to zero.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.edits.set(item, to: 0) })
                        .id(item)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(model.selectedAdjustment, anchor: .center) }
            .onChange(of: model.selectedAdjustment) { _, selected in
                withAnimation { proxy.scrollTo(selected, anchor: .center) }
            }
            }
        }
    }

    /// A round button whose outline fills up as the value moves away from zero.
    private func adjustmentButton(
        symbol: String,
        label: String,
        isSelected: Bool,
        ring: Double,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Color.yellow : Color.white)
            }
            .frame(width: 46, height: 46)
            .background(isSelected ? Color.white.opacity(0.12) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var filterPanel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(FilterPreset.allCases) { preset in
                    Button {
                        model.edits.filter = preset
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let thumbnail = model.filterThumbnails[preset] {
                                    Image(decorative: thumbnail, scale: 1)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Color.white.opacity(0.1)
                                }
                            }
                            .frame(width: 70, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.yellow, lineWidth: model.edits.filter == preset ? 2.5 : 0)
                            }
                            Text(preset.title)
                                .font(.caption2.weight(model.edits.filter == preset ? .semibold : .regular))
                                .foregroundStyle(model.edits.filter == preset ? Color.yellow : Color.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var cropPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 28) {
                Button { model.rotate() } label: {
                    Image(systemName: "rotate.left").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Rotate")

                Button { model.flip() } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.title3)
                        .foregroundStyle(model.edits.flipped ? Color.yellow : Color.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Flip")

                Menu {
                    Picker("Aspect Ratio", selection: Binding(
                        get: { model.edits.aspect },
                        set: { model.setAspect($0) }
                    )) {
                        ForEach(AspectPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                } label: {
                    Image(systemName: "aspectratio")
                        .font(.title3)
                        .foregroundStyle(model.edits.aspect == .freeform ? Color.white : Color.yellow)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Aspect Ratio")

                Button("Reset") { model.resetCrop(); model.setStraighten(0) }
                    .font(.footnote.weight(.semibold))
                    .disabled(!model.edits.changesGeometry && model.edits.aspect == .freeform)
            }
            .foregroundStyle(.white)

            VStack(spacing: 4) {
                Text(model.edits.straighten == 0 ? "Straighten" : String(format: "%+.1f°", model.edits.straighten))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(model.edits.straighten == 0 ? Color.white : Color.yellow)
                Slider(
                    value: Binding(
                        get: { model.edits.straighten },
                        set: { model.setStraighten(($0 * 2).rounded() / 2) }
                    ),
                    in: -45...45
                )
                .tint(.yellow)
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(model.modes) { mode in
                Button {
                    model.mode = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 20))
                            .frame(height: 26)
                        Text(mode.title).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(model.mode == mode ? Color.yellow : Color.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
        .disabled(!model.isLoaded || model.loadError != nil)
    }

    // MARK: - Saving

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(model.isVideo ? "Exporting Video" : "Saving")
                    .font(.headline)
                if let progress = model.saveProgress {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Button("Cancel", role: .cancel) { model.cancelSave() }
                    .buttonStyle(.bordered)
            }
            .padding(22)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private extension CGSize {
    func insetBy(_ inset: CGFloat) -> CGSize {
        CGSize(width: max(0, width - inset * 2), height: max(0, height - inset * 2))
    }
}
