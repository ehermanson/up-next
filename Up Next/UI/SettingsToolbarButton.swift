import SwiftUI

/// The trailing toolbar entry point into `SettingsView`, used on all four tabs. Always the plain
/// gear: swapping to the collaboration glyph (`person.2`) once a share went live was tried and
/// dropped — a toolbar control is found by its shape, and `person.2` promises the collaboration
/// sheet rather than all of Settings. Sharing status lives in Settings → Sharing.
struct SettingsToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Settings", systemImage: "gearshape")
        }
    }
}
