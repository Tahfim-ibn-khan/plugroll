import CoreImage
import XCTest
@testable import Plugroll

final class EditRendererTests: XCTestCase {
    private let red = CIColor(red: 1, green: 0, blue: 0)
    private let green = CIColor(red: 0, green: 1, blue: 0)
    private let blue = CIColor(red: 0, green: 0, blue: 1)
    private let white = CIColor(red: 1, green: 1, blue: 1)

    /// 400×200 with a coloured quarter in each corner: red top-left, green top-right,
    /// blue bottom-left, white bottom-right. Core Image's y runs upwards.
    private func quadrants(width: CGFloat = 400, height: CGFloat = 200) -> CIImage {
        let w = width / 2, h = height / 2
        let parts: [(CIColor, CGRect)] = [
            (red, CGRect(x: 0, y: h, width: w, height: h)),
            (green, CGRect(x: w, y: h, width: w, height: h)),
            (blue, CGRect(x: 0, y: 0, width: w, height: h)),
            (white, CGRect(x: w, y: 0, width: w, height: h)),
        ]
        return parts.reduce(CIImage.empty()) { image, part in
            CIImage(color: part.0).cropped(to: part.1).composited(over: image)
        }
    }

    /// The colour a short way in from a corner, as seen on screen.
    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func pixel(_ image: CIImage, _ corner: Corner) -> (r: UInt8, g: UInt8, b: UInt8) {
        let e = image.extent
        let inset: CGFloat = 5
        let x: CGFloat, y: CGFloat
        switch corner {
        case .topLeft: (x, y) = (e.minX + inset, e.maxY - inset - 1)
        case .topRight: (x, y) = (e.maxX - inset - 1, e.maxY - inset - 1)
        case .bottomLeft: (x, y) = (e.minX + inset, e.minY + inset)
        case .bottomRight: (x, y) = (e.maxX - inset - 1, e.minY + inset)
        }
        return pixel(image, at: CGPoint(x: x, y: y))
    }

    private func pixel(_ image: CIImage, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        EditRenderer.context.render(
            image,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return (bytes[0], bytes[1], bytes[2])
    }

    private func assertColour(_ got: (r: UInt8, g: UInt8, b: UInt8), _ want: CIColor, _ message: String, line: UInt = #line) {
        let close = { (a: UInt8, b: CGFloat) in abs(Int(a) - Int(b * 255)) < 30 }
        XCTAssertTrue(
            close(got.r, want.red) && close(got.g, want.green) && close(got.b, want.blue),
            "\(message): got \(got)",
            line: line
        )
    }

    // MARK: - Geometry

    func testQuarterTurnIsCounterClockwise() {
        var edits = Edits()
        edits.quarterTurns = 1
        let out = EditRenderer.apply(edits, to: quadrants())

        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 200, height: 400))
        // Turning left: the top-left corner ends up bottom-left, top-right ends up top-left.
        assertColour(pixel(out, .bottomLeft), red, "red after a left turn")
        assertColour(pixel(out, .topLeft), green, "green after a left turn")
    }

    func testFourQuarterTurnsChangeNothing() {
        var edits = Edits()
        edits.quarterTurns = 4
        let out = EditRenderer.apply(edits, to: quadrants())
        XCTAssertEqual(out.extent.size, CGSize(width: 400, height: 200))
        assertColour(pixel(out, .topLeft), red, "red stays top-left")
    }

    func testFlipMirrorsLeftToRight() {
        var edits = Edits()
        edits.flipped = true
        let out = EditRenderer.apply(edits, to: quadrants())
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 400, height: 200))
        assertColour(pixel(out, .topRight), red, "red moves to the top-right")
        assertColour(pixel(out, .bottomLeft), white, "white moves to the bottom-left")
    }

    func testCropIsMeasuredFromTheTopLeft() {
        var edits = Edits()
        edits.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let out = EditRenderer.apply(edits, to: quadrants())
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 200, height: 100))
        assertColour(pixel(out, .bottomRight), red, "only the red quarter is left")
        assertColour(pixel(out, .topLeft), red, "only the red quarter is left")
    }

    func testCropOfTheBottomRight() {
        var edits = Edits()
        edits.crop = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let out = EditRenderer.apply(edits, to: quadrants())
        XCTAssertEqual(out.extent.size, CGSize(width: 200, height: 100))
        assertColour(pixel(out, .topLeft), white, "only the white quarter is left")
    }

    func testStraightenShrinksToHideCorners() {
        let size = CGSize(width: 400, height: 200)
        let scale = EditRenderer.straightenScale(for: size, degrees: 30)
        XCTAssertEqual(scale, 200 / (400 * 0.5 + 200 * cos(.pi / 6)), accuracy: 0.0001)

        var edits = Edits()
        edits.straighten = 30
        let out = EditRenderer.apply(edits, to: quadrants())
        XCTAssertEqual(out.extent.origin, .zero)
        XCTAssertEqual(out.extent.width, (400 * scale).rounded(.down))
        XCTAssertEqual(out.extent.height, (200 * scale).rounded(.down))
        XCTAssertEqual(EditRenderer.outputSize(for: size, edits: edits), out.extent.size)
    }

    func testStraightenLeavesNoTransparentCorners() {
        var edits = Edits()
        edits.straighten = -20
        let out = EditRenderer.apply(edits, to: CIImage(color: red).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300)))
        for corner in [Corner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            assertColour(pixel(out, corner), red, "corner \(corner) is picture, not empty")
        }
    }

    func testCropAppliesAfterTurning() {
        var edits = Edits()
        edits.quarterTurns = 1
        edits.crop = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let out = EditRenderer.apply(edits, to: quadrants())
        // Turned: 200 wide, 400 tall, green over white on top. The top half is kept.
        XCTAssertEqual(out.extent.size, CGSize(width: 200, height: 200))
        assertColour(pixel(out, .topLeft), green, "green on the kept top-left")
        assertColour(pixel(out, .topRight), white, "white on the kept top-right")
    }

    func testCropCanBeSkippedForTheCropScreen() {
        var edits = Edits()
        edits.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let out = EditRenderer.apply(edits, to: quadrants(), applyCrop: false)
        XCTAssertEqual(out.extent.size, CGSize(width: 400, height: 200))
        XCTAssertEqual(EditRenderer.outputSize(for: CGSize(width: 400, height: 200), edits: edits, applyCrop: false), out.extent.size)
    }

    // MARK: - Colour

    private func grey(_ level: CGFloat = 0.5) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    private func centre(_ image: CIImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        pixel(image, at: CGPoint(x: image.extent.midX, y: image.extent.midY))
    }

    func testWarmthGoesYellowAndCoolnessBlue() {
        var edits = Edits()
        edits.set(.warmth, to: 1)
        let warm = centre(EditRenderer.apply(edits, to: grey()))
        XCTAssertGreaterThan(Int(warm.r), Int(warm.b) + 10, "warmer is more red/yellow than blue: \(warm)")

        edits.set(.warmth, to: -1)
        let cool = centre(EditRenderer.apply(edits, to: grey()))
        XCTAssertGreaterThan(Int(cool.b), Int(cool.r) + 10, "cooler is more blue: \(cool)")
    }

    func testExposureAndBrightnessGoTheRightWay() {
        let base = centre(grey()).r
        for adjustment in [Adjustment.exposure, .brightness] {
            var edits = Edits()
            edits.set(adjustment, to: 0.5)
            XCTAssertGreaterThan(centre(EditRenderer.apply(edits, to: grey())).r, base, "\(adjustment) up is brighter")
            edits.set(adjustment, to: -0.5)
            XCTAssertLessThan(centre(EditRenderer.apply(edits, to: grey())).r, base, "\(adjustment) down is darker")
        }
    }

    func testShadowsLiftDarkTones() {
        let dark = grey(0.2)
        let base = centre(dark).r
        var edits = Edits()
        edits.set(.shadows, to: 1)
        XCTAssertGreaterThan(centre(EditRenderer.apply(edits, to: dark)).r, base)
    }

    func testSaturationDownMakesGrey() {
        let colour = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        var edits = Edits()
        edits.set(.saturation, to: -1)
        let out = centre(EditRenderer.apply(edits, to: colour))
        XCTAssertLessThan(abs(Int(out.r) - Int(out.g)), 10, "no colour left: \(out)")
    }

    func testMonoFilterIsGrey() {
        let colour = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        var edits = Edits()
        edits.filter = .mono
        let out = centre(EditRenderer.apply(edits, to: colour))
        XCTAssertLessThan(abs(Int(out.r) - Int(out.b)), 10, "mono has no colour: \(out)")
    }

    func testEveryLookKeepsThePictureSize() {
        let image = quadrants()
        for preset in FilterPreset.allCases {
            var edits = Edits()
            edits.filter = preset
            for adjustment in Adjustment.allCases { edits.set(adjustment, to: 0.6) }
            XCTAssertEqual(EditRenderer.apply(edits, to: image).extent, image.extent, "\(preset) keeps the size")
        }
    }

    func testSliderValuesAreClampedAndZeroIsDropped() {
        var edits = Edits()
        edits.set(.sharpness, to: -1)
        XCTAssertEqual(edits.value(.sharpness), 0)
        XCTAssertTrue(edits.isUnchanged, "a zero value leaves nothing behind")
        edits.set(.contrast, to: 5)
        XCTAssertEqual(edits.value(.contrast), 1)
    }
}
