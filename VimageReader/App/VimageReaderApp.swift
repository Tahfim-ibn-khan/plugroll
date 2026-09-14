import AVFoundation
import SwiftUI

@main
struct VimageReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    init() {
        // Play video sound even when the silent switch is on, like Photos.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        // Leftover copies from a share that was interrupted last time.
        ExportService.clearOutbox()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}
