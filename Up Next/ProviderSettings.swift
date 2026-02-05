import Foundation
import SwiftUI

@MainActor @Observable
final class ProviderSettings {
    static let shared = ProviderSettings()

    private static let selectedProvidersKey = "selectedProviderIDs"
    private static let onboardingKey = "hasCompletedProviderOnboarding"

    var selectedProviderIDs: Set<Int> {
        didSet {
            saveSelectedProviders()
            // Clear availability cache since selections changed
            Task { await TMDBService.shared.clearProviderAvailabilityCache() }
        }
    }

    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingKey) }
    }

    var hasSelectedProviders: Bool {
        !selectedProviderIDs.isEmpty
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.selectedProvidersKey),
           let ids = try? JSONDecoder().decode(Set<Int>.self, from: data) {
            selectedProviderIDs = ids
        } else {
            selectedProviderIDs = []
        }
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
    }

    /// Returns true if provider should be shown.
    /// When no providers are selected, all providers are shown (preserves behavior for users who skip onboarding).
    func isSelected(_ id: Int) -> Bool {
        selectedProviderIDs.isEmpty || selectedProviderIDs.contains(id)
    }

    func toggleProvider(_ id: Int) {
        if selectedProviderIDs.contains(id) {
            selectedProviderIDs.remove(id)
        } else {
            selectedProviderIDs.insert(id)
        }
    }

    func selectProviders(_ ids: Set<Int>) {
        selectedProviderIDs = ids
    }

    private func saveSelectedProviders() {
        if let data = try? JSONEncoder().encode(selectedProviderIDs) {
            UserDefaults.standard.set(data, forKey: Self.selectedProvidersKey)
        }
    }
}
