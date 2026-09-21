import Foundation
import CoreData

@objc(CustomListItem)
final class CustomListItem: NSManagedObject, Identifiable {
    // See the comment on `ListItem`'s conformance: no natural `id`, so this uses the stdlib's
    // per-instance `ObjectIdentifier` default, which stays stable across a save.
    @NSManaged var movie: Movie?
    @NSManaged var tvShow: TVShow?
    @NSManaged var customList: CustomList?
    @NSManaged var addedAtRaw: Date?

    /// When this title was marked watched *inside this collection*. Collections are seasonal /
    /// thematic pools, so their watched state is their own — it never reads or writes the
    /// library's `ListItem`s (the Movies / TV Shows tabs). Optional + defaulted for CloudKit.
    @NSManaged var watchedAt: Date?

    var addedAt: Date {
        get { addedAtRaw ?? .distantPast }
        set { addedAtRaw = newValue }
    }

    var isWatched: Bool { watchedAt != nil }

    var media: (any MediaItemProtocol)? {
        movie ?? tvShow
    }

    /// Type-namespaced key (`"tv:123"` / `"movie:456"`, see `MediaIDKey`) for this entry's media,
    /// or nil if both `movie` and `tvShow` are nil. Callers used to derive this inline from
    /// `item.tvShow != nil ? .tvShow : .movie` + `media.id`; centralizing it here means the
    /// derivation only has one place to get right.
    var mediaKey: String? {
        if let movie { return MediaIDKey.make(.movie, movie.id) }
        if let tvShow { return MediaIDKey.make(.tvShow, tvShow.id) }
        return nil
    }

    convenience init(
        movie: Movie? = nil,
        tvShow: TVShow? = nil,
        customList: CustomList? = nil,
        addedAt: Date = Date.now,
        watchedAt: Date? = nil,
        context: NSManagedObjectContext? = nil
    ) {
        // Join the context (and store) of the collection / media row — see `inferredContext`.
        let related: [NSManagedObject?] = [customList, movie, tvShow]
        self.init(entity: managedEntity(named: "CustomListItem"), insertInto: inferredContext(context, relating: related))
        self.movie = movie
        self.tvShow = tvShow
        self.customList = customList
        self.addedAt = addedAt
        self.watchedAt = watchedAt
        if context == nil { assignToStore(of: related, self) }
    }

    /// Flips this collection entry's watched state. Nothing outside the collection changes.
    func toggleWatched() {
        watchedAt = isWatched ? nil : Date.now
    }
}
