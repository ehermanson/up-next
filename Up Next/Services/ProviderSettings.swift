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

    /// `nil` means "follow the device locale". Storing the device's own region is still an
    /// explicit choice and persists as one, so a later trip abroad doesn't silently move the user.
    nonisolated static let regionOverrideKey = "providers.regionOverride"
    var regionOverride: String? {
        didSet {
            if let regionOverride, !regionOverride.isEmpty {
                UserDefaults.standard.set(regionOverride, forKey: Self.regionOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.regionOverrideKey)
            }
        }
    }

    /// The device locale's region, or "US" when the locale doesn't carry one.
    nonisolated static var deviceRegion: String {
        Locale.current.region?.identifier ?? "US"
    }

    /// The region every TMDB lookup should use. Reads `UserDefaults` directly rather than the
    /// shared instance so `TMDBService` can call it from outside the main actor.
    nonisolated static var effectiveRegion: String {
        if let override = UserDefaults.standard.string(forKey: regionOverrideKey), !override.isEmpty {
            return override
        }
        return deviceRegion
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

        let storedRegion = UserDefaults.standard.string(forKey: Self.regionOverrideKey)
        regionOverride = (storedRegion?.isEmpty == false) ? storedRegion : nil

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
