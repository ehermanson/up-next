import Foundation
import SwiftUI

@MainActor @Observable
final class ProviderSettings {
    static let shared = ProviderSettings()

    private static let selectedProvidersKey = "selectedProviderIDs"
    var selectedProviderIDs: Set<Int> {
        didSet {
            saveSelectedProviders()
        }
    }

    private static let onlyMyServicesInDiscoverKey = "discover.onlyMyServices"
    var onlyMyServicesInDiscover: Bool {
        didSet {
            UserDefaults.standard.set(onlyMyServicesInDiscover, forKey: Self.onlyMyServicesInDiscoverKey)
        }
    }

    private static let hasCompletedProviderOnboardingKey = "hasCompletedProviderOnboarding"
    var hasCompletedProviderOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedProviderOnboarding, forKey: Self.hasCompletedProviderOnboardingKey)
        }
    }

    var hasSelectedProviders: Bool {
        !selectedProviderIDs.isEmpty
    }

    /// Selected provider ids as a sorted, pipe-joined string for TMDB's `with_watch_providers`
    /// query param, or `nil` when none are selected. Sorted so the value (and therefore the
    /// response cache key) is deterministic regardless of `Set` iteration order.
    var watchProvidersQueryValue: String? {
        guard !selectedProviderIDs.isEmpty else { return nil }
        return selectedProviderIDs.sorted().map(String.init).joined(separator: "|")
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.selectedProvidersKey),
           let ids = try? JSONDecoder().decode(Set<Int>.self, from: data) {
            selectedProviderIDs = ids
        } else {
            selectedProviderIDs = []
        }

        if UserDefaults.standard.object(forKey: Self.onlyMyServicesInDiscoverKey) != nil {
            onlyMyServicesInDiscover = UserDefaults.standard.bool(forKey: Self.onlyMyServicesInDiscoverKey)
        } else {
            onlyMyServicesInDiscover = true
        }

        hasCompletedProviderOnboarding = UserDefaults.standard.bool(forKey: Self.hasCompletedProviderOnboardingKey)
    }

    /// Returns true if provider should be shown.
    /// When no providers are selected, all providers are shown.
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
