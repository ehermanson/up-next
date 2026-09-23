import CloudKit
import CoreData
import SwiftUI

/// Settings → Activity: the shared history of adds, removals, watched marks and collection edits,
/// newest first and grouped by day — yours and the other person's. Reads the same `ActivityEvent`s
/// that drive `RemoteActivityNotifier`, so a notification that was missed (the phone was off, the
/// event went stale) is still here.
struct ActivityView: View {
    private let persistence = PersistenceController.shared

    /// Who did it. Decided by `actorRecordName` against this account's user record name — a
    /// stored attribute, so it's a plain filter rather than a record lookup per row. Events with
    /// no `actorRecordName` (written offline, before the name was fetched) only appear under
    /// Everyone.
    enum PersonFilter: String, CaseIterable, Identifiable {
        case everyone, you, other
        var id: String { rawValue }
    }

    enum KindFilter: String, CaseIterable, Identifiable {
        case everything, added, removed, watched, collections
        var id: String { rawValue }

        var label: String {
            switch self {
            case .everything: "Everything"
            case .added: "Added"
            case .removed: "Removed"
            case .watched: "Watched"
            case .collections: "Collections"
            }
        }

        func matches(_ kind: ActivityEvent.Kind?) -> Bool {
            switch self {
            case .everything: true
            case .added: kind == .added || kind == .collectionAdded
            case .removed: kind == .removed || kind == .collectionRemoved
            case .watched: kind == .watched || kind == .unwatched
            case .collections:
                [.collectionAdded, .collectionRemoved, .collectionCreated, .collectionDeleted, .collectionRenamed].contains { $0 == kind }
            }
        }
    }

    @State private var personFilter: PersonFilter = .everyone
    @State private var kindFilter: KindFilter = .everything

    private var isFiltering: Bool { personFilter != .everyone || kindFilter != .everything }

    /// Newest first, capped — the log itself is pruned to 500 at launch.
    private var allEvents: [ActivityEvent] {
        // Read so the screen re-derives when the other person's events import.
        _ = persistence.remoteChangeCount
        guard let group = persistence.group, group.managedObjectContext != nil, !group.isDeleted else { return [] }
        return (group.activities ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(300)
            .map { $0 }
    }

    private var events: [ActivityEvent] {
        let me = persistence.currentUserRecordName
        return allEvents.filter { event in
            guard kindFilter.matches(event.kind) else { return false }
            switch personFilter {
            case .everyone: return true
            case .you: return me != nil && event.actorRecordName == me
            case .other: return event.actorRecordName != nil && event.actorRecordName != me
            }
        }
    }

    private var otherName: String {
        persistence.liveShare?.otherDisplayName ?? "Them"
    }

    var body: some View {
        ActivityTimeline(
            events: events,
            emptyTitle: isFiltering ? "No Matches" : "No Activity Yet",
            emptySubtitle: isFiltering
                ? "Nothing in the log matches these filters."
                : "Adds, removals and watched marks show up here — yours and the other person’s.",
            onClearFilters: isFiltering ? { personFilter = .everyone; kindFilter = .everything } : nil
        )
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Same shape as the watchlist's Filter menu (`SectionHeader`): sections, a
                // filled glyph while anything is active, Clear Filters at the bottom.
                Menu {
                    Picker("Who", selection: $personFilter) {
                        Text("Everyone").tag(PersonFilter.everyone)
                        Text("You").tag(PersonFilter.you)
                        Text(otherName).tag(PersonFilter.other)
                    }
                    Picker("What", selection: $kindFilter) {
                        ForEach(KindFilter.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    if isFiltering {
                        Divider()
                        Button("Clear Filters", systemImage: "xmark.circle") {
                            personFilter = .everyone
                            kindFilter = .everything
                        }
                    }
                } label: {
                    Label("Filter", systemImage: isFiltering
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    /// Who an event belongs to, as a sentence subject. The CloudKit record's creator decides:
    /// `CKCurrentUserDefaultName` — or no record yet, i.e. written here and not exported — is
    /// "You". A store round-trip; callers resolve it once per row, off the first render.
    static func actor(for event: ActivityEvent, persistence: PersistenceController) -> String {
        guard let record = persistence.container.record(for: event.objectID),
              let creator = record.creatorUserRecordID,
              creator.recordName != CKCurrentUserDefaultName
        else { return "You" }
        // `liveShare` rather than `otherPersonDisplayName()`: same answer, without a share fetch
        // per row. iOS may withhold the name here while the writer knew its own.
        return persistence.liveShare?.otherDisplayName ?? event.actorName ?? "Someone"
    }
}

/// The scrolling body, split out so the preview can feed it context-less sample events.
struct ActivityTimeline: View {
    let events: [ActivityEvent]
    var emptyTitle = "No Activity Yet"
    var emptySubtitle: String? = "Adds, removals and watched marks show up here — yours and the other person’s."
    /// Present while filters are active: the empty state offers to clear them.
    var onClearFilters: (() -> Void)?
    /// Preview only: skips the CloudKit record lookup and uses this subject for every row.
    var fixedActor: String?

    private var days: [(day: Date, events: [ActivityEvent])] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.createdAt) }
        return byDay.keys.sorted(by: >).map { day in
            (day, byDay[day, default: []].sorted { $0.createdAt > $1.createdAt })
        }
    }

    var body: some View {
        ScrollView {
            if events.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", title: emptyTitle, subtitle: emptySubtitle) {
                    if let onClearFilters {
                        Button("Clear Filters", action: onClearFilters)
                            .buttonStyle(.glass)
                    }
                }
                .padding(.top, 80)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(days, id: \.day) { section in
                        SectionHeader(title: Self.dayLabel(for: section.day), showsFilter: false)
                            .padding(.top, 8)
                        ForEach(section.events) { event in
                            ActivityRow(event: event, fixedActor: fixedActor)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(AppBackground())
    }

    private static func dayLabel(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    let fixedActor: String?

    @State private var actor: String?

    private var icon: (name: String, tint: Color) {
        switch event.kind {
        case .added: ("plus.circle", Color.accentColor)
        case .removed: ("minus.circle", .orange)
        case .watched: ("checkmark.circle", Color.accentColor)
        case .unwatched: ("circle", Color.accentColor)
        case .collectionAdded, .collectionRemoved, .collectionCreated, .collectionDeleted, .collectionRenamed, nil:
            ("folder", Color.accentColor)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(icon.tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                // Placeholder-redacted until the creator lookup lands, so the subject never
                // flashes "Someone" before settling on "You".
                Text(event.sentence(actor: actor ?? fixedActor ?? "Someone"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .redacted(reason: actor == nil && fixedActor == nil ? .placeholder : [])
                Text(event.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        .accessibilityElement(children: .combine)
        .task(id: event.objectID, priority: .utility) {
            guard fixedActor == nil else { return }
            actor = ActivityView.actor(for: event, persistence: .shared)
        }
    }
}

#Preview {
    let group: WatchListGroup? = nil
    let events = [
        ActivityEvent(kind: .removed, title: "Hijack", mediaKey: "tv:201834", contextName: "TV Shows", createdAt: .now.addingTimeInterval(-120), group: group),
        ActivityEvent(kind: .watched, title: "Elf", mediaKey: "movie:10719", contextName: "Christmas Stuff", createdAt: .now.addingTimeInterval(-3_600), group: group),
        ActivityEvent(kind: .added, title: "Dune: Part Two", mediaKey: "movie:693134", contextName: "Movies", createdAt: .now.addingTimeInterval(-90_000), group: group),
    ]
    NavigationStack {
        ActivityTimeline(events: events, fixedActor: "Erika")
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
    }
}
