import OSLog
import SwiftUI

@main
struct Watch_ListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Non-nil when the Core Data stack couldn't be opened. There is nothing the app can usefully
    /// do in that state — and nothing it should do automatically, since deleting or recreating a
    /// store would throw away local edits that haven't synced — so it says so and stops.
    private let bootstrapError: Error?

    // `static` because `init` calls it before `bootstrapError` is assigned, and an instance method
    // can't run on a partly-initialized value.
    private static func loadRocketSimConnect() {
        #if DEBUG
        guard (Bundle(path: "/Applications/RocketSim.app/Contents/Frameworks/RocketSimConnectLinker.nocache.framework")?.load() == true) else {
            AppLog.app.debug("RocketSim Connect linker framework not loaded")
            return
        }
        AppLog.app.debug("RocketSim Connect successfully linked")
        #endif
    }

    init() {
        Self.loadRocketSimConnect()
        do {
            try PersistenceController.shared.bootstrap()
            bootstrapError = nil
        } catch {
            AppLog.persistence.error("bootstrap failed: \(error)")
            bootstrapError = error
        }
    }

    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .dark

    @State private var toastState = ToastState()

    var body: some Scene {
        WindowGroup {
            Group {
                if bootstrapError == nil {
                    ContentView()
                        .environment(toastState)
                        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
                } else {
                    storeFailurePlaceholder
                }
            }
            .preferredColorScheme(appearance.colorScheme)
            // Default font design app-wide; .fontDesign(.rounded) is opted into
            // per-component for chips, badges, counts and small metadata captions.
        }
    }

    private var storeFailurePlaceholder: some View {
        EmptyStateView(
            icon: "externaldrive.badge.exclamationmark",
            title: "Couldn’t Open Your Watchlist",
            subtitle: "Restart the app. If this keeps happening, reinstall Up Next — your data is safe in iCloud."
        )
        .background(AppBackground())
    }
}
