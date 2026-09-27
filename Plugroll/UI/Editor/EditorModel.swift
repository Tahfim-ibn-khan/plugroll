import AVFoundation
import CoreImage
import Observation
import Photos

/// State behind the editor: the picture being edited, its live preview, and saving.
@MainActor
@Observable
final class EditorModel {
    enum Mode: String, CaseIterable, Identifiable {
        case trim, adjust, filters, crop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .trim: return "Trim"
            case .adjust: return "Adjust"
            case .filters: return "Filters"
            case .crop: return "Crop"
            }
        }

        var symbol: String {
            switch self {
            case .trim: return "timeline.selection"
            case .adjust: return "dial.medium"
            case .filters: return "camera.filters"
            case .crop: return "crop.rotate"
            }
        }
    }

    let item: MediaItem
    var edits = Edits()
    var mode: Mode
    var selectedAdjustment: Adjustment = .exposure

    private(set) var isLoaded = false
    private(set) var loadError: String?
    /// The oriented size of the picture being edited (the preview's, for photos).
    private(set) var sourceSize: CGSize = .zero

    // Photos
    private(set) var preview: CGImage?
    @ObservationIgnored private var base: CIImage?
    @ObservationIgnored private var autoFilters: [CIFilter] = []

    // Videos
    private(set) var player: AVPlayer?
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var filmstrip: [CGImage] = []
    @ObservationIgnored private var asset: AVURLAsset?
    @ObservationIgnored private var timeObserver: Any?

    private(set) var filterThumbnails: [FilterPreset: CGImage] = [:]
    @ObservationIgnored private var thumbnailBase: CIImage?

    // Saving
    private(set) var isSaving = false
    private(set) var saveProgress: Double?
    var failure: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// What Replace Original does with the original. By default it's removed.
    let replaceOptions: EditExporter.ReplaceOptions

    init(item: MediaItem, replaceOptions: EditExporter.ReplaceOptions = .init()) {
        self.item = item
        self.replaceOptions = replaceOptions
        mode = item.kind == .video ? .trim : .adjust
    }

    /// Replace Original keeps the old version in Recently Deleted.
    var replaceKeepsOriginal: Bool { replaceOptions.recentlyDeletedRoot != nil }

    var isVideo: Bool { item.kind == .video }
    var modes: [Mode] { isVideo ? Mode.allCases : [.adjust, .filters, .crop] }
    var canReplaceOriginal: Bool { EditExporter.canReplaceOriginal(item) }
    var hasChanges: Bool { !edits.isUnchanged }

    /// What the preview shows: the whole straightened picture while cropping.
    var previewSize: CGSize {
        EditRenderer.outputSize(for: sourceSize, edits: edits, applyCrop: mode != .crop)
    }

    /// The crop box's shape as a fraction of the uncropped picture's width over height.
    var cropRatio: CGFloat? {
        let uncropped = EditRenderer.outputSize(for: sourceSize, edits: edits, applyCrop: false)
        guard let pixels = edits.aspect.ratio(for: uncropped), uncropped.width > 0 else { return nil }
        return pixels * uncropped.height / uncropped.width
    }

    var trimEnd: Double { edits.trimEnd ?? duration }

    // MARK: - Loading

    func load() async {
        guard !isLoaded else { return }
        if isVideo { await loadVideo() } else { await loadPhoto() }
        isLoaded = true
    }

    private func loadPhoto() async {
        // Screen-sized for a quick preview; saving reads the full file again.
        guard let image = await ThumbnailService.displayImage(for: item, maxPixel: 2048),
              let cgImage = image.cgImage
        else {
            loadError = "The photo couldn't be read. The drive may have been unplugged."
            return
        }
        let ciImage = CIImage(cgImage: cgImage)
        base = ciImage
        sourceSize = ciImage.extent.size
        thumbnailBase = Self.shrink(ciImage, to: 160)
        await renderPreview()
    }

    private func loadVideo() async {
        guard DriveIO.isAvailable else {
            loadError = DriveError.disconnected.localizedDescription
            return
        }
        let asset = AVURLAsset(url: item.url)
        do {
            duration = try await asset.load(.duration).seconds
            sourceSize = try await VideoEditing.orientedSize(of: asset)
        } catch {
            loadError = "The video couldn't be read. \(error.localizedDescription)"
            return
        }
        self.asset = asset

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player?.rate != 0
            }
        }
        self.player = player
        await updateVideo()
        await loadFilmstrip(asset)
    }

    private func loadFilmstrip(_ asset: AVURLAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let count = 10
        var frames: [CGImage] = []
        for index in 0..<count {
            let seconds = duration * (Double(index) + 0.5) / Double(count)
            guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            else { continue }
            frames.append(frame)
            filmstrip = frames
        }
        if let first = frames.first {
            thumbnailBase = Self.shrink(CIImage(cgImage: first), to: 160)
        }
    }

    func tearDown() {
        saveTask?.cancel()
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
    }

    // MARK: - Live preview

    /// Redraws the photo preview, or rebuilds the video's per-frame edits.
    func refresh() async {
        if isVideo { await updateVideo() } else { await renderPreview() }
    }

    private func renderPreview() async {
        guard let base else { return }
        let edits = edits
        let applyCrop = mode != .crop
        let filters = UncheckedSendable(value: edits.autoEnhance ? autoFiltersForBase() : [])
        let rendered = await Task.detached(priority: .userInitiated) {
            EditRenderer.cgImage(from: EditRenderer.apply(edits, to: base, applyCrop: applyCrop, autoFilters: filters.value))
        }.value
        guard !Task.isCancelled else { return }
        preview = rendered
    }

    private func autoFiltersForBase() -> [CIFilter] {
        if autoFilters.isEmpty, let base {
            autoFilters = EditRenderer.autoFilters(for: base)
        }
        return autoFilters
    }

    private func updateVideo() async {
        guard let asset, let player, let playerItem = player.currentItem else { return }
        guard let composition = try? await VideoEditing.composition(
            for: asset,
            edits: edits,
            applyCrop: mode != .crop
        ), !Task.isCancelled else { return }
        playerItem.videoComposition = composition
        player.isMuted = edits.muted
        playerItem.forwardPlaybackEndTime = edits.trimEnd.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        if player.rate == 0 {
            // A paused player only redraws on a seek.
            await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func renderFilterThumbnails() async {
        guard let thumbnailBase else { return }
        var geometryFree = edits
        geometryFree.quarterTurns = 0
        geometryFree.flipped = false
        geometryFree.straighten = 0
        geometryFree.crop = Edits.fullCrop
        geometryFree.autoEnhance = false
        let template = geometryFree
        let rendered = await Task.detached(priority: .utility) { () -> [FilterPreset: CGImage] in
            var thumbnails: [FilterPreset: CGImage] = [:]
            for preset in FilterPreset.allCases {
                var edits = template
                edits.filter = preset
                thumbnails[preset] = EditRenderer.cgImage(from: EditRenderer.apply(edits, to: thumbnailBase))
            }
            return thumbnails
        }.value
        filterThumbnails = rendered
    }

    private static func shrink(_ image: CIImage, to side: CGFloat) -> CIImage {
        let scale = side / max(image.extent.width, image.extent.height, 1)
        guard scale < 1 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Editing

    /// Back to the original, trim included, like Revert in Photos.
    func revert() {
        edits = Edits()
    }

    func rotate() {
        edits.quarterTurns = (edits.quarterTurns + 1) % 4
        resetCropToAspect()
    }

    func flip() {
        edits.flipped.toggle()
        resetCropToAspect()
    }

    func setStraighten(_ degrees: Double) {
        edits.straighten = degrees
        resetCropToAspect()
    }

    func setAspect(_ aspect: AspectPreset) {
        edits.aspect = aspect
        resetCropToAspect()
    }

    func resetCrop() {
        edits.aspect = .freeform
        edits.crop = Edits.fullCrop
    }

    /// The largest centred box of the chosen shape.
    private func resetCropToAspect() {
        guard let ratio = cropRatio else {
            edits.crop = Edits.fullCrop
            return
        }
        let size = ratio >= 1 ? CGSize(width: 1, height: 1 / ratio) : CGSize(width: ratio, height: 1)
        edits.crop = CGRect(x: (1 - size.width) / 2, y: (1 - size.height) / 2, width: size.width, height: size.height)
    }

    func toggleAuto() {
        edits.autoEnhance.toggle()
    }

    // MARK: - Video playback

    func togglePlayback() {
        guard let player else { return }
        if player.rate != 0 {
            player.pause()
            return
        }
        // From the start of the trim if the playhead is outside it.
        if currentTime < edits.trimStart || currentTime >= trimEnd - 0.05 {
            player.seek(to: CMTime(seconds: edits.trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    func seek(to seconds: Double) {
        player?.pause()
        currentTime = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Saving

    func save(to destination: EditDestination, completion: @escaping (EditResult) -> Void) {
        guard !isSaving else { return }
        isSaving = true
        saveProgress = isVideo ? 0 : nil
        player?.pause()

        saveTask = Task {
            defer {
                isSaving = false
                saveProgress = nil
            }
            do {
                if destination == .photos {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard status == .authorized || status == .limited else {
                        failure = "Allow Plugroll to add photos in Settings → Apps → Plugroll → Photos."
                        return
                    }
                }
                let batch = try ExportService.makeBatchDirectory()
                defer { ExportService.remove(batch) }

                let rendered: URL
                if isVideo {
                    rendered = try await EditExporter.renderVideo(item, edits: edits, in: batch) { fraction in
                        Task { @MainActor [weak self] in self?.saveProgress = fraction }
                    }
                } else {
                    let filters = UncheckedSendable(value: edits.autoEnhance ? autoFiltersForBase() : [])
                    rendered = try await EditExporter.renderPhoto(item, edits: edits, autoFilters: filters.value, in: batch)
                }
                try Task.checkCancellation()
                let result = try await EditExporter.save(rendered, for: item, to: destination, options: replaceOptions)
                completion(result)
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    func cancelSave() {
        saveTask?.cancel()
    }
}
