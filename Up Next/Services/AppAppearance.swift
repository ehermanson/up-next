import SwiftUI

/// A device-local preference; shared libraries do not change a partner's appearance.
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark, light, system

    static let storageKey = "appearance"
    var id: Self { self }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}
