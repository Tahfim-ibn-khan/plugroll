import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns `Edits` into Core Image work. Photos and video frames go through the same
/// function, so a video looks exactly like its preview.
enum EditRenderer {
    /// Shared: contexts are expensive to make, and this one is safe to use from any thread.
    static let context = CIContext(options: [.cacheIntermediates: false])

    static let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// The edited picture, moved so its bottom-left corner sits at (0, 0).
    ///
    /// - Parameters:
    ///   - applyCrop: false shows the whole turned and straightened picture, for the
    ///     crop screen to draw its box on.
    ///   - autoFilters: from `autoFilters(for:)`, used when `edits.autoEnhance` is on.
    static func apply(
        _ edits: Edits,
        to input: CIImage,
        applyCrop: Bool = true,
        autoFilters: [CIFilter] = []
    ) -> CIImage {
        var image = orient(input, quarterTurns: edits.quarterTurns, flipped: edits.flipped)
        image = straighten(image, degrees: edits.straighten)
        if applyCrop { image = crop(image, to: edits.crop) }

        // Colour work can grow the extent (sharpening, vignette); keep the picture's own.
        let frame = image.extent
        if edits.autoEnhance {
            for filter in autoFilters {
                guard let copy = filter.copy() as? CIFilter else { continue }
                copy.setValue(image, forKey: kCIInputImageKey)
                image = copy.outputImage ?? image
            }
        }
        image = adjust(image, edits)
        image = applyFilter(edits.filter, to: image)
        return image.cropped(to: frame)
    }

    /// The size `apply` would produce for a picture of `size`, without rendering anything.
    static func outputSize(for size: CGSize, edits: Edits, applyCrop: Bool = true) -> CGSize {
        let blank = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        var image = orient(blank, quarterTurns: edits.quarterTurns, flipped: edits.flipped)
        image = straighten(image, degrees: edits.straighten)
        if applyCrop { image = crop(image, to: edits.crop) }
        return image.extent.size
    }

    /// Photos-style auto-enhance, worked out once from a picture and reused for every render.
    static func autoFilters(for image: CIImage) -> [CIFilter] {
        image.autoAdjustmentFilters(options: [.redEye: false])
    }

    static func cgImage(from image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: displayColorSpace)
    }

    // MARK: - Geometry

    static func orient(_ image: CIImage, quarterTurns: Int, flipped: Bool) -> CIImage {
        var out = image
        if flipped {
            out = out.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0))
        }
        // Exact matrices: rotating by .pi / 2 leaves tiny errors that make extents fractional.
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: out = out.transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))
        case 2: out = out.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0))
        case 3: out = out.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0))
        default: break
        }
        return toOrigin(out)
    }

    /// How much a straightened picture has to shrink so no empty corners show: the
    /// largest rectangle of the same shape that fits inside the turned one.
    static func straightenScale(for size: CGSize, degrees: Double) -> CGFloat {
        let radians = abs(degrees) * .pi / 180
        let c = CGFloat(cos(radians)), s = CGFloat(sin(radians))
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return 1 }
        return min(w / (w * c + h * s), h / (w * s + h * c))
    }

    static func straighten(_ image: CIImage, degrees: Double) -> CIImage {
        guard degrees != 0 else { return image }
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        // Clamped first, so the edges of the kept area never blend with emptiness.
        let turned = image.clampedToExtent().transformed(
            by: CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: -CGFloat(degrees) * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
        )
        let scale = straightenScale(for: extent.size, degrees: degrees)
        let size = CGSize(width: (extent.width * scale).rounded(.down), height: (extent.height * scale).rounded(.down))
        let kept = CGRect(
            x: (center.x - size.width / 2).rounded(),
            y: (center.y - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        return toOrigin(turned.cropped(to: kept))
    }

    /// `crop` is in fractions from the top-left; Core Image measures from the bottom-left.
    static func crop(_ image: CIImage, to crop: CGRect) -> CIImage {
        guard crop != Edits.fullCrop else { return image }
        let extent = image.extent
        let unit = crop.intersection(Edits.fullCrop)
        guard !unit.isNull, unit.width > 0, unit.height > 0 else { return image }
        let x = (unit.minX * extent.width).rounded()
        let y = ((1 - unit.maxY) * extent.height).rounded()
        let rect = CGRect(
            x: extent.minX + x,
            y: extent.minY + y,
            width: max(1, min((unit.width * extent.width).rounded(), extent.width - x)),
            height: max(1, min((unit.height * extent.height).rounded(), extent.height - y))
        )
        return toOrigin(image.cropped(to: rect))
    }

    private static func toOrigin(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.origin != .zero, extent.minX.isFinite, extent.minY.isFinite else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    // MARK: - Colour

    static func adjust(_ image: CIImage, _ edits: Edits) -> CIImage {
        var out = image

        let exposure = edits.value(.exposure)
        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = out
            filter.ev = Float(exposure * 2)
            out = filter.outputImage ?? out
        }

        let brightness = edits.value(.brightness)
        let contrast = edits.value(.contrast)
        let saturation = edits.value(.saturation)
        if brightness != 0 || contrast != 0 || saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = out
            filter.brightness = Float(brightness * 0.25)
            filter.contrast = Float(1 + contrast * 0.35)
            filter.saturation = Float(1 + saturation)
            out = filter.outputImage ?? out
        }

        let highlights = edits.value(.highlights)
        let shadows = edits.value(.shadows)
        if highlights != 0 || shadows != 0 {
            // A gentle curve: shadows move the quarter-tone point, highlights the
            // three-quarter point, each by up to 0.15 either way.
            let filter = CIFilter.toneCurve()
            filter.inputImage = out
            filter.point0 = CGPoint(x: 0, y: 0)
            filter.point1 = CGPoint(x: 0.25, y: 0.25 + shadows * 0.15)
            filter.point2 = CGPoint(x: 0.5, y: 0.5 + (shadows + highlights) * 0.04)
            filter.point3 = CGPoint(x: 0.75, y: 0.75 + highlights * 0.15)
            filter.point4 = CGPoint(x: 1, y: 1)
            out = filter.outputImage ?? out
        }

        let vibrance = edits.value(.vibrance)
        if vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = out
            filter.amount = Float(vibrance)
            out = filter.outputImage ?? out
        }

        let warmth = edits.value(.warmth)
        if warmth != 0 {
            out = warm(out, by: warmth)
        }

        let sharpness = edits.value(.sharpness)
        if sharpness != 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = out
            filter.sharpness = Float(sharpness)
            filter.radius = 1.7
            out = filter.outputImage ?? out
        }

        let vignette = edits.value(.vignette)
        if vignette != 0 {
            let extent = image.extent
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = out
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.radius = Float(hypot(extent.width, extent.height) * 0.45)
            filter.intensity = Float(vignette)
            filter.falloff = 0.6
            out = filter.outputImage ?? out
        }

        return out
    }

    /// Positive is warmer (more yellow), negative cooler (more blue).
    static func warm(_ image: CIImage, by amount: Double) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 6500 - amount * 2500, y: 0)
        return filter.outputImage ?? image
    }

    static func applyFilter(_ preset: FilterPreset, to image: CIImage) -> CIImage {
        func controls(saturation: Float, contrast: Float = 1, brightness: Float = 0) -> CIImage {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = saturation
            filter.contrast = contrast
            filter.brightness = brightness
            return filter.outputImage ?? image
        }
        func vivid(_ base: CIImage) -> CIImage {
            let filter = CIFilter.vibrance()
            filter.inputImage = base
            filter.amount = 0.35
            return filter.outputImage ?? base
        }
        func effect(_ filter: CIFilter & CIFilterProtocol) -> CIImage {
            filter.setValue(image, forKey: kCIInputImageKey)
            return filter.outputImage ?? image
        }

        switch preset {
        case .original: return image
        case .vivid: return vivid(controls(saturation: 1.25, contrast: 1.05))
        case .vividWarm: return warm(vivid(controls(saturation: 1.25, contrast: 1.05)), by: 0.35)
        case .vividCool: return warm(vivid(controls(saturation: 1.25, contrast: 1.05)), by: -0.35)
        case .dramatic: return controls(saturation: 0.8, contrast: 1.3, brightness: -0.03)
        case .mono: return effect(CIFilter.photoEffectMono())
        case .silvertone: return effect(CIFilter.photoEffectTonal())
        case .noir: return effect(CIFilter.photoEffectNoir())
        case .chrome: return effect(CIFilter.photoEffectChrome())
        case .fade: return effect(CIFilter.photoEffectFade())
        case .instant: return effect(CIFilter.photoEffectInstant())
        case .process: return effect(CIFilter.photoEffectProcess())
        case .transfer: return effect(CIFilter.photoEffectTransfer())
        }
    }
}
