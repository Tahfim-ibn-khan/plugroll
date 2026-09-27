import XCTest
@testable import Plugroll

final class CleanupFinderTests: XCTestCase {
    private func item(_ name: String, size: Int = 100, minutes: Double = 0, kind: MediaKind = .photo) -> MediaItem {
        MediaItem(
            url: URL(fileURLWithPath: "/drive/\(name)"),
            kind: kind,
            modified: Date(timeIntervalSince1970: 1_600_000_000 + minutes * 60),
            fileSize: size
        )
    }

    func testDuplicatesNeedTheSameSizeAndContent() {
        let a = item("a.jpg", size: 10), b = item("b.jpg", size: 10), c = item("c.jpg", size: 10)
        let d = item("d.jpg", size: 99), empty1 = item("e.jpg", size: 0), empty2 = item("f.jpg", size: 0)

        let candidates = CleanupFinder.sameSizeCandidates([a, b, c, d, empty1, empty2])
        XCTAssertEqual(candidates.count, 1, "empty files and unique sizes aren't worth hashing")
        XCTAssertEqual(Set(candidates[0].map(\.name)), ["a.jpg", "b.jpg", "c.jpg"])

        let groups = CleanupFinder.duplicateGroups([a, b, c], hashes: [a.url: "x", b.url: "x", c.url: "y"])
        XCTAssertEqual(groups.map { Set($0.map(\.name)) }, [["a.jpg", "b.jpg"]])
    }

    func testSimilarPhotosAreLinkedWithinTheTimeWindow() {
        let a = item("a.jpg", minutes: 0), b = item("b.jpg", minutes: 1), c = item("c.jpg", minutes: 2)
        let far = item("far.jpg", minutes: 600)
        // Everything looks alike; only time keeps `far` apart. a~b and b~c chain into one group.
        let distances: [Set<String>: Float] = [["a.jpg", "b.jpg"]: 0.1, ["b.jpg", "c.jpg"]: 0.2]
        let groups = CleanupFinder.similarPhotoGroups([far, c, a, b]) { x, y in
            (distances[[x.name, y.name]] ?? (x.name == "far.jpg" || y.name == "far.jpg" ? 0 : 0.9)) <= 0.3
        }
        XCTAssertEqual(groups.map { $0.map(\.name) }, [["a.jpg", "b.jpg", "c.jpg"]])
    }

    func testDifferentPhotosStayApart() {
        let a = item("a.jpg", minutes: 0), b = item("b.jpg", minutes: 1)
        let groups = CleanupFinder.similarPhotoGroups([a, b]) { _, _ in false }
        XCTAssertTrue(groups.isEmpty)
    }

    func testSimilarVideosMustBeAboutTheSameLength() {
        let a = item("a.mov", kind: .video), b = item("b.mov", minutes: 9999, kind: .video)
        let c = item("c.mov", kind: .video)
        let groups = CleanupFinder.similarVideoGroups(
            [a, b, c],
            durations: [a.url: 30, b.url: 30.4, c.url: 45]
        ) { _, _ in true }
        XCTAssertEqual(groups.map { Set($0.map(\.name)) }, [["a.mov", "b.mov"]])
    }

    func testKeeperPrefersFavouriteThenPixelsThenSize() {
        let small = item("IMG_1.jpg", size: 100), big = item("IMG_1 copy.jpg", size: 200)
        let facts = [
            small.url: MediaFacts(pixelWidth: 4000, pixelHeight: 3000),
            big.url: MediaFacts(pixelWidth: 1000, pixelHeight: 750),
        ]
        XCTAssertEqual(CleanupFinder.keeper(of: [small, big], facts: facts, isFavourite: { _ in false }), small,
                       "more pixels beat a bigger file")
        XCTAssertEqual(CleanupFinder.keeper(of: [small, big], facts: [:], isFavourite: { _ in false }), big,
                       "without sizes, the bigger file")
        XCTAssertEqual(CleanupFinder.keeper(of: [small, big], facts: facts, isFavourite: { $0 == big }), big,
                       "a favourite always stays")

        let original = item("IMG_2.jpg", size: 50, minutes: 0), copy = item("IMG_2 (1).jpg", size: 50, minutes: 5)
        XCTAssertEqual(CleanupFinder.keeper(of: [copy, original], facts: [:], isFavourite: { _ in false }), original,
                       "same file: the older one")
    }

    func testLookAlikesNeedBothChecksToAgree() {
        let t = CleanupFinder.similarPhotoDistance
        XCTAssertTrue(CleanupFinder.looksAlike(featureDistance: t / 2, hashDistance: 4, threshold: t))
        XCTAssertFalse(CleanupFinder.looksAlike(featureDistance: t / 2, hashDistance: 40, threshold: t),
                       "a feature print alone can't group pictures the hash calls different")
        XCTAssertFalse(CleanupFinder.looksAlike(featureDistance: t * 2, hashDistance: 0, threshold: t))
        XCTAssertTrue(CleanupFinder.looksAlike(featureDistance: nil, hashDistance: 3, threshold: t))
        XCTAssertFalse(CleanupFinder.looksAlike(featureDistance: nil, hashDistance: 15, threshold: t))
        XCTAssertFalse(CleanupFinder.looksAlike(featureDistance: 0, hashDistance: nil, threshold: t))
    }

    func testAGroupNeverLosesEveryFile() {
        let a = item("a.jpg", size: 10), b = item("b.jpg", size: 10)
        let group = CleanupFinder.makeGroups([[a, b]], facts: [:], isFavourite: { _ in false })[0]
        XCTAssertTrue(group.allows(marking: [a.url]))
        XCTAssertFalse(group.allows(marking: [a.url, b.url]))
        XCTAssertEqual(group.reclaimableBytes, 10)
    }

    func testBigAndLargestLists() {
        let big = item("big.mov", size: CleanupFinder.bigVideoBytes, kind: .video)
        let smallVideo = item("small.mov", size: 10, kind: .video)
        let hugePhoto = item("huge.tif", size: CleanupFinder.bigVideoBytes * 2)
        XCTAssertEqual(CleanupFinder.bigVideos([smallVideo, hugePhoto, big]), [big], "videos only")
        XCTAssertEqual(CleanupFinder.largest([smallVideo, hugePhoto, big], limit: 2), [hugePhoto, big])
    }

    func testDarkIsNotAlsoCalledBlurry() {
        let dark = MediaFacts(blurScore: 1, brightness: 0.01)
        let blurry = MediaFacts(blurScore: 1, brightness: 0.5)
        let sharp = MediaFacts(blurScore: 500, brightness: 0.5)
        XCTAssertTrue(CleanupFinder.isDark(dark))
        XCTAssertFalse(CleanupFinder.isBlurry(dark))
        XCTAssertTrue(CleanupFinder.isBlurry(blurry))
        XCTAssertFalse(CleanupFinder.isBlurry(sharp))
    }
}
