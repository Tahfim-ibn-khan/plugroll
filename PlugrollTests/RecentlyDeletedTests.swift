import XCTest
@testable import Plugroll

final class RecentlyDeletedTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentlyDeletedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ path: String, bytes: Int = 100) throws -> MediaItem {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return MediaItem(url: url, kind: MediaKind(url: url)!, modified: Date(timeIntervalSince1970: 1_600_000_000), fileSize: bytes)
    }

    func testTrashThenRestorePutsTheFileBack() async throws {
        let item = try makeFile("Trip/IMG_1.jpg", bytes: 321)
        let entry = try await RecentlyDeleted.trash(item, root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(entry.originalPath, "Trip/IMG_1.jpg")
        XCTAssertEqual(entry.name, "IMG_1.jpg")
        let entries = try await RecentlyDeleted.entries(root: root)
        XCTAssertEqual(entries, [entry])
        let size = await RecentlyDeleted.totalSize(root: root)
        XCTAssertEqual(size, 321)

        // Hidden from folder listings and scans.
        let listing = try await FolderScanner.list(root)
        XCTAssertEqual(listing.folders.map(\.name), ["Trip"])

        let restored = try await RecentlyDeleted.restore([entry], root: root)
        XCTAssertEqual(restored.map(\.url.path), [item.url.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        let left = try await RecentlyDeleted.entries(root: root)
        XCTAssertTrue(left.isEmpty)
    }

    func testRestoreDoesNotOverwriteANewFileWithTheSameName() async throws {
        let item = try makeFile("IMG_2.jpg")
        let entry = try await RecentlyDeleted.trash(item, root: root)
        _ = try makeFile("IMG_2.jpg", bytes: 5)

        let restored = try await RecentlyDeleted.restore([entry], root: root)
        XCTAssertEqual(restored.first?.name, "IMG_2 (Restored).jpg")
        XCTAssertEqual(try Data(contentsOf: item.url).count, 5, "the newer file is untouched")
    }

    func testSameNamesFromDifferentFoldersDontCollide() async throws {
        let a = try makeFile("A/IMG_3.jpg", bytes: 10)
        let b = try makeFile("B/IMG_3.jpg", bytes: 20)
        _ = try await RecentlyDeleted.trash([a, b], root: root)
        let entries = try await RecentlyDeleted.entries(root: root)
        XCTAssertEqual(Set(entries.map(\.originalPath)), ["A/IMG_3.jpg", "B/IMG_3.jpg"])
    }

    func testPurgeRemovesOnlyFilesOlderThanThirtyDays() async throws {
        let old = try makeFile("old.jpg")
        let recent = try makeFile("recent.jpg")
        let now = Date()
        let oldEntry = try RecentlyDeleted.moveIn(
            file: old.url, recordingAs: old.url, root: root, modified: old.modified, size: old.fileSize,
            now: now.addingTimeInterval(-31 * 86_400)
        )
        let recentEntry = try RecentlyDeleted.moveIn(
            file: recent.url, recordingAs: recent.url, root: root, modified: recent.modified, size: recent.fileSize,
            now: now.addingTimeInterval(-2 * 86_400)
        )
        XCTAssertEqual(recentEntry.daysLeft(now: now), 28)

        let purged = try await RecentlyDeleted.purge(root: root, now: now)
        XCTAssertEqual(purged.map(\.id), [oldEntry.id])
        let left = try await RecentlyDeleted.entries(root: root)
        XCTAssertEqual(left.map(\.id), [recentEntry.id])
        let oldFolder = RecentlyDeleted.folder(in: root).appendingPathComponent(oldEntry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path))
    }

    func testEmptyDeletesEverything() async throws {
        _ = try await RecentlyDeleted.trash([try makeFile("1.jpg"), try makeFile("2.mov")], root: root)
        try await RecentlyDeleted.empty(root: root)
        let left = try await RecentlyDeleted.entries(root: root)
        XCTAssertTrue(left.isEmpty)
        let size = await RecentlyDeleted.totalSize(root: root)
        XCTAssertEqual(size, 0)
    }

    func testAFolderIsNeverTrashed() async throws {
        let folder = root.appendingPathComponent("clip.mov", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fake = MediaItem(url: folder, kind: .video, modified: .distantPast, fileSize: 0)
        do {
            _ = try await RecentlyDeleted.trash(fake, root: root)
            XCTFail("a folder must not be moved")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
}
