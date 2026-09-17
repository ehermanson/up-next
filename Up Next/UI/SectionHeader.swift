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
        showsMyServicesFilter: Bool = false
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
    }

    private var hasActiveFilter: Bool {
        selectedGenre != nil || selectedProviderCategory != nil || onlyMyServices
    }

    /// The filter menu is worth showing as soon as *any* of its sections has something to offer.
    private var hasFilterOptions: Bool {
        showsMyServicesFilter || !availableGenres.isEmpty || !availableProviderCategories.isEmpty
    }

    var body: some View {
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
                    .accessibilityLabel("\(count) items")
            }
            Spacer()
            if showsFilter, hasFilterOptions {
                Menu {
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
                .accessibilityLabel("Filter")
            }
        }
        .padding(.vertical, 4)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
