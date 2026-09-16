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
        #if DEBUG
        // App Store screenshot capture (`--screenshots`, see ScreenshotMode): an in-memory,
        // non-CloudKit store so seeded data never touches the real local/CloudKit store and every
        // launch starts from a clean slate.
        if ScreenshotMode.isEnabled {
            let screenshotConfiguration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: screenshotConfiguration)
            } catch {
                fatalError("Could not create in-memory ModelContainer for screenshot mode: \(error)")
            }
        }
        #endif

        let configuration = ModelConfiguration(
            "Watch_List",
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            // ⚠️ CloudKit sync is DISABLED — falling back to local-only store
            print("⚠️ CloudKit ModelContainer failed, falling back to local-only: \(error)")
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

    @State private var toastState = ToastState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(toastState)
                .preferredColorScheme(.dark)
                .fontDesign(.rounded)
        }
        .modelContainer(sharedModelContainer)
    }
}
