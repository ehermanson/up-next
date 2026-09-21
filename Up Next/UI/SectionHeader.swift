import SwiftUI

/// Shared section-header style for watchlist/collection surfaces: bold title, optional leading
/// icon, optional count chip, and (watchlist only) a trailing filter `Menu`. One style so
/// "Up Next" / "Watched" / the upcoming strip / a collection's "Watched" all read the same.
struct SectionHeader: View {
    let title: String
    /// `nil` omits the count chip entirely (the upcoming strip has no count to show).
    var count: Int? = nil
    /// Leading symbol, e.g. the upcoming strip's calendar glyph.
    var icon: String? = nil
    var showsFilter: Bool = true
    var availableGenres: [String] = []
    @Binding var selectedGenre: String?
    var availableProviderCategories: [String] = []
    @Binding var selectedProviderCategory: String?
    @Binding var onlyMyServices: Bool
    var showsMyServicesFilter: Bool = false
    /// Non-nil turns the whole header into a disclosure control — a full-width button that toggles
    /// this binding, with a trailing chevron that rotates to reflect state (the watchlist's
    /// "Watched" header). `nil` (the default) renders a plain, non-interactive header.
    var isExpanded: Binding<Bool>? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        count: Int? = nil,
        icon: String? = nil,
        showsFilter: Bool = true,
        availableGenres: [String] = [],
        selectedGenre: Binding<String?> = .constant(nil),
        availableProviderCategories: [String] = [],
        selectedProviderCategory: Binding<String?> = .constant(nil),
        onlyMyServices: Binding<Bool> = .constant(false),
        showsMyServicesFilter: Bool = false,
        isExpanded: Binding<Bool>? = nil
    ) {
        self.title = title
        self.count = count
        self.icon = icon
        self.showsFilter = showsFilter
        self.availableGenres = availableGenres
        self._selectedGenre = selectedGenre
        self.availableProviderCategories = availableProviderCategories
        self._selectedProviderCategory = selectedProviderCategory
        self._onlyMyServices = onlyMyServices
        self.showsMyServicesFilter = showsMyServicesFilter
        self.isExpanded = isExpanded
    }

    private var hasActiveFilter: Bool {
        selectedGenre != nil || selectedProviderCategory != nil || onlyMyServices
    }

    /// The filter menu is worth showing as soon as *any* of its sections has something to offer.
    private var hasFilterOptions: Bool {
        showsMyServicesFilter || !availableGenres.isEmpty || !availableProviderCategories.isEmpty
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }

    var body: some View {
        Group {
            if let isExpanded {
                Button {
                    withAnimation(disclosureAnimation) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    headerRow(chevronExpanded: isExpanded.wrappedValue)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(.rect)
                .animation(disclosureAnimation, value: isExpanded.wrappedValue)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count.map { "\(title), \($0) titles" } ?? title)
                .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded.wrappedValue ? "Hide \(title.lowercased()) titles" : "Show \(title.lowercased()) titles")
            } else {
                headerRow(chevronExpanded: nil)
            }
        }
        .padding(.vertical, 4)
        .textCase(nil)
        .listRowInsets(EdgeInsets(
            top: 8,
            leading: DesignTokens.Spacing.screenInset,
            bottom: 4,
            trailing: DesignTokens.Spacing.screenInset
        ))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func headerRow(chevronExpanded: Bool?) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            }
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            if let count {
                Chip(text: "\(count)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(count) titles")
            }
            Spacer()
            if showsFilter, hasFilterOptions {
                Menu {
                    if hasActiveFilter {
                        Button("Clear Filters", systemImage: "xmark.circle") {
                            onlyMyServices = false
                            selectedProviderCategory = nil
                            selectedGenre = nil
                        }
                    }
                    if showsMyServicesFilter {
                        Section {
                            Button {
                                onlyMyServices.toggle()
                            } label: {
                                if onlyMyServices {
                                    Label("On my services", systemImage: "checkmark")
                                } else {
                                    Text("On my services")
                                }
                            }
                        }
                    }
                    if availableProviderCategories.count > 1 {
                        Section("Watch Option") {
                            Button {
                                selectedProviderCategory = nil
                            } label: {
                                if selectedProviderCategory == nil {
                                    Label("All", systemImage: "checkmark")
                                } else {
                                    Text("All")
                                }
                            }
                            ForEach(availableProviderCategories, id: \.self) { category in
                                Button {
                                    selectedProviderCategory = category
                                } label: {
                                    if selectedProviderCategory == category {
                                        Label(category, systemImage: "checkmark")
                                    } else {
                                        Text(category)
                                    }
                                }
                            }
                        }
                    }
                    if !availableGenres.isEmpty {
                        Section("Genre") {
                            Button {
                                selectedGenre = nil
                            } label: {
                                if selectedGenre == nil {
                                    Label("All", systemImage: "checkmark")
                                } else {
                                    Text("All")
                                }
                            }
                            ForEach(availableGenres, id: \.self) { genre in
                                Button {
                                    selectedGenre = genre
                                } label: {
                                    if selectedGenre == genre {
                                        Label(genre, systemImage: "checkmark")
                                    } else {
                                        Text(genre)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Chip(
                        icon: hasActiveFilter
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle",
                        text: "Filter",
                        isEmphasized: hasActiveFilter
                    )
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                // A Menu tints its label with the accent color, so the chip's `.secondary` text
                // would resolve to "secondary purple"; pin the tint so it reads like every other chip.
                .tint(.primary)
                .accessibilityLabel("Filter")
                .accessibilityValue(activeFilterDescription)
            }
            if let chevronExpanded {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .rotationEffect(.degrees(chevronExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }

    /// Read by VoiceOver as the filter button's `accessibilityValue` — "None" when nothing's
    /// active, else the applied filters in the same order the Menu lists its sections.
    private var activeFilterDescription: String {
        var parts: [String] = []
        if onlyMyServices { parts.append("On my services") }
        if let selectedProviderCategory { parts.append(selectedProviderCategory) }
        if let selectedGenre { parts.append(selectedGenre) }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }
}
