import Foundation
import SwiftUI

@MainActor @Observable
final class ProviderSettings {
    static let shared = ProviderSettings()

    private static let storageKey = "hiddenProviderIDs"

    var hiddenProviderIDs: Set<Int> {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let ids = try? JSONDecoder().decode(Set<Int>.self, from: data) {
            hiddenProviderIDs = ids
        } else {
            hiddenProviderIDs = []
        }
    }

    func isHidden(_ id: Int) -> Bool {
        hiddenProviderIDs.contains(id)
    }

    func toggleProvider(_ id: Int) {
        if hiddenProviderIDs.contains(id) {
            hiddenProviderIDs.remove(id)
        } else {
            hiddenProviderIDs.insert(id)
        }
    }

    func setHidden(_ hidden: Bool, for ids: Set<Int>) {
        if hidden {
            hiddenProviderIDs.formUnion(ids)
        } else {
            hiddenProviderIDs.subtract(ids)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hiddenProviderIDs) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
