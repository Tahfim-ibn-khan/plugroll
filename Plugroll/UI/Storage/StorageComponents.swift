import SwiftUI

/// A ring that fills as the drive fills, for the top of every folder screen.
struct StorageGauge: View {
    let space: DriveSpace?
    /// Adds "120 GB free" next to the ring.
    var showsFreeSpace = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: space?.fractionUsed ?? 0)
                    .stroke(StorageColors.tint(for: space), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            .animation(.easeInOut, value: space)

            if showsFreeSpace, let space {
                Text("\(ByteFormat.string(space.available)) free")
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue(space.map {
            "\(ByteFormat.string($0.used)) used of \(ByteFormat.string($0.total)), \(ByteFormat.string($0.available)) free"
        } ?? "Unknown")
    }
}

enum StorageColors {
    static func tint(for space: DriveSpace?) -> Color {
        guard let fraction = space?.fractionUsed else { return .accentColor }
        if fraction >= 0.95 { return .red }
        if fraction >= 0.85 { return .orange }
        return .accentColor
    }
}

/// The long bar at the top of the Storage screen, like iPhone Storage in Settings.
struct StorageBar: View {
    let space: DriveSpace?
    let recentlyDeletedBytes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let space {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(ByteFormat.string(space.used)) of \(ByteFormat.string(space.total)) used")
                        .font(.headline)
                    Spacer()
                    Text("\(ByteFormat.string(space.available)) free")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()

                GeometryReader { geometry in
                    let width = geometry.size.width
                    let total = Double(max(space.total, 1))
                    let deleted = min(Double(recentlyDeletedBytes), Double(space.used))
                    let usedWidth = width * (Double(space.used) - deleted) / total
                    let deletedWidth = width * deleted / total
                    HStack(spacing: 0) {
                        Rectangle().fill(StorageColors.tint(for: space)).frame(width: max(0, usedWidth))
                        Rectangle().fill(Color.gray.opacity(0.6)).frame(width: max(0, deletedWidth))
                        Rectangle().fill(Color.secondary.opacity(0.18))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .frame(height: 22)

                HStack(spacing: 14) {
                    legend("Used", color: StorageColors.tint(for: space))
                    if recentlyDeletedBytes > 0 {
                        legend("Recently Deleted", color: .gray.opacity(0.6))
                    }
                    legend("Free", color: .secondary.opacity(0.18))
                }
            } else {
                HStack {
                    ProgressView()
                    Text("Reading drive size…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A thumbnail from the shared thumbnail cache, filling its frame.
struct ThumbnailView: View {
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if item.kind == .video {
                    Image(systemName: "video").foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: item.cacheKey) {
                image = ThumbnailService.shared.cachedThumbnail(for: item)
                if image == nil {
                    image = await ThumbnailService.shared.thumbnail(for: item)
                }
            }
    }
}

/// A square grid of thumbnails with an optional select mode, for the cleanup lists.
struct SelectableGrid: View {
    let items: [MediaItem]
    let isSelecting: Bool
    @Binding var selection: Set<URL>
    /// Text in the corner of each tile (a size, or days left).
    var badge: (MediaItem) -> String? = { _ in nil }
    let onOpen: (MediaItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    tile(item)
                }
            }
        }
    }

    private func tile(_ item: MediaItem) -> some View {
        let isSelected = selection.contains(item.url)
        return Button {
            if isSelecting {
                if isSelected { selection.remove(item.url) } else { selection.insert(item.url) }
            } else {
                onOpen(item)
            }
        } label: {
            ThumbnailView(item: item)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if let text = badge(item) {
                        Text(text)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.kind == .video {
                        Image(systemName: "video.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(5)
                    }
                }
                .overlay {
                    if isSelecting && isSelected {
                        Color.white.opacity(0.25)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Color.blue : Color.black.opacity(0.2))
                            .shadow(radius: 2)
                            .padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "12 items · 3.4 GB"
@MainActor
func itemsAndSize(_ items: [MediaItem]) -> String {
    "\(MediaActions.count(items.count)) · \(ByteFormat.string(items.reduce(0) { $0 + $1.fileSize }))"
}
