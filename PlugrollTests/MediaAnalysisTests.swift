import CoreGraphics
import CryptoKit
import UIKit
import XCTest
@testable import Plugroll

final class MediaAnalysisTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 400×300 picture drawn by `draw`, on a white background.
    private func image(_ draw: (CGContext) -> Void) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            draw(context.cgContext)
        }.cgImage!
    }

    private func checkerboard(_ context: CGContext) {
        context.setFillColor(UIColor.black.cgColor)
        for row in 0..<30 {
            for column in 0..<40 where (row + column).isMultiple(of: 2) {
                context.fill(CGRect(x: column * 10, y: row * 10, width: 10, height: 10))
            }
        }
    }

    private func blurred(_ image: CGImage, radius: Double) -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent)!
    }

    func testSharpScoresHighAndBlurredLow() {
        let sharp = image(checkerboard)
        let soft = blurred(sharp, radius: 12)
        let sharpScore = MediaAnalyzer.sharpnessAndBrightness(of: sharp).sharpness
        let softScore = MediaAnalyzer.sharpnessAndBrightness(of: soft).sharpness
        XCTAssertGreaterThan(sharpScore, CleanupFinder.blurThreshold, "sharp: \(sharpScore)")
        XCTAssertLessThan(softScore, CleanupFinder.blurThreshold, "blurred: \(softScore)")
    }

    func testDarkPictureIsFlagged() {
        let dark = image { context in
            context.setFillColor(UIColor(white: 0.02, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let brightness = MediaAnalyzer.sharpnessAndBrightness(of: dark).brightness
        XCTAssertTrue(CleanupFinder.isDark(MediaFacts(blurScore: 0, brightness: brightness)), "brightness \(brightness)")
        let light = MediaAnalyzer.sharpnessAndBrightness(of: image(checkerboard)).brightness
        XCTAssertEqual(light, 0.5, accuracy: 0.05)
    }

    func testScreenshotDetection() {
        XCTAssertTrue(MediaAnalyzer.looksLikeScreenshot(name: "IMG_1.PNG", userComment: "Screenshot", pixelWidth: 10, pixelHeight: 10))
        XCTAssertTrue(MediaAnalyzer.looksLikeScreenshot(name: "Screenshot 2024-01-01.jpg", userComment: nil, pixelWidth: 0, pixelHeight: 0))
        XCTAssertTrue(MediaAnalyzer.looksLikeScreenshot(name: "IMG_2.png", userComment: nil, pixelWidth: 2556, pixelHeight: 1179))
        XCTAssertFalse(MediaAnalyzer.looksLikeScreenshot(name: "IMG_2.jpg", userComment: nil, pixelWidth: 1179, pixelHeight: 2556),
                       "a JPEG at screen size is a photo")
        XCTAssertFalse(MediaAnalyzer.looksLikeScreenshot(name: "IMG_3.png", userComment: nil, pixelWidth: 4032, pixelHeight: 3024))
    }

    func testContentHashMatchesSHA256() throws {
        let url = folder.appendingPathComponent("file.bin")
        // Several chunks' worth.
        let data = Data((0..<(9 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try data.write(to: url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try MediaAnalyzer.sha256(of: url), expected)
    }

    func testDifferenceHashTellsLookAlikesFromDifferentPictures() {
        let scene = image { context in
            context.setFillColor(UIColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(x: 60, y: 60, width: 160, height: 160))
            context.setFillColor(UIColor.systemBlue.cgColor)
            context.fill(CGRect(x: 240, y: 40, width: 120, height: 200))
        }
        // A retake: shifted a little and slightly lighter.
        let retake = image { context in
            context.setFillColor(UIColor.systemRed.withAlphaComponent(0.9).cgColor)
            context.fillEllipse(in: CGRect(x: 64, y: 62, width: 160, height: 160))
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.9).cgColor)
            context.fill(CGRect(x: 244, y: 42, width: 120, height: 200))
        }
        let other = image { context in
            context.setFillColor(UIColor.systemGreen.cgColor)
            context.fill(CGRect(x: 0, y: 150, width: 400, height: 150))
            context.setFillColor(UIColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: 280, y: 20, width: 100, height: 100))
        }
        let a = MediaAnalyzer.differenceHash(of: scene)
        let near = (a ^ MediaAnalyzer.differenceHash(of: retake)).nonzeroBitCount
        let far = (a ^ MediaAnalyzer.differenceHash(of: other)).nonzeroBitCount
        XCTAssertLessThanOrEqual(near, CleanupFinder.hashOnlyBits, "retake differs in \(near) bits")
        XCTAssertGreaterThan(far, CleanupFinder.similarHashBits, "different picture differs in \(far) bits")
    }

    func testDriveIndexFindsMediaAndFolderSizes() throws {
        let files = FileManager.default
        func write(_ path: String, _ bytes: Int) throws {
            let url = folder.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        try write("Trips/Rome/IMG_1.jpg", 100)
        try write("Trips/IMG_2.mov", 300)
        try write("Trips/notes.txt", 50)
        try write("Work/IMG_3.png", 40)
        try write("loose.jpg", 7)
        try write(".Plugroll Recently Deleted/x/IMG_9.jpg", 999)

        let index = try DriveIndex.build(root: folder)
        XCTAssertEqual(Set(index.items.map(\.name)), ["IMG_1.jpg", "IMG_2.mov", "IMG_3.png", "loose.jpg"],
                       "hidden Recently Deleted is left out")
        let sizes = Dictionary(uniqueKeysWithValues: index.folderSizes.map { ($0.name, ($0.bytes, $0.mediaCount)) })
        XCTAssertEqual(sizes["Trips"]?.0, 450)
        XCTAssertEqual(sizes["Trips"]?.1, 2)
        XCTAssertEqual(sizes["Work"]?.0, 40)
        XCTAssertEqual(sizes["Files at Top Level"]?.0, 7)
        XCTAssertEqual(index.folderSizes.first?.name, "Trips", "biggest first")
    }
}
