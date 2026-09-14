import SwiftUI

/// Scrub bar and transport buttons for the video on screen.
/// Lives outside the paging scroll view so dragging the bar never swipes pages.
struct VideoControls: View {
    let player: PlayerModel
    /// Called on any touch, so the viewer can restart its auto-hide timer.
    let onInteraction: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(DurationFormat.string(from: player.currentTime))
                    .frame(minWidth: 44, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { min(player.currentTime, sliderUpperBound) },
                        set: { player.scrub(to: $0) }
                    ),
                    in: 0...sliderUpperBound,
                    onEditingChanged: { editing in
                        if editing { player.beginScrubbing() } else { player.endScrubbing() }
                        onInteraction()
                    }
                )
                .tint(.white)
                .disabled(player.duration <= 0)

                Text("-" + DurationFormat.string(from: max(0, player.duration - player.currentTime)))
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.9))

            HStack {
                controlButton(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 17) {
                    player.isMuted.toggle()
                }

                Spacer()

                controlButton("gobackward.10", size: 22) { player.skip(by: -10) }

                controlButton(player.isPlaying ? "pause.fill" : "play.fill", size: 30) {
                    player.togglePlayback()
                }
                .padding(.horizontal, 18)

                controlButton("goforward.10", size: 22) { player.skip(by: 10) }

                Spacer()

                AirPlayButton()
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var sliderUpperBound: Double {
        max(player.duration, 0.1)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
