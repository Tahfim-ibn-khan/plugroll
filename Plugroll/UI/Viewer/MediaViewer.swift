import AVKit
import SwiftUI
import UIKit

/// Full-screen swipe-through viewer for photos and videos.
struct MediaViewer: View {
    /// Tells the folder screen which files were deleted from here.
    let onDeleted: ([MediaItem]) -> Void

    @State private var items: [MediaItem]
    @State private var currentID: URL?
    @State private var chromeVisible = true
    /// Player for the current page when it is a video; nil on photo pages.
    @State private var player: PlayerModel?
    /// Bumped on every control touch to restart the auto-hide countdown.
    @State private var controlsActivity = 0
    @State private var actions = MediaActions()
    @State private var confirmingDelete = false
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    init(items: [MediaItem], start: MediaItem, onDeleted: @escaping ([MediaItem]) -> Void = { _ in }) {
        self.onDeleted = onDeleted
        _items = State(initialValue: items)
        _currentID = State(initialValue: start.id)
    }

    private var currentIndex: Int? {
        items.firstIndex { $0.id == currentID }
    }

    private var currentItem: MediaItem? {
        currentIndex.map { items[$0] }
    }

    private var isCurrentFavourite: Bool {
        currentItem.map { Favourites.shared.isFavourite($0) } ?? false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        MediaPage(
                            item: item,
                            isActive: item.id == currentID,
                            player: item.id == currentID ? player : nil,
                            onSingleTap: { toggleChrome() }
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID, anchor: .center)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()

            if chromeVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if let player {
                        VideoControls(player: player, onInteraction: { controlsActivity += 1 })
                            .frame(maxWidth: 640)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                    actionBar
                }
                .transition(.opacity)
            }

            if !appState.isDriveConnected {
                VStack {
                    Spacer()
                    DriveDisconnectedBanner()
                        .environment(\.colorScheme, .dark)
                        .padding(.horizontal, 16)
                        .padding(.bottom, chromeVisible ? 130 : 16)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.isDriveConnected)
        .onChange(of: appState.reconnectCount) { _, _ in
            updatePlayer()
        }
        .statusBarHidden()
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .mediaActionsOverlay(actions)
        .confirmationDialog(
            currentItem?.kind == .video ? "Delete This Video?" : "Delete This Photo?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from Drive", role: .destructive) {
                deleteCurrent()
            }
        } message: {
            Text("This permanently deletes the file from the drive. It can't be undone.")
        }
        .onChange(of: currentID, initial: true) { _, _ in
            updatePlayer()
        }
        .onDisappear {
            player?.tearDown()
            player = nil
            OrientationController.reset()
        }
        .task(id: AutoHideKey(
            chromeVisible: chromeVisible,
            isPlaying: player?.isPlaying ?? false,
            isScrubbing: player?.isScrubbing ?? false,
            activity: controlsActivity
        )) {
            // While a video plays, controls fade away after a few quiet seconds, like Photos.
            guard chromeVisible, let player, player.isPlaying, !player.isScrubbing else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
        }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    /// Keeps exactly one player: for the current page if it is a video, otherwise none.
    private func updatePlayer() {
        guard let index = currentIndex, items[index].kind == .video else {
            player?.tearDown()
            player = nil
            return
        }
        let item = items[index]
        guard player?.url != item.url else { return }
        player?.tearDown()
        player = nil
        // No player for a file on an unplugged drive; one is made when it reconnects.
        guard DriveIO.isAvailable else { return }
        let model = PlayerModel(url: item.url, knownDuration: VideoDurationService.shared.cachedDuration(for: item))
        player = model
        model.play()
    }

    private func deleteCurrent() {
        guard let index = currentIndex else { return }
        let item = items[index]
        // Let go of the file before deleting it.
        if player?.url == item.url {
            player?.tearDown()
            player = nil
        }
        actions.delete([item]) { deleted in
            let gone = Set(deleted.map(\.url))
            items.removeAll { gone.contains($0.url) }
            onDeleted(deleted)
            if items.isEmpty {
                dismiss()
            } else {
                // Land on the item that slid into the deleted one's place.
                currentID = items[min(index, items.count - 1)].id
                updatePlayer()
            }
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            circleButton("xmark") { dismiss() }

            Spacer(minLength: 0)

            if let index = currentIndex {
                VStack(spacing: 1) {
                    Text(items[index].name)
                        .font(.footnote.weight(.semibold))
                    Text("\(Self.dateFormatter.string(from: items[index].modified)) · \(index + 1) of \(items.count)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer(minLength: 0)

            circleButton("rectangle.landscape.rotate") {
                OrientationController.toggle()
                controlsActivity += 1
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .environment(\.colorScheme, .dark)
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton("square.and.arrow.up", label: "Share") {
                if let currentItem { actions.share([currentItem]) }
            }
            actionButton(
                isCurrentFavourite ? "heart.fill" : "heart",
                label: isCurrentFavourite ? "Remove from Favourites" : "Favourite"
            ) {
                if let currentItem { Favourites.shared.toggle([currentItem]) }
            }
            actionButton("square.and.arrow.down", label: "Save") {
                if let currentItem { actions.saveToPhotos([currentItem]) }
            }
            actionButton("trash", label: "Delete") {
                confirmingDelete = true
            }
        }
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.bottom, 8)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            controlsActivity += 1
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct AutoHideKey: Equatable {
    let chromeVisible: Bool
    let isPlaying: Bool
    let isScrubbing: Bool
    let activity: Int
}

private struct MediaPage: View {
    let item: MediaItem
    let isActive: Bool
    let player: PlayerModel?
    let onSingleTap: () -> Void

    var body: some View {
        switch item.kind {
        case .photo: PhotoPage(item: item, isActive: isActive, onSingleTap: onSingleTap)
        case .video: VideoPage(item: item, player: player, onSingleTap: onSingleTap)
        }
    }
}

private struct PhotoPage: View {
    let item: MediaItem
    let isActive: Bool
    let onSingleTap: () -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            // The grid's thumbnail stands in until the full-size decode lands.
            if let shown = image ?? ThumbnailService.shared.cachedThumbnail(for: item) {
                ZoomableImage(image: shown, isActive: isActive, onSingleTap: onSingleTap)
            } else {
                Group {
                    if loadFailed {
                        Label("Can't Load Photo", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSingleTap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reloads when the drive comes back, in case the first try failed.
        .task(id: "\(item.id.path)#\(appState.reconnectCount)") {
            guard image == nil else { return }
            loadFailed = false
            image = await ThumbnailService.displayImage(for: item)
            loadFailed = image == nil
        }
        .onDisappear {
            image = nil // free memory for pages swiped away
        }
    }
}

private struct VideoPage: View {
    let item: MediaItem
    /// Set only while this page is the current one.
    let player: PlayerModel?
    let onSingleTap: () -> Void

    @State private var thumbnail: UIImage?
    @State private var skipFeedback: SkipFeedback?

    private struct SkipFeedback: Equatable {
        let forward: Bool
        let id = UUID()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The first frame stands in until the player draws, so pages never flash black.
                if let thumbnail = thumbnail ?? ThumbnailService.shared.cachedThumbnail(for: item) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                }
                if let player {
                    PlayerLayerView(player: player.player)
                }
                if let skipFeedback {
                    skipBadge(forward: skipFeedback.forward, width: geometry.size.width)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                guard let player else { return }
                let forward = location.x > geometry.size.width / 2
                player.skip(by: forward ? 10 : -10)
                showSkipFeedback(forward: forward)
            }
            .onTapGesture(count: 1) {
                onSingleTap()
            }
        }
        .task(id: item.id) {
            if thumbnail == nil {
                thumbnail = await ThumbnailService.shared.thumbnail(for: item)
            }
        }
    }

    private func skipBadge(forward: Bool, width: CGFloat) -> some View {
        HStack {
            if forward { Spacer() }
            Label("10", systemImage: forward ? "goforward" : "gobackward")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, width * 0.12)
            if !forward { Spacer() }
        }
        .allowsHitTesting(false)
    }

    private func showSkipFeedback(forward: Bool) {
        let feedback = SkipFeedback(forward: forward)
        withAnimation(.easeOut(duration: 0.15)) { skipFeedback = feedback }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard skipFeedback == feedback else { return }
            withAnimation(.easeIn(duration: 0.25)) { skipFeedback = nil }
        }
    }
}

/// Pinch to zoom, double-tap to zoom in on a spot, drag to pan while zoomed.
/// A UIScrollView does this properly; SwiftUI gestures fight the paging swipe.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let isActive: Bool
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> ZoomableImageView {
        let view = ZoomableImageView()
        view.onSingleTap = onSingleTap
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: ZoomableImageView, context: Context) {
        view.onSingleTap = onSingleTap
        view.setImage(image)
        if !isActive { view.resetZoom() }
    }
}

/// A UIScrollView does the zooming; this view owns it rather than being it, since a
/// scroll view acting as its own delegate is asking for trouble.
private final class ZoomableImageView: UIView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var lastLaidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.decelerationRate = .fast
        // While the photo fits the screen there is nothing to pan, and leaving the pan
        // recognizer live would swallow the horizontal swipe to the next photo.
        scrollView.panGestureRecognizer.isEnabled = false
        addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ newImage: UIImage) {
        guard imageView.image !== newImage else { return }
        let sameShape = imageView.image.map { hasSameShape($0, newImage) } ?? false
        imageView.image = newImage
        // A sharper copy of the same picture arriving: leave the zoom where the user put it.
        if !sameShape {
            scrollView.zoomScale = scrollView.minimumZoomScale
            layoutImage()
        }
    }

    func resetZoom() {
        guard scrollView.zoomScale != scrollView.minimumZoomScale else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        layoutImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if bounds.size != lastLaidOutSize {
            lastLaidOutSize = bounds.size
            scrollView.zoomScale = scrollView.minimumZoomScale
            layoutImage()
        } else {
            centerImage()
        }
    }

    /// Sizes the image view to the picture's aspect-fit rect, so zooming magnifies the
    /// photo instead of the empty bars beside it.
    private func layoutImage() {
        let available = scrollView.bounds.size
        guard let image = imageView.image,
              available.width > 0, available.height > 0,
              image.size.width > 0, image.size.height > 0
        else { return }

        let scale = min(available.width / image.size.width, available.height / image.size.height)
        let fitted = CGSize(
            width: (image.size.width * scale).rounded(.down),
            height: (image.size.height * scale).rounded(.down)
        )
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        centerImage()
        updatePanAvailability()
    }

    /// Keeps the photo in the middle of the screen when it is smaller than the screen.
    private func centerImage() {
        let available = scrollView.bounds.size
        let content = scrollView.contentSize
        let insetX = max(0, (available.width - content.width) / 2)
        let insetY = max(0, (available.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    private func updatePanAvailability() {
        scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > scrollView.minimumZoomScale
    }

    private func hasSameShape(_ a: UIImage, _ b: UIImage) -> Bool {
        guard a.size.height > 0, b.size.height > 0 else { return false }
        return abs(a.size.width / a.size.height - b.size.width / b.size.height) < 0.01
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let target = min(scrollView.maximumZoomScale, 3)
        let point = gesture.location(in: imageView)
        let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
        let rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        scrollView.zoom(to: rect, animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        updatePanAvailability()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updatePanAvailability()
    }
}
