import SwiftData
import SwiftUI

@main
struct Watch_ListApp: App {
    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Movie.self,
            TVShow.self,
            Network.self,
            MediaList.self,
            ListItem.self,
            UserIdentity.self,
            WatchListGroup.self,
            CustomList.self,
            CustomListItem.self,
        ])
        let configuration = ModelConfiguration("Watch_List")
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
