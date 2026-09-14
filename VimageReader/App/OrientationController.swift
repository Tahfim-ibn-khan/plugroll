import UIKit

/// Lets SwiftUI decide which orientations the app allows at any moment.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationController.allowed
    }
}

/// The viewer's rotate button. Turning the screen from code works even with
/// Portrait Orientation Lock on, because the app narrows what it allows and
/// then asks the scene to rotate to match.
@MainActor
enum OrientationController {
    fileprivate(set) static var allowed: UIInterfaceOrientationMask = .allButUpsideDown

    /// Portrait ⇄ landscape. Stays put (ignores device tilt) until tapped again.
    static func toggle() {
        guard let scene = activeScene else { return }
        apply(scene.effectiveGeometry.interfaceOrientation.isLandscape ? .portrait : .landscapeRight, in: scene)
    }

    /// Back to portrait with normal rotation allowed. Called when the viewer closes.
    static func reset() {
        guard allowed != .allButUpsideDown, let scene = activeScene else { return }
        if scene.effectiveGeometry.interfaceOrientation.isLandscape {
            apply(.portrait, in: scene)
        }
        allowed = .allButUpsideDown
        refreshSupportedOrientations(in: scene)
    }

    private static func apply(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        allowed = mask
        refreshSupportedOrientations(in: scene)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    private static func refreshSupportedOrientations(in scene: UIWindowScene) {
        // Every controller in the presentation chain has to re-read the allowed set,
        // since the viewer is a full-screen cover on top of the root.
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
