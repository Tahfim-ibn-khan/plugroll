import SwiftUI
import UIKit

/// UIKit collection view wrapped for SwiftUI: stays smooth with thousands of items.
struct FolderGridView: UIViewControllerRepresentable {
    let folders: [FolderEntry]
    let groups: [MediaGroup]
    var isSelecting = false
    /// Changing this re-runs thumbnail loading for visible cells (after the drive reconnects).
    var reloadToken = 0
    let onOpenFolder: (FolderEntry) -> Void
    let onOpenItem: (MediaItem) -> Void
    var onSelectionChange: ([MediaItem]) -> Void = { _ in }

    func makeUIViewController(context: Context) -> FolderGridViewController {
        FolderGridViewController()
    }

    func updateUIViewController(_ controller: FolderGridViewController, context: Context) {
        controller.onOpenFolder = onOpenFolder
        controller.onOpenItem = onOpenItem
        controller.onSelectionChange = onSelectionChange
        controller.apply(folders: folders, groups: groups)
        controller.setSelecting(isSelecting)
        controller.reloadIfNeeded(token: reloadToken)
    }
}

final class FolderGridViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    private enum Section: Hashable {
        case folders
        /// The section's header text; empty when the sort order has no day headers.
        case media(String)
    }

    private enum Row: Hashable {
        case folder(FolderEntry)
        case media(MediaItem)
    }

    var onOpenFolder: ((FolderEntry) -> Void)?
    var onOpenItem: ((MediaItem) -> Void)?
    var onSelectionChange: (([MediaItem]) -> Void)?

    private var isSelecting = false
    private var reloadToken = 0
    /// Count line shown at the right of each section header.
    private var sectionDetails: [Section: String] = [:]
    private var folders: [FolderEntry] = []
    private var groups: [MediaGroup] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>?
    private var prefetchTasks: [URL: Task<Void, Never>] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        // Needed for dragging a finger across the grid to select many items.
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let folderRegistration = UICollectionView.CellRegistration<FolderCell, FolderEntry> { cell, _, folder in
            cell.configure(folder)
        }
        let mediaRegistration = UICollectionView.CellRegistration<MediaCell, MediaItem> { cell, _, item in
            cell.configure(item)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Row>(collectionView: collectionView) { collectionView, indexPath, row in
            switch row {
            case .folder(let folder):
                return collectionView.dequeueConfiguredReusableCell(using: folderRegistration, for: indexPath, item: folder)
            case .media(let item):
                return collectionView.dequeueConfiguredReusableCell(using: mediaRegistration, for: indexPath, item: item)
            }
        }
        self.dataSource = dataSource

        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: indexPath.section) else {
                header.configure(title: "", detail: nil)
                return
            }
            switch section {
            case .folders: header.configure(title: "Folders", detail: self.sectionDetails[section])
            case .media(let title): header.configure(title: title, detail: self.sectionDetails[section])
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        applySnapshot()
    }

    func apply(folders: [FolderEntry], groups: [MediaGroup]) {
        guard folders != self.folders || groups != self.groups else { return }
        self.folders = folders
        self.groups = groups
        guard dataSource != nil else { return }
        // The layout reads section identifiers when it is invalidated, which applying
        // the snapshot does, so a regrouped sort order re-lays itself out.
        applySnapshot()
    }

    private func applySnapshot() {
        cancelAllPrefetching()

        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        var details: [Section: String] = [:]
        if !folders.isEmpty {
            snapshot.appendSections([.folders])
            snapshot.appendItems(folders.map(Row.folder), toSection: .folders)
            details[.folders] = folders.count == 1 ? "1 Folder" : "\(folders.count) Folders"
        }
        for group in groups where !group.items.isEmpty {
            let section = Section.media(group.title)
            snapshot.appendSections([section])
            snapshot.appendItems(group.items.map(Row.media), toSection: section)
            details[section] = Self.countText(for: group.items)
        }
        sectionDetails = details
        dataSource?.apply(snapshot, animatingDifferences: false)
        // Deleted items drop out of the selection along with the grid.
        if isSelecting { reportSelection() }
    }

    /// "12 Photos, 3 Videos", like the counts in Photos.
    private static func countText(for items: [MediaItem]) -> String {
        let videos = items.filter { $0.kind == .video }.count
        let photos = items.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append(photos == 1 ? "1 Photo" : "\(photos) Photos") }
        if videos > 0 { parts.append(videos == 1 ? "1 Video" : "\(videos) Videos") }
        return parts.joined(separator: ", ")
    }

    /// Cells whose thumbnails or covers failed while the drive was away try again.
    func reloadIfNeeded(token: Int) {
        guard token != reloadToken else { return }
        reloadToken = token
        guard let dataSource else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    func setSelecting(_ selecting: Bool) {
        guard selecting != isSelecting, collectionView != nil else { return }
        isSelecting = selecting
        collectionView.isEditing = selecting
        collectionView.allowsMultipleSelection = selecting
        if !selecting {
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
        reportSelection()
    }

    private func reportSelection() {
        let items = (collectionView.indexPathsForSelectedItems ?? [])
            .sorted()
            .compactMap { indexPath -> MediaItem? in
                guard case .media(let item) = dataSource?.itemIdentifier(for: indexPath) else { return nil }
                return item
            }
        // Deferred: this can run inside a SwiftUI update, which must not change state.
        DispatchQueue.main.async { [weak self] in
            self?.onSelectionChange?(items)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        // Folders open, but never join a selection.
        guard isSelecting else { return true }
        if case .media = dataSource?.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        isSelecting
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if isSelecting { reportSelection() }
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            let width = environment.container.effectiveContentSize.width
            guard let section = self?.dataSource?.sectionIdentifier(for: sectionIndex) else {
                return Self.mediaSection(width: width, hasHeader: false)
            }
            switch section {
            case .folders:
                return Self.folderSection(width: width)
            case .media(let title):
                return Self.mediaSection(width: width, hasHeader: !title.isEmpty)
            }
        }
    }

    /// Album-style cards: square cover with the folder name underneath.
    private static func folderSection(width: CGFloat) -> NSCollectionLayoutSection {
        let columns = width > 600 ? 4 : 2
        let inset: CGFloat = 16
        let spacing: CGFloat = 14
        let cardWidth = floor((width - inset * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let cardHeight = cardWidth + FolderCell.labelHeight

        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .absolute(cardWidth), heightDimension: .absolute(cardHeight)
        ))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(cardHeight)),
            repeatingSubitem: item,
            count: columns
        )
        group.interItemSpacing = .fixed(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        section.contentInsets = .init(top: 4, leading: inset, bottom: 20, trailing: inset)
        // The section's own side insets already line the header up with the cards.
        section.boundarySupplementaryItems = [makeHeader(height: 44, sideInset: 0)]
        return section
    }

    /// Photos-style square grid with thin gaps.
    private static func mediaSection(width: CGFloat, hasHeader: Bool) -> NSCollectionLayoutSection {
        let columns = width > 600 ? 5 : 3
        let spacing: CGFloat = 2
        // Absolute square cells: the group lays items out at their own size, so a
        // full-width item would give one stretched cell per row.
        let side = floor((width - spacing * CGFloat(columns - 1)) / CGFloat(columns))

        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .absolute(side), heightDimension: .absolute(side)
        ))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
            repeatingSubitem: item,
            count: columns
        )
        // Flexible spacing soaks up the sub-point remainder so the grid stays edge to edge.
        group.interItemSpacing = .flexible(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        if hasHeader {
            // The grid runs edge to edge, so the header text gets its own margin.
            section.boundarySupplementaryItems = [makeHeader(height: 40, sideInset: 16)]
            section.contentInsets = .init(top: 0, leading: 0, bottom: 14, trailing: 0)
        }
        return section
    }

    /// Plain headers that scroll with the grid, like Photos. Pinned headers with a solid
    /// background sat under the translucent navigation bar as opaque strips.
    private static func makeHeader(height: CGFloat, sideInset: CGFloat) -> NSCollectionLayoutBoundarySupplementaryItem {
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
        header.contentInsets = .init(top: 0, leading: sideInset, bottom: 0, trailing: sideInset)
        return header
    }

    // MARK: - Opening

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isSelecting {
            reportSelection()
            return
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource?.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .folder(let folder): onOpenFolder?(folder)
        case .media(let item): onOpenItem?(item)
        }
    }

    // MARK: - Prefetching

    /// Starts thumbnails for cells about to scroll into view, so the grid fills in
    /// ahead of the finger instead of after it.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let row = dataSource?.itemIdentifier(for: indexPath), case .media(let item) = row else { continue }
            guard prefetchTasks[item.url] == nil,
                  ThumbnailService.shared.cachedThumbnail(for: item) == nil
            else { continue }

            prefetchTasks[item.url] = Task { @MainActor [weak self] in
                _ = await ThumbnailService.shared.thumbnail(for: item)
                self?.prefetchTasks[item.url] = nil
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let row = dataSource?.itemIdentifier(for: indexPath), case .media(let item) = row else { continue }
            prefetchTasks.removeValue(forKey: item.url)?.cancel()
        }
    }

    private func cancelAllPrefetching() {
        for task in prefetchTasks.values {
            task.cancel()
        }
        prefetchTasks.removeAll()
    }
}

/// Section title with a count on the right, drawn straight on the page like Photos:
/// no background, and it scrolls away with its section.
final class SectionHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    func configure(title: String, detail: String?) {
        titleLabel.text = title
        detailLabel.text = detail
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .right
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
