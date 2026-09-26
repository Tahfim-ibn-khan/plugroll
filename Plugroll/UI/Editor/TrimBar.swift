import SwiftUI

/// A strip of frames with yellow handles, like the trimmer in Photos. Drag a handle to
/// trim; drag the strip to move the playhead.
struct TrimBar: View {
    let frames: [CGImage]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double?
    let playhead: Double
    let onSeek: (Double) -> Void

    @State private var dragOrigin: Double?

    private static let handleWidth: CGFloat = 16
    private static let height: CGFloat = 52
    /// The shortest clip the handles allow.
    private static let minimumLength: Double = 0.5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - Self.handleWidth * 2
            let endValue = end ?? duration
            let startX = Self.handleWidth + x(for: start, in: width)
            let endX = Self.handleWidth + x(for: endValue, in: width)

            ZStack(alignment: .leading) {
                filmstrip(width: width)
                    .offset(x: Self.handleWidth)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(width: width))

                // Dims the parts that will be cut.
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: max(0, startX - Self.handleWidth), height: Self.height)
                    .offset(x: Self.handleWidth)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: max(0, Self.handleWidth + width - endX), height: Self.height)
                    .offset(x: endX)
                    .allowsHitTesting(false)

                // The yellow frame around what's kept.
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: endX - startX + Self.handleWidth * 2, height: Self.height)
                    .offset(x: startX - Self.handleWidth)
                    .allowsHitTesting(false)

                handle(pointingLeft: true)
                    .offset(x: startX - Self.handleWidth)
                    .gesture(handleGesture(width: width, isStart: true))
                handle(pointingLeft: false)
                    .offset(x: endX)
                    .gesture(handleGesture(width: width, isStart: false))

                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: Self.height + 8)
                    .offset(x: Self.handleWidth + x(for: playhead, in: width) - 1.5)
                    .shadow(radius: 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: Self.height)
    }

    private func x(for seconds: Double, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / duration, 0), 1)) * width
    }

    private func seconds(forTranslation translation: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(translation / width) * duration
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width / CGFloat(max(frames.count, 1)), height: Self.height)
                    .clipped()
            }
        }
        .frame(width: width, height: Self.height, alignment: .leading)
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func handle(pointingLeft: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: pointingLeft ? 6 : 0,
            bottomLeadingRadius: pointingLeft ? 6 : 0,
            bottomTrailingRadius: pointingLeft ? 0 : 6,
            topTrailingRadius: pointingLeft ? 0 : 6
        )
        .fill(Color.yellow)
        .frame(width: Self.handleWidth, height: Self.height)
        .overlay {
            Image(systemName: pointingLeft ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black)
        }
        .contentShape(Rectangle().inset(by: -10))
        .accessibilityLabel(pointingLeft ? "Start of trim" : "End of trim")
    }

    private func handleGesture(width: CGFloat, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? (isStart ? start : (end ?? duration))
                dragOrigin = origin
                let proposed = origin + seconds(forTranslation: value.translation.width, in: width)
                if isStart {
                    start = min(max(0, proposed), (end ?? duration) - Self.minimumLength)
                    onSeek(start)
                } else {
                    let clamped = max(min(duration, proposed), start + Self.minimumLength)
                    // At the very end, nothing is cut.
                    end = clamped >= duration - 0.01 ? nil : clamped
                    onSeek(clamped)
                }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let seconds = Double(min(max(0, value.location.x / max(width, 1)), 1)) * duration
                onSeek(seconds)
            }
    }
}
