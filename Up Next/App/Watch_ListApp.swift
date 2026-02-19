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
            // Fall back to local-only store
            let localOnly = ModelConfiguration("Watch_List", cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: localOnly)
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()
    
    private func loadRocketSimConnect() {
        #if DEBUG
        guard (Bundle(path: "/Applications/RocketSim.app/Contents/Frameworks/RocketSimConnectLinker.nocache.framework")?.load() == true) else {
            print("Failed to load linker framework")
            return
        }
        print("RocketSim Connect successfully linked")
        #endif
    }
    
    init() {
        loadRocketSimConnect()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
