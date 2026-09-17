import CloudKit
import UIKit

// NOTE: Not wired up yet. Task E adds `@UIApplicationDelegateAdaptor(AppDelegate.self)` to
// `Watch_ListApp` when it swaps the app over to `PersistenceController`. Until then this file
// compiles standalone but isn't part of the running app.

/// App delegate whose only job is to hand scene configuration to `SceneDelegate`, so
/// `windowScene(_:userDidAcceptCloudKitShareWith:)` can accept incoming CloudKit share
/// invitations (tapping a share link / accepting from Messages, Mail, etc.).
final class AppDelegate: NSObject, UIApplicationDelegate {
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

/// Accepts CloudKit share invitations the user opens (e.g. from Messages/Mail) into the shared
/// store, then re-runs the persistence role rule so this device becomes a participant. Two entry
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
            do {
                try await PersistenceController.shared.acceptShare(metadata: metadata)
            } catch {
                print("⚠️ SceneDelegate: failed to accept CloudKit share: \(error)")
            }
        }
    }
}
