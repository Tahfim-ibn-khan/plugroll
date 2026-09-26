import UIKit

final class FolderCell: UICollectionViewCell {
    static let labelHeight: CGFloat = 28

    private let coverView = UIImageView()
    private let nameLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var folderURL: URL?

    private static let heart = UIImage(
        systemName: "heart.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 40)
    )

    private static let placeholder = UIImage(
        systemName: "folder.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 40)
    )

    override init(frame: CGRect) {
        super.init(frame: frame)

        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 8
        coverView.backgroundColor = .secondarySystemBackground
        coverView.tintColor = .tertiaryLabel
        coverView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(coverView)

        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            coverView.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverView.heightAnchor.constraint(equalTo: coverView.widthAnchor),

            nameLabel.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
    }

    func configure(_ folder: FolderEntry) {
        folderURL = folder.url
        nameLabel.text = folder.name
        coverView.tintColor = .tertiaryLabel
        coverView.alpha = 1
        showPlaceholder()

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let cover = await FolderScanner.cover(for: folder.url),
                  let image = await ThumbnailService.shared.thumbnail(for: cover)
            else { return }
            guard let self, !Task.isCancelled, self.folderURL == folder.url else { return }
            self.coverView.contentMode = .scaleAspectFill
            self.coverView.image = image
        }
    }

    /// The Favourites album: a heart instead of a cover.
    func configureFavourites(count: Int) {
        folderURL = nil
        loadTask?.cancel()
        loadTask = nil
        nameLabel.text = "Favourites"
        coverView.contentMode = .center
        coverView.tintColor = .systemPink
        coverView.image = Self.heart
        coverView.alpha = count == 0 ? 0.6 : 1
    }

    private func showPlaceholder() {
        coverView.contentMode = .center
        coverView.image = Self.placeholder
    }
}
