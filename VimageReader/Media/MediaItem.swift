import Foundation
import UniformTypeIdentifiers

enum MediaKind: Hashable {
    case photo
    case video

    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) {
            self = .video
        } else if type.conforms(to: .image), !type.conforms(to: .svg) {
            // Includes HEIC, JPEG, PNG and camera RAW (CR3, ARW, NEF, DNG...).
            self = .photo
        } else {
            return nil
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    let url: URL
    let kind: MediaKind
    let modified: Date
    let fileSize: Int

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var isRAW: Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
    }
}

struct FolderEntry: Identifiable, Hashable {
    let url: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct FolderListing: Equatable {
    var folders: [FolderEntry]
    var items: [MediaItem]
}

/// How the grid orders a folder's photos and videos.
enum MediaSort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case name
    case largest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        case .name: return "Name"
        case .largest: return "Largest First"
        }
    }

    /// Date order gets Photos-style day headers; the other orders are one plain grid.
    var groupsByDay: Bool {
        switch self {
        case .newest, .oldest: return true
        case .name, .largest: return false
        }
    }

    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .newest:
            return items.sorted { $0.modified > $1.modified }
        case .oldest:
            return items.sorted { $0.modified < $1.modified }
        case .name:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .largest:
            return items.sorted { $0.fileSize > $1.fileSize }
        }
    }

    /// Items in this order, split into the sections the grid draws.
    func groups(for items: [MediaItem]) -> [MediaGroup] {
        let ordered = sorted(items)
        guard groupsByDay else {
            return ordered.isEmpty ? [] : [MediaGroup(title: "", items: ordered)]
        }

        let calendar = Calendar.current
        var groups: [MediaGroup] = []
        var day: Date?
        var bucket: [MediaItem] = []

        for item in ordered {
            let itemDay = calendar.startOfDay(for: item.modified)
            if itemDay != day {
                if let day, !bucket.isEmpty {
                    groups.append(MediaGroup(title: MediaGroup.title(for: day), items: bucket))
                }
                day = itemDay
                bucket = []
            }
            bucket.append(item)
        }
        if let day, !bucket.isEmpty {
            groups.append(MediaGroup(title: MediaGroup.title(for: day), items: bucket))
        }
        return groups
    }
}

/// One section of the grid. An empty title means no header is drawn.
struct MediaGroup: Identifiable, Equatable {
    let title: String
    let items: [MediaItem]

    var id: String { title }

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return dayFormatter.string(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}
