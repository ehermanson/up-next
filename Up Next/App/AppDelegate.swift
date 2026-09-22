import CloudKit
import UIKit

/// App delegate whose only job is to hand scene configuration to `SceneDelegate`, so
/// `windowScene(_:userDidAcceptCloudKitShareWith:)` can accept incoming CloudKit share
/// invitations (tapping a share link / accepting from Messages, Mail, etc.).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LightModeControlAppearance.install()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// Light-mode styling for the two system controls SwiftUI gives no styling hook for: the
/// `.searchable` field and the segmented `Picker`. Both default to a black-alpha fill
/// (`tertiarySystemFill`) which reads as flat gray on the lilac mesh — the one place the light
/// design looked like a fallback. Registered through the *light* trait's appearance proxy only,
/// so dark mode keeps the stock system look untouched.
enum LightModeControlAppearance {
    static func install() {
        let light = UITraitCollection(userInterfaceStyle: .light)

        // Same translucent white as `DesignTokens.Colors.lightSmallSurface`, so the field reads
        // as one of the app's own surfaces rather than a system well.
        let surface = UIColor.white.withAlphaComponent(0.72)
        // `UISearchTextField.backgroundColor` is ignored by the iOS 26 search bar; the background
        // *image* is still honoured, so the field gets a resizable capsule in the surface color.
        UISearchBar.appearance(for: light).setSearchFieldBackgroundImage(capsuleImage(surface), for: .normal)
        // The segmented track; the selected segment stays the system's opaque white so the
        // active tab still steps up from it.
        UISegmentedControl.appearance(for: light).backgroundColor = surface
    }

    /// A capsule the search bar stretches to the field's size. The caps are the field's own
    /// corner radius, so only the straight middle stretches.
    private static func capsuleImage(_ color: UIColor) -> UIImage {
        let height: CGFloat = 36
        let size = CGSize(width: height, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2).fill()
        }
        let cap = height / 2
        return image.resizableImage(
            withCapInsets: UIEdgeInsets(top: cap, left: cap, bottom: cap, right: cap),
            resizingMode: .stretch
        )
    }
}

/// Hands CloudKit share invitations the user opens (e.g. from Messages/Mail) to
/// `PersistenceController`, which asks before replacing this device's own library. Two entry
/// points: a link tapped while the app is running arrives through
/// `windowScene(_:userDidAcceptCloudKitShareWith:)`; a link that *launches* the app arrives in
/// the scene's connection options instead, and would be silently dropped without the first method.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            accept(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        accept(cloudKitShareMetadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            PersistenceController.shared.receiveShareInvitation(metadata)
        }
    }
}
