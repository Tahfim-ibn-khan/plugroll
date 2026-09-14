import AVKit
import SwiftUI
import UIKit

/// Full-screen swipe-through viewer for photos and videos.
struct MediaViewer: View {
    let items: [MediaItem]

    @State private var currentID: URL?
    @State private var chromeVisible = true
    @Environment(\.dismiss) private var dismiss

    init(items: [MediaItem], start: MediaItem) {
        self.items = items
        _currentID = State(initialValue: start.id)
    }

    private var currentIndex: Int? {
        items.firstIndex { $0.id == currentID }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        MediaPage(
                            item: item,
                            isActive: item.id == currentID,
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
                topBar.transition(.opacity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .onChange(of: currentID) { _, _ in
            // Videos carry their own controls and no tap target of their own,
            // so make sure the close button is back when one comes on screen.
            if let index = currentIndex, items[index].kind == .video, !chromeVisible {
                toggleChrome()
            }
        }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .tint(.white)

            Spacer()

            if let index = currentIndex {
                VStack(spacing: 1) {
                    Text(items[index].name)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                    Text("\(index + 1) of \(items.count)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

private struct MediaPage: View {
    let item: MediaItem
    let isActive: Bool
    let onSingleTap: () -> Void

    var body: some View {
        switch item.kind {
        case .photo: PhotoPage(item: item, isActive: isActive, onSingleTap: onSingleTap)
        case .video: VideoPage(item: item, isActive: isActive)
        }
    }
}

private struct PhotoPage: View {
    let item: MediaItem
    let isActive: Bool
    let onSingleTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Group {
            // The grid's thumbnail stands in until the full-size decode lands.
            if let shown = image ?? ThumbnailService.shared.cachedThumbnail(for: item) {
                ZoomableImage(image: shown, isActive: isActive, onSingleTap: onSingleTap)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSingleTap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            image = await ThumbnailService.displayImage(for: item)
        }
        .onDisappear {
            image = nil // free memory for pages swiped away
        }
    }
}

private struct VideoPage: View {
    let item: MediaItem
    let isActive: Bool
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if let thumbnail = ThumbnailService.shared.cachedThumbnail(for: item) {
                Image(uiImage: thumbnail).resizable().scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if player == nil { player = AVPlayer(url: item.url) }
            if isActive { player?.play() }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .onChange(of: isActive) { _, active in
            if active { player?.play() } else { player?.pause() }
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
