import CloudKit
import Foundation

/// Display names for share participants, in one place. iOS may withhold `nameComponents` from
/// apps without the extended share-access entitlement, so every caller needs the same fallback
/// dance — previously copy-pasted across Settings, the toolbar button, notifications and
/// attribution.
extension CKUserIdentity {
    /// "Sarah Jones" when CloudKit provides name components, else nil.
    var displayName: String? {
        guard let components = nameComponents else { return nil }
        let name = PersonNameComponentsFormatter().string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Up to two initials ("SJ"), for avatar badges. Nil when there's no usable name.
    var initials: String? {
        guard let components = nameComponents else { return nil }
        let parts = [components.givenName, components.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).first }
        guard !parts.isEmpty else { return nil }
        return String(parts).uppercased()
    }
}

extension CKShare.Participant {
    var displayName: String? { userIdentity.displayName }
    var initials: String? { userIdentity.initials }
}

extension CKShare {
    /// The first non-owner participant. **Owner-side only**: on a participant's own device this is
    /// the participant themselves. Anything that names "the other person" must use
    /// `otherParticipant` / `otherDisplayName` instead.
    var partnerParticipant: CKShare.Participant? {
        participants.first { $0.role != .owner }
    }

    /// The other person in the share from this device's point of view: the owner when the current
    /// user is a participant, else the first non-owner participant.
    var otherParticipant: CKShare.Participant? {
        currentUserParticipant?.role == .owner ? partnerParticipant : owner
    }

    var otherDisplayName: String? { otherParticipant?.displayName }

    var ownerDisplayName: String? { owner.userIdentity.displayName }
}
