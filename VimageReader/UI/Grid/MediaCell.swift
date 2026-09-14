import UIKit

final class MediaCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let videoBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private var loadTask: Task<Void, Never>?
    private var itemURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        videoBadge.tintColor = .white
        videoBadge.contentMode = .scaleAspectFit
        videoBadge.layer.shadowColor = UIColor.black.cgColor
        videoBadge.layer.shadowOpacity = 0.5
        videoBadge.layer.shadowRadius = 2
        videoBadge.layer.shadowOffset = .zero
        videoBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(videoBadge)
        NSLayoutConstraint.activate([
            videoBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            videoBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            videoBadge.widthAnchor.constraint(equalToConstant: 12),
            videoBadge.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
    }

    func configure(_ item: MediaItem) {
        itemURL = item.url
        videoBadge.isHidden = item.kind != .video
        loadTask?.cancel()

        if let cached = ThumbnailService.shared.cachedThumbnail(for: item) {
            imageView.image = cached
            return
        }

        imageView.image = nil
        loadTask = Task { [weak self] in
            let image = await ThumbnailService.shared.thumbnail(for: item)
            guard let self, !Task.isCancelled, self.itemURL == item.url else { return }
            UIView.transition(with: self.imageView, duration: 0.15, options: .transitionCrossDissolve) {
                self.imageView.image = image
            }
        }
    }
}
