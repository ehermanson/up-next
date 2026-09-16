import SwiftUI

@main
struct Watch_ListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
        do {
            try PersistenceController.shared.bootstrap()
        } catch {
            print("⚠️ Watch_ListApp: PersistenceController bootstrap failed: \(error)")
        }
    }

    @State private var toastState = ToastState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(toastState)
                .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
                .preferredColorScheme(.dark)
                .fontDesign(.rounded)
        }
    }
}
