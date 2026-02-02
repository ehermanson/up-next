import Foundation
import SwiftData

@MainActor
@Observable
final class CustomListViewModel {
    var customLists: [CustomList] = []
    var activeListID: UUID?

    private var modelContext: ModelContext?

    func configure(modelContext: ModelContext) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        loadLists()
    }

    func createList(name: String, iconName: String) {
        guard let context = modelContext else { return }
        let list = CustomList(name: name, iconName: iconName)
        context.insert(list)
        customLists.append(list)
        save()
    }

    func deleteList(_ list: CustomList) {
        guard let context = modelContext else { return }
        customLists.removeAll { $0.id == list.id }
        context.delete(list)
        save()
    }

    func updateList(_ list: CustomList, name: String, iconName: String) {
        list.name = name
        list.iconName = iconName
        save()
    }

    func addItem(movie: Movie? = nil, tvShow: TVShow? = nil, to list: CustomList) {
        guard let context = modelContext else { return }
        let mediaID = movie?.id ?? tvShow?.id
        guard let mediaID else { return }
        guard !containsItem(mediaID: mediaID, in: list) else { return }

        let item = CustomListItem(movie: movie, tvShow: tvShow, customList: list, addedAt: Date())
        context.insert(item)
        list.items.append(item)
        save()
    }

    func removeItem(_ item: CustomListItem, from list: CustomList) {
        guard let context = modelContext else { return }
        list.items.removeAll { $0.persistentModelID == item.persistentModelID }
        context.delete(item)
        save()
    }

    func containsItem(mediaID: String, in list: CustomList) -> Bool {
        list.items.contains { $0.media?.id == mediaID }
    }

    // MARK: - Private

    private func loadLists() {
        guard let context = modelContext else { return }
        do {
            let descriptor = FetchDescriptor<CustomList>(
                sortBy: [SortDescriptor(\CustomList.createdAt, order: .forward)]
            )
            customLists = try context.fetch(descriptor)
        } catch {
            #if DEBUG
                print("Failed to load custom lists: \(error)")
            #endif
        }
    }

    private func save() {
        guard let context = modelContext else { return }
        do {
            try context.save()
        } catch {
            #if DEBUG
                print("Failed to save custom list changes: \(error)")
            #endif
        }
    }
}
