import SwiftUI

/// Navigation value for a tapped cast member. The persisted cast is names only, so the id comes
/// from the detail sheet's own TMDB fetch (see `MediaDetailView.castPersonIDs`).
struct CastPersonRoute: Hashable {
    let id: Int
    let name: String
}

/// Read-only page for one cast member, pushed inside the detail sheet: photo, a few facts, the
/// biography, and the titles they've acted in. Fetched from `/person/{id}` on demand; nothing is
/// persisted. Tapping a title pushes its detail page onto the same stack, like "More Like This".
struct PersonDetailView: View {
    let person: CastPersonRoute
    /// Type-namespaced IDs already on the watchlist (see `MediaIDKey`), handed down from the sheet.
    var existingIDs: Set<String> = []
    var onTVShowAdded: ((TVShow) -> Void)?
    var onMovieAdded: ((Movie) -> Void)?
    var addTargetName: String?
    /// Closes the whole detail sheet, not just this page.
    var dismiss: (() -> Void)?

    @State private var detail: TMDBPersonDetail?
    @State private var credits: [TMDBPersonCredit] = []
    @State private var isLoading = false
    @State private var loadGeneration = UUID()
    @State private var loadError: String?
    @State private var selectedItem: ListItem?
    @State private var selectedSourceID = ""
    @State private var addedIDs: Set<String> = []
    @Namespace private var namespace

    private let service = TMDBService.shared

    var body: some View {
        let knownIDs = existingIDs.union(addedIDs)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                header

                if isLoading && detail == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let loadError {
                    EmptyStateView(
                        icon: "wifi.exclamationmark",
                        title: "Couldn’t Load Details",
                        subtitle: loadError
                    ) {
                        Button("Try Again") {
                            Task { await load() }
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(.top, 40)
                } else {
                    if let biography = detail?.biography, !biography.isEmpty {
                        ClampedDescriptionText(text: biography, lineLimit: 6)
                    }

                    knownForSection(knownIDs: knownIDs)
                    creditsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
            // Matches `MediaDetailView`'s readable column on the iPad page sheet.
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { AppBackground() }
        // The header already shows the name; like the detail page, the bar carries only Back and Done.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let dismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
        .task(id: person.id) {
            await load()
        }
        .navigationDestination(item: $selectedItem) { item in
            MediaDetailView(
                listItem: item,
                dismiss: dismiss ?? {},
                onRemove: { selectedItem = nil },
                onAdd: canAddToLibrary ? { addFromDetail(item) } : nil,
                existingIDs: knownIDs,
                onTVShowAdded: onTVShowAdded,
                onMovieAdded: onMovieAdded,
                addTargetName: addTargetName,
                isPushed: true
            )
            .navigationTransition(.zoom(sourceID: selectedSourceID, in: namespace))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            profileImage
                .frame(width: 110, height: 150)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.posterCard))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(detail?.name ?? person.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .fixedSize(horizontal: false, vertical: true)

                // Only when it says something: everyone reached from a cast row acted, so "Acting"
                // is noise, but "Directing" or "Writing" tells you who this mostly is.
                if let department = detail?.knownForDepartment, !department.isEmpty, department != "Acting" {
                    Chip(text: department)
                }

                ForEach(facts, id: \.self) { fact in
                    Text(fact)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var profileImage: some View {
        if let url = service.imageURL(path: detail?.profilePath, size: .w342) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    profilePlaceholder
                }
            }
        } else {
            profilePlaceholder
        }
    }

    private var profilePlaceholder: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
    }

    /// "Born March 3, 1970 (age 56)", "Died …", "Place of birth" — whatever TMDB has.
    private var facts: [String] {
        guard let detail else { return [] }
        let born = detail.birthday.flatMap(AirDateFormat.date(from:))
        let died = detail.deathday.flatMap(AirDateFormat.date(from:))
        var lines: [String] = []
        if let born {
            let age = Self.years(from: born, to: died ?? .now)
            lines.append(died == nil ? "Born \(Self.format(born)) (age \(age))" : "Born \(Self.format(born))")
        }
        if let died {
            let age = born.map { " (aged \(Self.years(from: $0, to: died)))" } ?? ""
            lines.append("Died \(Self.format(died))\(age)")
        }
        if let place = detail.placeOfBirth, !place.isEmpty {
            lines.append(place)
        }
        return lines
    }

    private static func format(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }

    private static func years(from start: Date, to end: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.dateComponents([.year], from: start, to: end).year ?? 0
    }

    // MARK: - Credits

    /// Their best-known titles: the most-voted ones they had a real part in. Raw vote count alone
    /// puts a one-episode voice cameo on The Simpsons or a 76th-billed movie role up front, so TV
    /// needs a few episodes and movies a top-15 billing.
    private var knownFor: [TMDBPersonCredit] {
        let substantial = credits.filter { credit in
            credit.isTV ? (credit.episodeCount ?? 0) >= 3 : (credit.order ?? 0) < 15
        }
        return Array(substantial.sorted { ($0.voteCount ?? 0) > ($1.voteCount ?? 0) }.prefix(10))
    }

    @ViewBuilder
    private func knownForSection(knownIDs: Set<String>) -> some View {
        // Filtered by `knownFor`'s own bar, so check the result, not just the credit count — a
        // career of guest spots can pass one and leave the other empty.
        let knownFor = self.knownFor
        if credits.count > 3, !knownFor.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Known For")
                    .font(.headline)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(knownFor, id: \.key) { credit in
                            PosterCard(
                                posterPath: credit.posterPath,
                                title: credit.displayTitle,
                                subtitle: credit.year,
                                isAdded: knownIDs.contains(credit.key),
                                onTap: { open(credit, sourcePrefix: "knownFor") },
                                transitionSource: (id: "knownFor:" + credit.key, namespace: namespace)
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private var creditsSection: some View {
        if credits.isEmpty {
            if detail != nil {
                Text("No acting credits on TMDB yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            // Lazy, so rows (and their poster fetches) load as they scroll in rather than all at
            // once — a long career runs to hundreds of credits.
            LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.rowGap) {
                Text("Credits")
                    .font(.headline)

                ForEach(credits, id: \.key) { credit in
                    creditRow(credit)
                }
            }
        }
    }

    private func creditRow(_ credit: TMDBPersonCredit) -> some View {
        Button {
            open(credit, sourcePrefix: "credit")
        } label: {
            HStack(spacing: 12) {
                creditPoster(credit)

                VStack(alignment: .leading, spacing: 4) {
                    Text(credit.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(creditMeta(credit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if (credit.voteCount ?? 0) > 0, let vote = credit.voteAverage, vote > 0 {
                            StarRatingLabel(vote: vote)
                        }
                    }

                    if let character = credit.character, !character.isEmpty {
                        Text("as \(character)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cardSurface(cornerRadius: DesignTokens.Radius.cardCompact)
        .matchedTransitionSource(id: "credit:" + credit.key, in: namespace)
    }

    private func creditPoster(_ credit: TMDBPersonCredit) -> some View {
        Group {
            if let url = service.imageURL(path: credit.posterPath, size: .w185) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(.fill.tertiary)
                    }
                }
            } else {
                Rectangle()
                    .fill(.fill.tertiary)
                    .overlay {
                        Image(systemName: "film")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 46, height: 69)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.posterSmall))
        .accessibilityHidden(true)
    }

    /// "2023 · Movie", "2019 · TV Show · 8 episodes".
    private func creditMeta(_ credit: TMDBPersonCredit) -> String {
        var parts: [String] = []
        parts.append(credit.year ?? "TBA")
        parts.append(credit.isTV ? "TV Show" : "Movie")
        if credit.isTV, let episodes = credit.episodeCount, episodes > 0 {
            parts.append(episodes == 1 ? "1 episode" : "\(episodes) episodes")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Loading

    private func load() async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        loadError = nil
        do {
            let fetched = try await service.getPersonDetails(id: person.id)
            guard !Task.isCancelled else { return }
            detail = fetched
            credits = Self.actingCredits(from: fetched.combinedCredits?.cast ?? [])
        } catch {
            guard !Task.isCancelled else { return }
            loadError = "Check your connection and try again."
        }
    }

    /// TMDB's talk (10767) and news (10763) genres — guest spots on those, and any role credited as
    /// themselves, aren't "stuff they've been in" in the sense this page means.
    private static let appearanceGenreIDs: Set<Int> = [10767, 10763]

    /// Movies and shows they acted in, newest first (undated projects last), one row per title.
    /// TMDB lists a separate credit per character, so those merge: characters joined, episodes
    /// summed, and the earliest appearance kept as the date.
    static func actingCredits(from cast: [TMDBPersonCredit]) -> [TMDBPersonCredit] {
        var merged: [TMDBPersonCredit] = []
        var indexByKey: [String: Int] = [:]
        for credit in cast {
            guard credit.mediaType == "movie" || credit.mediaType == "tv",
                  credit.adult != true,
                  !credit.displayTitle.isEmpty,
                  appearanceGenreIDs.isDisjoint(with: credit.genreIds ?? []),
                  !credit.isSelf
            else { continue }
            guard let index = indexByKey[credit.key] else {
                indexByKey[credit.key] = merged.count
                merged.append(credit)
                continue
            }
            var existing = merged[index]
            if let character = credit.character, !character.isEmpty,
               existing.character?.localizedCaseInsensitiveContains(character) != true {
                existing.character = [existing.character, character]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " / ")
            }
            if let episodes = credit.episodeCount {
                existing.episodeCount = (existing.episodeCount ?? 0) + episodes
            }
            if existing.isTV, let date = credit.firstCreditAirDate,
               existing.firstCreditAirDate.map({ date < $0 }) ?? true {
                existing.firstCreditAirDate = date
            }
            merged[index] = existing
        }
        return merged.sorted { lhs, rhs in
            // `yyyy-MM-dd` strings sort chronologically as-is — no date parsing in the comparator.
            switch (lhs.creditDate, rhs.creditDate) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (lhs.voteCount ?? 0) > (rhs.voteCount ?? 0)
            }
        }
    }

    // MARK: - Actions

    private var canAddToLibrary: Bool {
        onTVShowAdded != nil || onMovieAdded != nil
    }

    private func open(_ credit: TMDBPersonCredit, sourcePrefix: String) {
        selectedSourceID = "\(sourcePrefix):" + credit.key
        let posterURL = service.imageURL(path: credit.posterPath)
        if credit.isTV {
            let tvShow = TVShow(id: String(credit.id), title: credit.displayTitle, thumbnailURL: posterURL, voteAverage: credit.voteAverage)
            selectedItem = ListItem(tvShow: tvShow)
        } else {
            let movie = Movie(id: String(credit.id), title: credit.displayTitle, thumbnailURL: posterURL, voteAverage: credit.voteAverage)
            selectedItem = ListItem(movie: movie)
        }
    }

    /// Mirrors `MediaDetailView.addSimilarFromDetail`: the pushed page's Add pill already toasts.
    private func addFromDetail(_ item: ListItem) {
        guard let media = item.media else { return }
        let key = MediaIDKey.make(item.tvShow != nil ? .tvShow : .movie, media.id)
        guard !existingIDs.contains(key), !addedIDs.contains(key) else { return }
        addedIDs.insert(key)
        if let tvShow = item.tvShow {
            onTVShowAdded?(tvShow)
        } else if let movie = item.movie {
            onMovieAdded?(movie)
        }
    }
}

private extension TMDBPersonCredit {
    var isTV: Bool { mediaType == "tv" }

    var key: String { MediaIDKey.make(isTV ? .tvShow : .movie, id) }

    /// "Self", "Himself", "Herself - Guest", "Self (archive footage)".
    var isSelf: Bool {
        guard let character = character?.lowercased() else { return false }
        return ["self", "himself", "herself", "themselves", "themself"].contains { character.hasPrefix($0) }
    }
}
