import CoreGraphics
import Foundation

/// The light and colour sliders, like the ones in Photos. Each value runs over `range`,
/// with 0 meaning unchanged.
enum Adjustment: String, CaseIterable, Identifiable, Sendable {
    case exposure
    case brightness
    case contrast
    case highlights
    case shadows
    case saturation
    case vibrance
    case warmth
    case sharpness
    case vignette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: return "Exposure"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .saturation: return "Saturation"
        case .vibrance: return "Vibrance"
        case .warmth: return "Warmth"
        case .sharpness: return "Sharpness"
        case .vignette: return "Vignette"
        }
    }

    var symbol: String {
        switch self {
        case .exposure: return "plusminus.circle"
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .highlights: return "circle.tophalf.filled"
        case .shadows: return "circle.bottomhalf.filled"
        case .saturation: return "drop.halffull"
        case .vibrance: return "sparkles"
        case .warmth: return "thermometer.medium"
        case .sharpness: return "triangle"
        case .vignette: return "circle.dashed"
        }
    }

    /// Sharpness and vignette only add, so they start at 0; the rest go both ways.
    var range: ClosedRange<Double> {
        switch self {
        case .sharpness, .vignette: return 0...1
        default: return -1...1
        }
    }
}

/// One-tap looks, named like the Photos filters they resemble.
enum FilterPreset: String, CaseIterable, Identifiable, Sendable {
    case original
    case vivid
    case vividWarm
    case vividCool
    case dramatic
    case mono
    case silvertone
    case noir
    case chrome
    case fade
    case instant
    case process
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .vivid: return "Vivid"
        case .vividWarm: return "Vivid Warm"
        case .vividCool: return "Vivid Cool"
        case .dramatic: return "Dramatic"
        case .mono: return "Mono"
        case .silvertone: return "Silvertone"
        case .noir: return "Noir"
        case .chrome: return "Chrome"
        case .fade: return "Fade"
        case .instant: return "Instant"
        case .process: return "Process"
        case .transfer: return "Transfer"
        }
    }
}

/// Shapes the crop box can be held to.
enum AspectPreset: String, CaseIterable, Identifiable, Sendable {
    case freeform
    case original
    case square
    case landscape16x9
    case landscape4x3
    case landscape3x2
    case portrait9x16
    case portrait3x4
    case portrait2x3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeform: return "Freeform"
        case .original: return "Original"
        case .square: return "Square"
        case .landscape16x9: return "16:9"
        case .landscape4x3: return "4:3"
        case .landscape3x2: return "3:2"
        case .portrait9x16: return "9:16"
        case .portrait3x4: return "3:4"
        case .portrait2x3: return "2:3"
        }
    }

    /// Width over height in pixels, or nil for freeform. `imageSize` is the picture
    /// being cropped, which "Original" follows.
    func ratio(for imageSize: CGSize) -> CGFloat? {
        switch self {
        case .freeform: return nil
        case .original: return imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        case .square: return 1
        case .landscape16x9: return 16.0 / 9
        case .landscape4x3: return 4.0 / 3
        case .landscape3x2: return 3.0 / 2
        case .portrait9x16: return 9.0 / 16
        case .portrait3x4: return 3.0 / 4
        case .portrait2x3: return 2.0 / 3
        }
    }
}

/// Everything the editor can change. Applied in this order: flip and quarter turns,
/// straighten, crop, auto-enhance, adjustments, filter.
struct Edits: Equatable, Sendable {
    /// Counter-clockwise quarter turns, like the rotate button in Photos.
    var quarterTurns = 0
    /// Mirrored left to right.
    var flipped = false
    /// Degrees, -45...45. Positive turns the picture clockwise.
    var straighten: Double = 0
    /// The kept part, as fractions of the turned and straightened picture, measured from
    /// its top-left corner.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var aspect: AspectPreset = .freeform
    var autoEnhance = false
    var adjustments: [Adjustment: Double] = [:]
    var filter: FilterPreset = .original

    // Videos only.
    var trimStart: Double = 0
    /// Seconds from the start; nil keeps everything to the end.
    var trimEnd: Double?
    var muted = false

    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    var isUnchanged: Bool { self == Edits() }

    /// Nothing but a trim or mute: the video can be cut without re-encoding a frame.
    var isTrimOnly: Bool {
        var picture = self
        picture.trimStart = 0
        picture.trimEnd = nil
        picture.muted = false
        return picture == Edits()
    }

    /// Whether anything moves or trims the picture, as opposed to only recolouring it.
    var changesGeometry: Bool {
        quarterTurns % 4 != 0 || flipped || straighten != 0 || crop != Self.fullCrop
    }

    func value(_ adjustment: Adjustment) -> Double {
        adjustments[adjustment] ?? 0
    }

    mutating func set(_ adjustment: Adjustment, to value: Double) {
        let clamped = min(max(value, adjustment.range.lowerBound), adjustment.range.upperBound)
        adjustments[adjustment] = abs(clamped) < 0.005 ? nil : clamped
    }
}
