import SwiftUI

/// Shown while the opened drive is unplugged. Things already loaded stay browsable.
struct DriveDisconnectedBanner: View {
    var onChooseDrive: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Drive Disconnected")
                    .font(.subheadline.weight(.semibold))
                Text("Plug it back in and it reconnects on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let onChooseDrive {
                Button("Choose", action: onChooseDrive)
                    .buttonStyle(.bordered)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
