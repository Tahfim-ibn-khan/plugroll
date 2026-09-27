import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Plugroll

final class EditExporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Fixtures

    /// Raw pixels: red top-left, green top-right, blue bottom-left, white bottom-right.
    private func quadrantPixels(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let top = y < height / 2, left = x < width / 2
                let (r, g, b): (UInt8, UInt8, UInt8) =
                    top && left ? (255, 0, 0) : top ? (0, 255, 0) : left ? (0, 0, 255) : (255, 255, 255)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        return bytes
    }

    private func quadrantCGImage(width: Int, height: Int) -> CGImage {
        let bytes = quadrantPixels(width: width, height: height)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// A JPEG with a date, a place and the given EXIF orientation.
    private func writeJPEG(named name: String, orientation: Int = 1) throws -> MediaItem {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [String: Any] = [
            kCGImagePropertyOrientation as String: orientation,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2024:05:06 07:08:09",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 23.8,
                kCGImagePropertyGPSLatitudeRef as String: "N",
            ],
        ]
        CGImageDestinationAddImage(destination, quadrantCGImage(width: 400, height: 200), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return MediaItem(url: url, kind: .photo, modified: values.contentModificationDate!, fileSize: values.fileSize!)
    }

    private func decoded(_ url: URL) -> (image: CIImage, properties: [String: Any]) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])!
        return (image, properties)
    }

    /// Colour near a corner, as seen on screen.
    private func colour(of image: CIImage, top: Bool, left: Bool) -> (r: Int, g: Int, b: Int) {
        let e = image.extent
        let point = CGPoint(
            x: left ? e.minX + 4 : e.maxX - 5,
            y: top ? e.maxY - 5 : e.minY + 4
        )
        var bytes = [UInt8](repeating: 0, count: 4)
        EditRenderer.context.render(
            image, toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 180 && c.g < 90 && c.b < 90 }
    private func isGreen(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.g > 180 && c.r < 90 && c.b < 90 }

    // MARK: - Photos

    func testPhotoKeepsMetadataAndBakesInOrientation() async throws {
        // Orientation 6: stored sideways, shown turned a quarter clockwise, so 200×400.
        let item = try writeJPEG(named: "IMG_0001.jpg", orientation: 6)
        let batch = try ExportService.makeBatchDirectory()
        defer { ExportService.remove(batch) }

        let output = try await EditExporter.renderPhoto(item, edits: Edits(), autoFilters: [], in: batch)
        let (image, properties) = decoded(output)

        XCTAssertEqual(output.pathExtension, "jpg")
        XCTAssertEqual(image.extent.size, CGSize(width: 200, height: 400), "the turn is baked into the pixels")
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 1)
        // The stored top-left (red) shows top-right after a clockwise quarter turn.
        XCTAssertTrue(isRed(colour(of: image, top: true, left: false)), "\(colour(of: image, top: true, left: false))")

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2024:05:06 07:08:09")
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude as String] as? Double ?? 0, 23.8, accuracy: 0.001)
    }

    func testPhotoCropIsRenderedAtFullSize() async throws {
        let item = try writeJPEG(named: "crop.jpg")
        let batch = try ExportService.makeBatchDirectory()
        defer { ExportService.remove(batch) }

        var edits = Edits()
        edits.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let output = try await EditExporter.renderPhoto(item, edits: edits, autoFilters: [], in: batch)
        let (image, _) = decoded(output)

        XCTAssertEqual(image.extent.size, CGSize(width: 200, height: 100))
        XCTAssertTrue(isGreen(colour(of: image, top: true, left: true)), "only the green quarter is left")
    }

    func testSavingACopyPutsItNextToTheOriginal() async throws {
        let item = try writeJPEG(named: "IMG_0002.jpg")
        let batch = try ExportService.makeBatchDirectory()
        defer { ExportService.remove(batch) }

        var edits = Edits()
        edits.quarterTurns = 1
        let rendered = try await EditExporter.renderPhoto(item, edits: edits, autoFilters: [], in: batch)
        let result = try await EditExporter.save(rendered, for: item, to: .copyOnDrive)

        guard case .copy(let copy) = result else { return XCTFail("expected a copy, got \(result)") }
        XCTAssertEqual(copy.name, "IMG_0002 (Edited).jpg")
        XCTAssertEqual(copy.url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(decoded(copy.url).image.extent.size, CGSize(width: 200, height: 400))
        XCTAssertEqual(decoded(item.url).image.extent.size, CGSize(width: 400, height: 200), "the original is untouched")
    }

    func testEditedNamesDontOverwriteEachOther() {
        let taken: Set<String> = ["IMG (Edited).jpg", "IMG (Edited 2).jpg"]
        let url = EditExporter.uniqueEditedURL(in: folder, stem: "IMG", ext: "jpg") {
            taken.contains($0.lastPathComponent)
        }
        XCTAssertEqual(url.lastPathComponent, "IMG (Edited 3).jpg")
    }

    func testReplacingSwapsTheFileAndLeavesNothingBehind() async throws {
        let item = try writeJPEG(named: "IMG_0003.jpg")
        let batch = try ExportService.makeBatchDirectory()
        defer { ExportService.remove(batch) }

        var edits = Edits()
        edits.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let rendered = try await EditExporter.renderPhoto(item, edits: edits, autoFilters: [], in: batch)
        let result = try await EditExporter.save(rendered, for: item, to: .replaceOriginal)

        guard case .replaced(let updated) = result else { return XCTFail("expected a replace, got \(result)") }
        XCTAssertEqual(updated.url, item.url)
        XCTAssertNotEqual(updated.cacheKey, item.cacheKey, "caches see it as a new file")
        XCTAssertEqual(decoded(item.url).image.extent.size, CGSize(width: 200, height: 200))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, ["IMG_0003.jpg"], "no hidden temporary files remain")
    }

    func testFormatsThatChangeCantReplaceTheOriginal() {
        func item(_ name: String, _ kind: MediaKind) -> MediaItem {
            MediaItem(url: folder.appendingPathComponent(name), kind: kind, modified: .distantPast, fileSize: 0)
        }
        XCTAssertTrue(EditExporter.canReplaceOriginal(item("a.JPG", .photo)))
        XCTAssertTrue(EditExporter.canReplaceOriginal(item("a.heic", .photo)))
        XCTAssertFalse(EditExporter.canReplaceOriginal(item("a.CR3", .photo)))
        XCTAssertEqual(EditExporter.outputExtension(for: item("a.dng", .photo)), "jpg")
        XCTAssertTrue(EditExporter.canReplaceOriginal(item("a.mov", .video)))
        XCTAssertFalse(EditExporter.canReplaceOriginal(item("a.avi", .video)))
    }

    // MARK: - Videos

    /// A 2-second 64×32 video of the four colours, flagged to be shown turned a quarter
    /// clockwise, the way phones store portrait video.
    private func writePortraitVideo() async throws -> URL {
        let url = folder.appendingPathComponent("portrait.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 32,
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 32,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let rgba = quadrantPixels(width: 64, height: 32)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<32 {
                for x in 0..<64 {
                    let i = (y * 64 + x) * 4, o = y * rowBytes + x * 4
                    base[o] = rgba[i + 2]; base[o + 1] = rgba[i + 1]; base[o + 2] = rgba[i]; base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    /// A frame as it's meant to be watched, rotation applied.
    private func frame(of url: URL, at seconds: Double) async throws -> CIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        return CIImage(cgImage: image)
    }

    private func export(_ source: URL, _ edits: Edits) async throws -> URL {
        let batch = try ExportService.makeBatchDirectory()
        addTeardownBlock { ExportService.remove(batch) }
        return try await EditExporter.render(
            videoFrom: AVURLAsset(url: source), edits: edits, to: batch, ext: "mov", progress: { _ in }
        )
    }

    func testPortraitVideoStaysUprightWhenEdited() async throws {
        let source = try await writePortraitVideo()
        let sourceSize = try await VideoEditing.orientedSize(of: AVURLAsset(url: source))
        XCTAssertEqual(sourceSize, CGSize(width: 32, height: 64), "shown portrait")

        var edits = Edits()
        edits.set(.contrast, to: 0.1) // any edit, so every frame goes through the renderer
        let output = try await export(source, edits)

        let outputSize = try await VideoEditing.orientedSize(of: AVURLAsset(url: output))
        XCTAssertEqual(outputSize, CGSize(width: 32, height: 64), "still portrait")

        // Every corner shows the same colour before and after: four different colours,
        // so any turn or mirror would show up.
        let original = try await frame(of: source, at: 0.5)
        let edited = try await frame(of: output, at: 0.5)
        var seen = Set<String>()
        for (top, left) in [(true, true), (true, false), (false, true), (false, false)] {
            let before = colour(of: original, top: top, left: left)
            let after = colour(of: edited, top: top, left: left)
            let label = "\(before.r > 128)\(before.g > 128)\(before.b > 128)"
            seen.insert(label)
            XCTAssertEqual(label, "\(after.r > 128)\(after.g > 128)\(after.b > 128)",
                           "corner top:\(top) left:\(left): before \(before), after \(after)")
        }
        XCTAssertEqual(seen.count, 4, "the fixture really has four different corners")
    }

    func testVideoTrimTurnAndMute() async throws {
        let source = try await writePortraitVideo()
        var edits = Edits()
        edits.trimStart = 0.5
        edits.trimEnd = 1.5
        edits.quarterTurns = 1
        edits.muted = true
        let output = try await export(source, edits)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.15, "trimmed to one second")
        let size = try await VideoEditing.orientedSize(of: asset)
        XCTAssertEqual(size, CGSize(width: 64, height: 32), "a left turn makes it landscape")
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }

    func testVideoCropGivesAnEvenSize() async throws {
        let source = try await writePortraitVideo()
        var edits = Edits()
        edits.crop = CGRect(x: 0, y: 0, width: 0.53, height: 0.5)
        let output = try await export(source, edits)
        let size = try await VideoEditing.orientedSize(of: AVURLAsset(url: output))
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size, CGSize(width: 16, height: 32))
    }

    // MARK: - Trim only, and keeping the original

    func testTrimOnlyEditsAreRecognised() {
        var edits = Edits()
        edits.trimStart = 1
        edits.trimEnd = 3
        edits.muted = true
        XCTAssertTrue(edits.isTrimOnly)
        edits.set(.contrast, to: 0.2)
        XCTAssertFalse(edits.isTrimOnly)
        var turned = Edits()
        turned.quarterTurns = 1
        XCTAssertFalse(turned.isTrimOnly)
    }

    func testTrimOnlyKeepsTheFramesAsTheyAre() async throws {
        let source = try await writePortraitVideo()
        var edits = Edits()
        edits.trimStart = 0.5
        edits.trimEnd = 1.5
        let output = try await export(source, edits)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.15, "trimmed to one second")
        let size = try await VideoEditing.orientedSize(of: asset)
        XCTAssertEqual(size, CGSize(width: 32, height: 64), "still portrait")
        // Passed through, not re-encoded: the stored frames keep their size and turn.
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let natural = try await track.load(.naturalSize)
        XCTAssertEqual(natural, CGSize(width: 64, height: 32))
    }

    func testReplacingCanKeepTheOriginalInRecentlyDeleted() async throws {
        let item = try writeJPEG(named: "IMG_0004.jpg")
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.url.path)
        let original = MediaItem(url: item.url, kind: .photo, modified: date, fileSize: item.fileSize)
        let before = try Data(contentsOf: item.url)
        let batch = try ExportService.makeBatchDirectory()
        defer { ExportService.remove(batch) }

        var edits = Edits()
        edits.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let rendered = try await EditExporter.renderPhoto(original, edits: edits, autoFilters: [], in: batch)
        let result = try await EditExporter.save(
            rendered,
            for: original,
            to: .replaceOriginal,
            options: .init(recentlyDeletedRoot: folder, keepsDate: true)
        )

        guard case .replaced(let updated) = result else { return XCTFail("expected a replace, got \(result)") }
        XCTAssertEqual(updated.modified, date, "keeps its place in the grid")
        let entries = try await RecentlyDeleted.entries(root: folder)
        XCTAssertEqual(entries.map(\.originalPath), ["IMG_0004.jpg"])
        let kept = try XCTUnwrap(RecentlyDeleted.item(for: entries[0], root: folder))
        XCTAssertEqual(try Data(contentsOf: kept.url), before, "the untouched original waits in Recently Deleted")

        let visible = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(visible, ["IMG_0004.jpg"], "no other files show in the folder")
    }
}
