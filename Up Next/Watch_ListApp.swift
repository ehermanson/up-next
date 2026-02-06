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
        let configuration = ModelConfiguration(
            "Watch_List",
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            print("CloudKit ModelContainer failed: \(error)")
            // Fall back to local-only store
            let localOnly = ModelConfiguration("Watch_List", cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: localOnly)
            } catch {
                print("Local ModelContainer also failed: \(error)")
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
