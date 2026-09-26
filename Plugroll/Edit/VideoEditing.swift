import AVFoundation
import CoreImage

/// Puts `Edits` on a video: the same Core Image pipeline as photos, run on every frame.
enum VideoEditing {
    enum Failure: LocalizedError {
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "This file has no video in it."
            }
        }
    }

    /// The frame size as it's meant to be watched, after the track's own rotation
    /// (phones record portrait video as landscape frames plus a turn).
    static func orientedSize(of asset: AVAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let turned = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(turned.width).rounded(), height: abs(turned.height).rounded())
    }

    /// A video composition that draws every frame through `EditRenderer`.
    /// `applyCrop` false shows the whole picture, for the crop screen.
    static func composition(
        for asset: AVAsset,
        edits: Edits,
        applyCrop: Bool = true
    ) async throws -> AVMutableVideoComposition {
        let source = try await orientedSize(of: asset)
        let output = EditRenderer.outputSize(for: source, edits: edits, applyCrop: applyCrop)
        // Encoders want even sizes; the spare pixel, if any, is dropped.
        let renderSize = CGSize(width: evenFloor(output.width), height: evenFloor(output.height))
        let frame = CGRect(origin: .zero, size: renderSize)

        let composition = try await AVMutableVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: { request in
                let edited = EditRenderer.apply(edits, to: request.sourceImage, applyCrop: applyCrop)
                request.finish(with: edited.cropped(to: frame), context: nil)
            }
        )
        composition.renderSize = renderSize
        return composition
    }

    /// The trimmed (and possibly muted) video, ready for `composition(for:)` and export.
    static func trimmedAsset(from source: AVAsset, edits: Edits) async throws -> AVMutableComposition {
        guard let video = try await source.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let duration = try await source.load(.duration)
        let range = trimRange(edits, duration: duration)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw Failure.noVideoTrack }
        try videoTrack.insertTimeRange(range, of: video, at: .zero)
        videoTrack.preferredTransform = try await video.load(.preferredTransform)

        if !edits.muted {
            for audio in try await source.loadTracks(withMediaType: .audio) {
                let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                try audioTrack?.insertTimeRange(range, of: audio, at: .zero)
            }
        }
        return composition
    }

    static func trimRange(_ edits: Edits, duration: CMTime) -> CMTimeRange {
        let total = duration.seconds.isFinite ? duration.seconds : 0
        let start = min(max(0, edits.trimStart), total)
        let end = min(max(start, edits.trimEnd ?? total), total)
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    static func isHEVC(_ asset: AVAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first
        else { return false }
        return CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
    }

    private static func evenFloor(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}
