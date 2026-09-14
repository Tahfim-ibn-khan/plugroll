import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Draws a player's video, aspect-fit. No controls of its own.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerSurface, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: PlayerSurface, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass guarantees the type.
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Apple's AirPlay picker button, styled for the dark viewer.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
