import SwiftUI

/// "Added Elf" / "Added Elf to Christmas" — one shape for every add confirmation the detail sheet
/// shows, whether the tap came from the pill, a "More Like This" card or a collection part.
func addedToastMessage(_ title: String, target: String?) -> String {
    guard let target else { return "Added \(title)" }
    return "Added \(title) to \(target)"
}

/// The detail sheet's one canonical Add affordance, sitting directly under the metadata block.
///
/// It has two forms — a big glass "Add to <target>" button, and a card-surface status chip
/// reporting the title's actual state — and an overflow menu that is the single place every
/// title-level action lives: state transitions for library-owned titles, collection membership,
/// and the destructive Remove. The old on-page toggle cards are gone; do not reintroduce them.
struct PrimaryAddPill: View {
    @ObservedObject var listItem: ListItem
    var customListViewModel: CustomListViewModel?
    /// Type-namespaced IDs of titles already in the library (see `MediaIDKey`).
    var existingIDs: Set<String> = []
    /// Names the collection an add-to-collection flow targets; nil means Up Next.
    var addTargetName: String?
    /// Set when the sheet was opened from a collection.
    var collectionName: String?
    /// True when the sheet is bound to a collection entry rather than a library row.
    var isCollectionEntry: Bool
    /// Copy for the menu's destructive row.
    var removeLabel: String?
    var onAdd: (() -> Void)?
    @Binding var justAddedLocally: Bool
    @Binding var isConfirmingRemoval: Bool
    /// Stamped on every local state change so `SeasonChecklistCard` can tell this device's edits
    /// from a partner's landing while the sheet is open.
    @Binding var lastLocalWatchedEdit: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ToastState.self) private var toast

    var body: some View {
        switch pillState {
        case .addable:
            addablePillView
                .transition(Motion.morph)
        case .added:
            statusPillView
                .transition(Motion.morph)
        }
    }

    // MARK: - State

    /// Namespaced key for the currently-open title. `MediaIDKey.make` treats TV and movie ids as
    /// distinct namespaces so a set of these can safely mix both.
    private var currentMediaKey: String? {
        guard let media = listItem.media, let id = Int(media.id) else { return nil }
        return MediaIDKey.make(listItem.tvShow != nil ? .tvShow : .movie, id)
    }

    private var isAlreadyInLibrary: Bool {
        guard let currentMediaKey else { return false }
        return existingIDs.contains(currentMediaKey)
    }

    /// Human name for the primary add target: the collection name when opened in an "add to
    /// collection" flow (Discover/similar from inside a collection), else "Up Next".
    private var primaryAddTarget: String { addTargetName ?? "Up Next" }

    private enum PillState {
        /// Big glass "Add to <target>" pill; not yet added.
        case addable
        /// Card-surface status chip: already in the target, or just added in this session.
        case added
    }

    private var pillState: PillState {
        // Any of these mean the title is already in whatever the current target is: it's a library
        // item (owned), a collection member, we just added it in this session, or the parent's
        // existingIDs already flags it.
        if isCollectionEntry || onAdd == nil || justAddedLocally || isAlreadyInLibrary {
            return .added
        }
        return .addable
    }

    // MARK: - Pill forms

    private var addablePillView: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    performPrimaryAdd()
                } label: {
                    Label("Add to \(primaryAddTarget)", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
                .accessibilityLabel("Add to \(primaryAddTarget)")

                pillMenuButton(glass: true)
            }
        }
    }

    private var statusPillView: some View {
        let pill = statusPill
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: pill.icon)
                    .font(.title3)
                    .foregroundStyle(pill.color)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: pill.icon)
                    .accessibilityHidden(true)

                Text(pill.title)
                    .font(.headline)
            }
            // The status reads as one element; the menu beside it stays separately focusable,
            // which a `.combine` on the whole row would swallow.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(pill.title)

            Spacer(minLength: 0)

            pillMenuButton(glass: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        .accessibilityElement(children: .contain)
    }

    /// The status pill's label reflects the *actual* state of the title, not just "On Up Next" —
    /// otherwise a show set to Watching reads "On Up Next" here while its own menu offers "Move to
    /// Up Next", which is confusing. Order: collection context > library state > browse.
    private var statusPill: (title: String, icon: String, color: Color) {
        // Collection contexts — a collection entry's only state is membership. `collectionName`
        // accompanies a collection entry; `addTargetName` names an add-to-collection flow.
        if let name = collectionName ?? addTargetName {
            return ("In \(name)", "checkmark.circle.fill", .green)
        }
        if listItem.list != nil {
            if listItem.isDropped { return ("Dropped", "xmark.circle.fill", .orange) }
            // Watching *and* fully watched is the "Caught up" row of the Watching section, not
            // plain Watched — calling it Watched would leave no way back out of Watching.
            if listItem.isWatching, listItem.isWatched {
                return ("Caught Up", "checkmark.circle.fill", Color.accentColor)
            }
            if listItem.isWatched { return ("Watched", "checkmark.circle.fill", .green) }
            if listItem.isWatching { return ("Watching", "play.circle.fill", Color.accentColor) }
            return ("On Up Next", "bookmark.circle.fill", Color.accentColor)
        }
        // Browse context: the transient ListItem carries no library state, but the title is on Up
        // Next either way — a fresh add gets the confirming check, an existing one the bookmark.
        if justAddedLocally { return ("On Up Next", "checkmark.circle.fill", .green) }
        return ("On Up Next", "bookmark.circle.fill", Color.accentColor)
    }

    // MARK: - Menu

    /// The pill's overflow menu. Beside the `.glassProminent` Add button it takes glass too (it's
    /// already inside that `GlassEffectContainer`), otherwise a bare glyph reads as decoration.
    /// On the status chip — a card surface — glass on glass isn't allowed, so it stays plain.
    @ViewBuilder
    private func pillMenuButton(glass: Bool) -> some View {
        if glass {
            Menu {
                pillMenuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(minWidth: 20, minHeight: 44)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("More options")
        } else {
            Menu {
                pillMenuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
        }
    }

    @ViewBuilder
    private var pillMenuContent: some View {
        libraryStateActions

        if !collectionMenuEntries.isEmpty {
            Section("Collections") {
                ForEach(collectionMenuEntries) { entry in
                    Button(action: entry.toggle) {
                        if entry.isMember {
                            Label(entry.name, systemImage: "checkmark")
                        } else {
                            Text(entry.name)
                        }
                    }
                }
            }
        }

        if canRemoveFromPill {
            // Plain Text (no `Label` with icon) so the destructive item renders on one line at
            // any menu width — the icon+text pair wrapped in narrow menus.
            Button(role: .destructive) {
                isConfirmingRemoval = true
            } label: {
                Text(destructiveMenuLabel)
            }
        }
    }

    private var destructiveMenuLabel: String {
        if let removeLabel { return removeLabel }
        return "Remove from Up Next"
    }

    /// Present a Remove menu item whenever there's something to remove: a library-owned title or a
    /// collection member. A browse/add context has nothing to remove yet.
    private var canRemoveFromPill: Bool {
        isCollectionEntry || onAdd == nil
    }

    // MARK: - State transitions

    /// State-transition actions for library-owned titles — the pill's menu is the one place these
    /// live. The old on-page toggle cards (watching / watched / done-watching) were deleted: they
    /// offered "Move to Up Next" directly beneath a "Watching" status pill, which read as a
    /// contradiction. Do not reintroduce them.
    @ViewBuilder
    private var libraryStateActions: some View {
        // Only library-owned items get state actions. Browse/add and collection contexts skip.
        if listItem.list != nil, !isCollectionEntry {
            Section {
                if listItem.tvShow != nil {
                    tvStateActions
                } else if listItem.movie != nil {
                    movieStateActions
                }
            }
        }
    }

    @ViewBuilder
    private var tvStateActions: some View {
        if listItem.isDropped {
            Button {
                applyStateChange { listItem.resumeShow() }
            } label: { Label("Pick Back Up", systemImage: "arrow.uturn.forward.circle") }
            Button {
                markLibraryWatched()
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        } else if listItem.isWatching, listItem.isWatched {
            // Caught up: still in Watching, nothing left to watch. Without this the only offer was
            // "Mark as Unwatched", leaving no way to close the show out.
            Button {
                applyStateChange { listItem.watchingStartedAt = nil }
            } label: { Label("Move to Watched", systemImage: "checkmark.circle") }
            Button {
                markLibraryUnwatched()
            } label: { Label("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle") }
        } else if listItem.isWatched {
            Button {
                markLibraryUnwatched()
            } label: { Label("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle") }
        } else if listItem.isWatching {
            Button {
                applyStateChange { listItem.toggleWatching() }
            } label: { Label("Move to Up Next", systemImage: "list.bullet.circle") }
            Button {
                markLibraryWatched()
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
            dropShowAction
        } else {
            // On Up Next
            Button {
                applyStateChange { listItem.toggleWatching() }
            } label: { Label("Start Watching", systemImage: "play.circle") }
            Button {
                markLibraryWatched()
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
            dropShowAction
        }
    }

    /// Giving up on a show part-way: it moves to Watched keeping its season progress, and can be
    /// resumed with "Pick Back Up". This is the only entry point to `dropShow()`.
    private var dropShowAction: some View {
        Button {
            applyStateChange { listItem.dropShow() }
        } label: { Label("Drop Show", systemImage: "xmark.circle") }
    }

    @ViewBuilder
    private var movieStateActions: some View {
        if listItem.isWatched {
            Button {
                markLibraryUnwatched()
            } label: { Label("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle") }
        } else {
            Button {
                markLibraryWatched()
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
        }
    }

    /// One animation (reduce-motion gated) and one save for every state transition the menu offers,
    /// plus the stamp `SeasonChecklistCard` uses to tell a local edit from a partner's. Only the
    /// watched marks are logged as activity — Start Watching / Drop / Pick Back Up aren't worth a
    /// ping to the other person.
    private func applyStateChange(logsWatchedActivity: Bool = false, _ change: () -> Void) {
        lastLocalWatchedEdit = .now
        withAnimation(reduceMotion ? nil : Motion.pop, change)
        if logsWatchedActivity {
            PersistenceController.shared.recordWatchedActivity(for: listItem)
        }
        PersistenceController.shared.save()
    }

    /// Marks the current library item watched: aired seasons filled, `isWatched` on, `watchedAt`
    /// now. Also finalises Watching (clears `watchingStartedAt`) and reverses any drop, so the
    /// state ends cleanly at "Watched" instead of the "watching+watched" limbo.
    private func markLibraryWatched() {
        applyStateChange(logsWatchedActivity: true) {
            listItem.droppedAt = nil
            listItem.watchingStartedAt = nil
            if let tvShow = listItem.tvShow, let total = tvShow.numberOfSeasons, total > 0 {
                // Aired seasons only — a check against a "Premieres …" row claims the user watched
                // something that doesn't exist yet. Matches `ListItem.toggleWatched()`.
                listItem.watchedSeasons = Array(1...max(1, tvShow.availableSeasonCount))
            }
            listItem.isWatched = true
            listItem.watchedAt = .now
        }
    }

    private func markLibraryUnwatched() {
        applyStateChange(logsWatchedActivity: true) {
            listItem.droppedAt = nil
            if let tvShow = listItem.tvShow, (tvShow.numberOfSeasons ?? 0) > 0 {
                listItem.watchedSeasons = []
            }
            listItem.isWatched = false
            listItem.watchedAt = nil
        }
    }

    // MARK: - Collections

    private struct PillCollectionEntry: Identifiable {
        /// The `CustomList`'s stable UUID (`CustomList.id`) — no CoreData types leak into this view.
        let id: String
        let name: String
        let isMember: Bool
        let toggle: () -> Void
    }

    private var collectionMenuEntries: [PillCollectionEntry] {
        guard let vm = customListViewModel else { return [] }
        guard let mediaID = listItem.media?.id else { return [] }
        // Read changeToken so the menu re-derives its check marks when collections mutate.
        _ = vm.changeToken
        return vm.customLists.map { list in
            let isMember = vm.containsItem(mediaID: mediaID, mediaType: listItem.tvShow == nil ? .movie : .tvShow, in: list)
            return PillCollectionEntry(
                id: list.id.uuidString,
                name: list.name,
                isMember: isMember
            ) {
                toggleCollectionMembership(mediaID: mediaID, list: list, currentlyMember: isMember)
            }
        }
    }

    private func toggleCollectionMembership(mediaID: String, list: CustomList, currentlyMember: Bool) {
        guard let vm = customListViewModel else { return }
        if currentlyMember {
            if let item = vm.item(mediaID: mediaID, mediaType: listItem.tvShow == nil ? .movie : .tvShow, in: list) {
                let title = vm.removeItem(item, from: list) ?? listItem.media?.title ?? "Title"
                // Same deferred-removal window as a swipe in the collection itself, so a mistap
                // here is just as recoverable.
                toast.show(
                    "Removed \(title) from \(list.name)",
                    icon: "trash.circle.fill",
                    actionLabel: "Undo",
                    feedback: .impact
                ) {
                    vm.undoLastRemoval()
                }
            }
        } else {
            vm.addItem(movie: listItem.movie, tvShow: listItem.tvShow, to: list)
            let title = listItem.media?.title ?? "Title"
            toast.show("Added \(title) to \(list.name)")
        }
    }

    // MARK: - Add

    /// The pill's primary-tap action for the addable state. Fires the parent's `onAdd`, shows a
    /// confirmation toast, and flips the pill to its status style in place — the sheet stays open
    /// so the user can keep reading and/or add to collections.
    private func performPrimaryAdd() {
        guard let onAdd else { return }
        onAdd()
        if let title = listItem.media?.title {
            toast.show(addedToastMessage(title, target: addTargetName))
        }
        withAnimation(reduceMotion ? nil : Motion.pop) {
            justAddedLocally = true
        }
    }
}
