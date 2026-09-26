import SwiftUI

/// The crop box drawn over the picture. Drag a corner to resize, or inside to move.
/// `crop` is in fractions of the picture, from its top-left.
struct CropOverlay: View {
    @Binding var crop: CGRect
    /// Width over height, in the same fractions as `crop`; nil for freeform.
    let ratio: CGFloat?
    /// The picture's size on screen.
    let size: CGSize

    @State private var dragStart: CGRect?

    private static let minimumSide: CGFloat = 0.08
    private static let handleSize: CGFloat = 44

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    var body: some View {
        let box = CGRect(
            x: crop.minX * size.width,
            y: crop.minY * size.height,
            width: crop.width * size.width,
            height: crop.height * size.height
        )

        ZStack(alignment: .topLeading) {
            // Darkens everything outside the box.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(box)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            if dragStart != nil {
                thirds(in: box)
            }

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
                .offset(x: box.minX, y: box.minY)
                .gesture(moveGesture)

            ForEach(Corner.allCases, id: \.self) { corner in
                handle(for: corner)
                    .position(
                        x: corner.isLeft ? box.minX : box.maxX,
                        y: corner.isTop ? box.minY : box.maxY
                    )
                    .gesture(resizeGesture(corner))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.15), value: dragStart == nil)
    }

    private func thirds(in box: CGRect) -> some View {
        Path { path in
            for i in 1...2 {
                let x = box.minX + box.width * CGFloat(i) / 3
                let y = box.minY + box.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: box.minY))
                path.addLine(to: CGPoint(x: x, y: box.maxY))
                path.move(to: CGPoint(x: box.minX, y: y))
                path.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    /// An L-shaped bracket, like the corners in Photos, with a bigger touch area.
    private func handle(for corner: Corner) -> some View {
        let arm: CGFloat = 20, thickness: CGFloat = 4
        return ZStack {
            Rectangle()
                .frame(width: arm, height: thickness)
                .offset(x: corner.isLeft ? arm / 2 - thickness / 2 : -(arm / 2 - thickness / 2),
                        y: corner.isTop ? -thickness / 2 : thickness / 2)
            Rectangle()
                .frame(width: thickness, height: arm)
                .offset(x: corner.isLeft ? -thickness / 2 : thickness / 2,
                        y: corner.isTop ? arm / 2 - thickness / 2 : -(arm / 2 - thickness / 2))
        }
        .foregroundStyle(.white)
        .frame(width: Self.handleSize, height: Self.handleSize)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                let dx = value.translation.width / max(size.width, 1)
                let dy = value.translation.height / max(size.height, 1)
                crop.origin = CGPoint(
                    x: min(max(0, start.minX + dx), 1 - start.width),
                    y: min(max(0, start.minY + dy), 1 - start.height)
                )
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                let dx = value.translation.width / max(size.width, 1)
                let dy = value.translation.height / max(size.height, 1)
                crop = Self.resized(start, corner: corner, dx: dx, dy: dy, ratio: ratio)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// The box after dragging `corner`; the opposite corner stays put.
    private static func resized(_ start: CGRect, corner: Corner, dx: CGFloat, dy: CGFloat, ratio: CGFloat?) -> CGRect {
        let anchor = CGPoint(x: corner.isLeft ? start.maxX : start.minX, y: corner.isTop ? start.maxY : start.minY)
        let moved = CGPoint(
            x: min(max(0, (corner.isLeft ? start.minX : start.maxX) + dx), 1),
            y: min(max(0, (corner.isTop ? start.minY : start.maxY) + dy), 1)
        )
        // Room from the anchor to the picture's edge, in the dragged direction.
        let roomX = corner.isLeft ? anchor.x : 1 - anchor.x
        let roomY = corner.isTop ? anchor.y : 1 - anchor.y

        var width = max(minimumSide, abs(anchor.x - moved.x))
        var height = max(minimumSide, abs(anchor.y - moved.y))
        width = min(width, roomX)
        height = min(height, roomY)

        if let ratio, ratio > 0 {
            // Follow whichever side moved further, then shrink both to fit.
            if width / height > ratio { height = width / ratio } else { width = height * ratio }
            if width > roomX { width = roomX; height = width / ratio }
            if height > roomY { height = roomY; width = height * ratio }
        }

        return CGRect(
            x: corner.isLeft ? anchor.x - width : anchor.x,
            y: corner.isTop ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
    }
}
