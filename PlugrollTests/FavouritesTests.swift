import XCTest
@testable import Plugroll

@MainActor
final class FavouritesTests: XCTestCase {
    private var drive: URL!

    override func setUp() async throws {
        // A unique folder name each run, so each test gets its own stored list.
        drive = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        Favourites.shared.setRoot(drive)
    }

    override func tearDown() async throws {
        Favourites.shared.setRoot(nil)
        try? FileManager.default.removeItem(at: drive)
    }

    @discardableResult
    private func makeFile(_ relativePath: String) throws -> MediaItem {
        let url = drive.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return MediaItem(url: url, kind: MediaKind(url: url) ?? .photo, modified: .distantPast, fileSize: 1)
    }

    func testTogglingMarksAndUnmarks() throws {
        let item = try makeFile("DCIM/a.jpg")
        XCTAssertFalse(Favourites.shared.isFavourite(item))

        Favourites.shared.toggle([item])
        XCTAssertTrue(Favourites.shared.isFavourite(item))
        XCTAssertEqual(Favourites.shared.count, 1)

        Favourites.shared.toggle([item])
        XCTAssertFalse(Favourites.shared.isFavourite(item))
        XCTAssertEqual(Favourites.shared.count, 0)
    }

    func testTogglingAMixedSelectionFavouritesAllOfIt() throws {
        let one = try makeFile("a.jpg")
        let two = try makeFile("b.mov")
        Favourites.shared.setFavourite(true, for: [one])

        Favourites.shared.toggle([one, two])
        XCTAssertTrue(Favourites.shared.areAllFavourite([one, two]))

        // Now that they all are, toggling clears them.
        Favourites.shared.toggle([one, two])
        XCTAssertEqual(Favourites.shared.count, 0)
    }

    func testFavouritingTwiceDoesNotDuplicate() throws {
        let item = try makeFile("a.jpg")
        Favourites.shared.setFavourite(true, for: [item])
        Favourites.shared.setFavourite(true, for: [item])
        XCTAssertEqual(Favourites.shared.count, 1)
    }

    func testItemsSkipsFilesThatAreGone() async throws {
        let kept = try makeFile("keep.jpg")
        let removed = try makeFile("gone.jpg")
        Favourites.shared.setFavourite(true, for: [kept, removed])
        try FileManager.default.removeItem(at: removed.url)

        let items = await Favourites.shared.items()
        XCTAssertEqual(items.map(\.name), ["keep.jpg"])
        // The missing one stays on the list, in case the drive is just unplugged.
        XCTAssertEqual(Favourites.shared.count, 2)
    }

    func testItemsAreNewestFavouriteFirst() async throws {
        let first = try makeFile("1.jpg")
        let second = try makeFile("2.jpg")
        Favourites.shared.setFavourite(true, for: [first])
        Favourites.shared.setFavourite(true, for: [second])

        let items = await Favourites.shared.items()
        XCTAssertEqual(items.map(\.name), ["2.jpg", "1.jpg"])
    }

    func testEachDriveKeepsItsOwnList() throws {
        let item = try makeFile("a.jpg")
        Favourites.shared.setFavourite(true, for: [item])

        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        Favourites.shared.setRoot(other)
        XCTAssertEqual(Favourites.shared.count, 0)

        // Back to the first drive: its favourites are still there.
        Favourites.shared.setRoot(drive)
        XCTAssertTrue(Favourites.shared.isFavourite(item))
    }

    func testFilesOutsideTheDriveAreIgnored() {
        let outside = URL(fileURLWithPath: "/somewhere/else/a.jpg")
        let item = MediaItem(url: outside, kind: .photo, modified: .distantPast, fileSize: 1)
        Favourites.shared.setFavourite(true, for: [item])
        XCTAssertEqual(Favourites.shared.count, 0)
        XCTAssertFalse(Favourites.shared.isFavourite(item))
    }
}
