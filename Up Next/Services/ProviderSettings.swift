import CoreData
import Foundation
import SwiftUI

/// `@AppStorage` key constants for the watchlist tabs' device-local view preferences. Kept next to
/// `ProviderSettings`' own keys so every persisted-preference string in the app lives in one file.
enum StorageKey {
    static let tvOnlyMyServices = "tvShows.onlyMyServices"
    static let movieOnlyMyServices = "movies.onlyMyServices"
    static let tvWatchedExpanded = "tvShows.watchedExpanded"
    static let movieWatchedExpanded = "movies.watchedExpanded"
}

/// Device preferences plus the household's streaming services.
///
/// `selectedProviderIDs` is a *mirror*: the source of truth is `WatchListGroup.selectedProviderIDs`
/// on the active root, so services follow the share the way titles and collections do — an owner's
/// iPhone and iPad agree, and a partner sees the same set. The stored property stays observable so
/// every SwiftUI consumer re-renders exactly as it did when this was a plain `UserDefaults` value;
/// the `UserDefaults` copy is still written, now as a startup cache (the first frame after launch
/// isn't "no services" while the store loads) and as the seed for a root that has none yet.
/// Everything else here is device-local on purpose: `regionOverride` (it's about where the phone
/// is), `onlyMyServicesInDiscover`, `hasCompletedProviderOnboarding`, `hasDismissedSharePitch`.
@MainActor @Observable
final class ProviderSettings {
    static let shared = ProviderSettings()

    private static let selectedProvidersKey = "selectedProviderIDs"
    var selectedProviderIDs: Set<Int> {
        didSet {
            saveSelectedProviders()
            pushSelectionToGroup()
        }
    }

    /// True once the active group's selection has been read at least once this launch. Onboarding
    /// waits for it — a partner joining on a cold launch must not be asked to pick services the
    /// household already has.
    private(set) var isSelectionLoaded = false

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

    private static let hasDismissedSharePitchKey = "sharing.pitchDismissed"
    var hasDismissedSharePitch: Bool {
        didSet {
            UserDefaults.standard.set(hasDismissedSharePitch, forKey: Self.hasDismissedSharePitchKey)
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

        hasDismissedSharePitch = UserDefaults.standard.bool(forKey: Self.hasDismissedSharePitchKey)
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

    // MARK: - Household sync

    /// Group → mirror. Called by `PersistenceController` when the root is established or a remote
    /// change lands. A `nil` on the group means it was never set: seed it from this device's cache
    /// (first non-nil wins — no merge, no conflict) instead of blanking the mirror.
    func adoptSelection(from group: WatchListGroup) {
        defer { isSelectionLoaded = true }
        guard let stored = group.selectedProviderIDs else {
            group.selectedProviderIDs = selectedProviderIDs
            PersistenceController.shared.save()
            return
        }
        // `didSet` fires on the assignment below, but `pushSelectionToGroup` then finds the group
        // already equal and writes nothing — no echo back into the store.
        if stored != selectedProviderIDs { selectedProviderIDs = stored }
    }

    /// Mirror → group. No-op without a root (mid-join, pre-bootstrap, `--screenshots` before
    /// seeding) — `adoptSelection` copies the cache in when the root appears.
    private func pushSelectionToGroup() {
        let persistence = PersistenceController.shared
        guard let group = persistence.group as WatchListGroup?,
              group.managedObjectContext != nil, !group.isDeleted
        else { return }
        guard group.selectedProviderIDs != selectedProviderIDs else { return }
        group.selectedProviderIDs = selectedProviderIDs
        persistence.save()
    }
}
