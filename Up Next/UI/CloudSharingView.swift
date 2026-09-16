import CloudKit
import SwiftUI
import UIKit

/// Wraps `UICloudSharingController` so `SharingSettingsView` can present the system "Manage
/// Sharing" UI for the single `CKShare` rooted at `WatchListGroup`. Mirrors `SafariView.swift`
/// in style: a thin `UIViewControllerRepresentable`, no state of its own beyond the delegate.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    /// Called after the sheet is dismissed (save or stop-sharing) so the caller can re-read
    /// `PersistenceController.existingShare()` and refresh its UI.
    var onChange: () -> Void = {}

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onChange: () -> Void

        init(onChange: @escaping () -> Void) {
            self.onChange = onChange
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Up Next library"
        }

        func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
            nil
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("⚠️ CloudSharingView: failed to save share: \(error)")
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onChange()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onChange()
        }
    }
}
