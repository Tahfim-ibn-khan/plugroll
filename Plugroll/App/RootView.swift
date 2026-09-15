import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var showPicker = false

    var body: some View {
        @Bindable var state = appState

        Group {
            if let root = appState.rootURL {
                NavigationStack(path: $state.path) {
                    FolderScreen(folder: root)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showPicker = true
                                } label: {
                                    Image(systemName: "externaldrive")
                                }
                            }
                        }
                        .navigationDestination(for: FolderEntry.self) { folder in
                            FolderScreen(folder: folder.url)
                        }
                }
            } else {
                ContentUnavailableView {
                    Label("No Drive Open", systemImage: "externaldrive")
                } description: {
                    Text("Plug in your SSD, then pick it (or any folder on it).")
                } actions: {
                    Button("Open SSD") { showPicker = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if appState.rootURL != nil && !appState.isDriveConnected {
                DriveDisconnectedBanner(onChooseDrive: { showPicker = true })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: appState.isDriveConnected)
        .task { await appState.restoreLastDrive() }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): appState.open(url)
            case .failure(let error): appState.errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Couldn't Open Folder",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}
