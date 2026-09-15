import XCTest
@testable import Plugroll

final class ExportServiceTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func makeSource(named name: String, bytes: Int) throws -> MediaItem {
        let url = workDirectory.appendingPathComponent(name)
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return MediaItem(url: url, kind: .video, modified: modified, fileSize: bytes)
    }

    func testStagedCopyMatchesSourceAcrossChunks() async throws {
        // Bigger than one 4 MB chunk, and not a multiple of it.
        let item = try makeSource(named: "clip.mov", bytes: 9 * 1024 * 1024 + 123)
        let batch = workDirectory.appendingPathComponent("batch", isDirectory: true)

        let copy = try await ExportService.stageCopy(of: item, index: 0, in: batch)

        XCTAssertEqual(copy.lastPathComponent, "clip.mov")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: item.url))
        let copiedDate = try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(copiedDate, item.modified)
    }

    func testCancelledCopyLeavesNoFile() async throws {
        let item = try makeSource(named: "big.mov", bytes: 16 * 1024 * 1024)
        let batch = workDirectory.appendingPathComponent("batch", isDirectory: true)

        let task = Task { try await ExportService.stageCopy(of: item, index: 0, in: batch) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled copy should throw")
        } catch is CancellationError {
            let partial = batch.appendingPathComponent("0").appendingPathComponent("big.mov")
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        }
    }

    func testDeleteRefusesAFolder() async throws {
        let folder = workDirectory.appendingPathComponent("clip.mov", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = MediaItem(url: folder, kind: .video, modified: .distantPast, fileSize: 0)

        do {
            try await ExportService.deleteFile(item)
            XCTFail("Deleting a folder should be refused")
        } catch ExportError.notAFile {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    func testDeleteRemovesAFile() async throws {
        let item = try makeSource(named: "photo.jpg", bytes: 10)
        try await ExportService.deleteFile(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
    }
}
