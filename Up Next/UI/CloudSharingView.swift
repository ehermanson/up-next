import CloudKit
import os
import SwiftUI
import UIKit

/// Wraps `UICloudSharingController` so `SharingSettingsView` can present the system "Manage
/// Sharing" UI for the single `CKShare` rooted at `WatchListGroup`. Mirrors `SafariView.swift`
/// in style: a thin `UIViewControllerRepresentable`, no state of its own beyond the delegate.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    /// Called after the sheet is dismissed (save or stop-sharing) so the caller can re-read
    /// `PersistenceController.liveShare` and refresh its UI.
    var onChange: () -> Void = {}
    /// Called when the system controller fails to save the share (e.g. a network error while
    /// updating permissions) so the caller can surface it instead of the failure going silent.
    var onError: (Error) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        // Matches the options the share was created with (`allowedParticipantAccessOptions: .any`
        // in `LibraryShareItem`) — otherwise the manage sheet offers a narrower set than the
        // original invite did.
        controller.availablePermissions = [.allowReadWrite, .allowPrivate, .allowPublic]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onError: onError)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onChange: () -> Void
        let onError: (Error) -> Void

        init(onChange: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onChange = onChange
            self.onError = onError
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Up Next watchlist"
        }

        func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
            nil
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            AppLog.sharing.error("failed to save share: \(error)")
            onError(error)
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onChange()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onChange()
        }
    }
}
