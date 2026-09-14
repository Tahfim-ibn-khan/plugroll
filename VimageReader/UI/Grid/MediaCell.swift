import UIKit

final class MediaCell: UICollectionViewCell {
    private let imageView = UIImageView()
    /// Darkens the bottom edge so the white duration text reads on bright thumbnails.
    private let bottomShade = GradientView()
    private let durationLabel = UILabel()
    private var thumbnailTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var itemURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        bottomShade.translatesAutoresizingMaskIntoConstraints = false
        bottomShade.isUserInteractionEnabled = false
        contentView.addSubview(bottomShade)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.textAlignment = .right
        durationLabel.layer.shadowColor = UIColor.black.cgColor
        durationLabel.layer.shadowOpacity = 0.4
        durationLabel.layer.shadowRadius = 1.5
        durationLabel.layer.shadowOffset = .zero
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            bottomShade.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomShade.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomShade.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomShade.heightAnchor.constraint(equalToConstant: 28),

            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        durationTask?.cancel()
        thumbnailTask = nil
        durationTask = nil
        imageView.image = nil
        setDuration(nil)
    }

    func configure(_ item: MediaItem) {
        itemURL = item.url
        thumbnailTask?.cancel()
        durationTask?.cancel()

        configureDuration(item)

        if let cached = ThumbnailService.shared.cachedThumbnail(for: item) {
            imageView.image = cached
            return
        }

        imageView.image = nil
        thumbnailTask = Task { [weak self] in
            let image = await ThumbnailService.shared.thumbnail(for: item)
            guard let self, !Task.isCancelled, self.itemURL == item.url else { return }
            UIView.transition(with: self.imageView, duration: 0.15, options: .transitionCrossDissolve) {
                self.imageView.image = image
            }
        }
    }

    private func configureDuration(_ item: MediaItem) {
        guard item.kind == .video else {
            setDuration(nil)
            return
        }
        if let cached = VideoDurationService.shared.cachedDuration(for: item) {
            setDuration(cached)
            return
        }
        // A video whose length can't be read still gets marked as a video.
        setDuration(nil, isVideo: true)
        durationTask = Task { [weak self] in
            let seconds = await VideoDurationService.shared.duration(for: item)
            guard let self, !Task.isCancelled, self.itemURL == item.url, let seconds else { return }
            self.setDuration(seconds)
        }
    }

    private func setDuration(_ seconds: Double?, isVideo: Bool = false) {
        if let seconds {
            durationLabel.text = DurationFormat.string(from: seconds)
        } else if isVideo {
            durationLabel.text = "▶︎"
        } else {
            durationLabel.text = nil
        }
        let showsBadge = durationLabel.text != nil
        durationLabel.isHidden = !showsBadge
        bottomShade.isHidden = !showsBadge
    }
}

/// A view whose backing layer is a top-clear, bottom-dark gradient.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.45).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
