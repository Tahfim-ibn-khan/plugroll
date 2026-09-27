import SwiftUI

/// The folders at the top of the drive, biggest first. Tap one to open it.
struct FolderSizesScreen: View {
    @Environment(AppState.self) private var appState

    private var folders: [FolderSize] { appState.storage.folderSizes }

    var body: some View {
        List {
            Section {
                ForEach(folders) { folder in
                    if folder.isTopLevelFiles {
                        row(folder)
                    } else {
                        NavigationLink {
                            FolderScreen(folder: folder.url)
                        } label: {
                            row(folder)
                        }
                    }
                }
            } footer: {
                Text("Sizes count every file in the folder, not only photos and videos.")
            }
        }
        .navigationTitle("Folders by Size")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView("No Folders", systemImage: "folder")
            }
        }
    }

    private func row(_ folder: FolderSize) -> some View {
        let largest = Double(max(folders.first?.bytes ?? 1, 1))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(folder.name, systemImage: folder.isTopLevelFiles ? "doc.on.doc" : "folder.fill")
                    .lineLimit(1)
                Spacer()
                Text(ByteFormat.string(folder.bytes))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: max(4, geometry.size.width * Double(folder.bytes) / largest))
            }
            .frame(height: 5)
            Text("\(folder.mediaCount.formatted()) photos and videos")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
