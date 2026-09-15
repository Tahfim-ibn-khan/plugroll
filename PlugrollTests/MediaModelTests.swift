import XCTest
@testable import Plugroll

final class MediaModelTests: XCTestCase {
    private func item(_ name: String, modified: Date = .distantPast, size: Int = 0) -> MediaItem {
        let url = URL(fileURLWithPath: "/Drive/\(name)")
        return MediaItem(url: url, kind: MediaKind(url: url) ?? .photo, modified: modified, fileSize: size)
    }

    // MARK: - MediaKind

    func testMediaKindRecognisesPhotosAndVideos() {
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/a.JPG")), .photo)
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/a.heic")), .photo)
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/a.dng")), .photo)
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/a.mov")), .video)
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/a.MP4")), .video)
    }

    func testMediaKindRejectsOtherFiles() {
        XCTAssertNil(MediaKind(url: URL(fileURLWithPath: "/a.svg")))
        XCTAssertNil(MediaKind(url: URL(fileURLWithPath: "/a.txt")))
        XCTAssertNil(MediaKind(url: URL(fileURLWithPath: "/noextension")))
    }

    // MARK: - Cache key

    func testCacheKeyChangesWhenFileChanges() {
        let date = Date(timeIntervalSince1970: 1_000)
        let original = item("a.jpg", modified: date, size: 10)
        XCTAssertEqual(original.cacheKey, item("a.jpg", modified: date, size: 10).cacheKey)
        XCTAssertNotEqual(original.cacheKey, item("a.jpg", modified: date, size: 11).cacheKey)
        XCTAssertNotEqual(original.cacheKey, item("a.jpg", modified: date.addingTimeInterval(1), size: 10).cacheKey)
        XCTAssertNotEqual(original.cacheKey, item("b.jpg", modified: date, size: 10).cacheKey)
        XCTAssertEqual(original.cacheKey.count, 64)
    }

    // MARK: - DurationFormat

    func testDurationFormat() {
        XCTAssertEqual(DurationFormat.string(from: 0), "0:00")
        XCTAssertEqual(DurationFormat.string(from: 42.4), "0:42")
        XCTAssertEqual(DurationFormat.string(from: 725), "12:05")
        XCTAssertEqual(DurationFormat.string(from: 3735), "1:02:15")
        XCTAssertEqual(DurationFormat.string(from: -5), "0:00")
    }

    // MARK: - Sorting

    func testMediaSortOrders() {
        let old = item("b.jpg", modified: Date(timeIntervalSince1970: 0), size: 5)
        let new = item("a10.jpg", modified: Date(timeIntervalSince1970: 100), size: 1)
        let mid = item("a2.jpg", modified: Date(timeIntervalSince1970: 50), size: 9)
        let items = [old, new, mid]

        XCTAssertEqual(MediaSort.newest.sorted(items), [new, mid, old])
        XCTAssertEqual(MediaSort.oldest.sorted(items), [old, mid, new])
        XCTAssertEqual(MediaSort.largest.sorted(items), [mid, old, new])
        // Finder-style: "a2" before "a10".
        XCTAssertEqual(MediaSort.name.sorted(items), [mid, new, old])
    }

    func testFolderSortOrders() {
        let a = FolderEntry(url: URL(fileURLWithPath: "/Drive/Folder 2"), modified: Date(timeIntervalSince1970: 10))
        let b = FolderEntry(url: URL(fileURLWithPath: "/Drive/Folder 10"), modified: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(FolderSort.nameAscending.sorted([b, a]), [a, b])
        XCTAssertEqual(FolderSort.nameDescending.sorted([a, b]), [b, a])
        XCTAssertEqual(FolderSort.newest.sorted([b, a]), [a, b])
        XCTAssertEqual(FolderSort.oldest.sorted([a, b]), [b, a])
    }

    func testDateSortsGroupByDay() {
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: 2020, month: 3, day: 4, hour: 9))!
        let sameDay = day.addingTimeInterval(3600)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let items = [item("1.jpg", modified: day), item("2.jpg", modified: nextDay), item("3.jpg", modified: sameDay)]

        let groups = MediaSort.newest.groups(for: items)
        XCTAssertEqual(groups.map(\.items.count), [1, 2])
        XCTAssertEqual(groups.first?.items.first?.name, "2.jpg")
        XCTAssertFalse(groups.contains { $0.title.isEmpty })
    }

    func testNonDateSortsMakeOneUntitledGroup() {
        let items = [item("1.jpg"), item("2.jpg")]
        let groups = MediaSort.name.groups(for: items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "")
        XCTAssertTrue(MediaSort.largest.groups(for: []).isEmpty)
    }
}
