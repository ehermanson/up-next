import OSLog

/// Unified logging for the app — one `Logger` per subsystem area. Replaces `print`: entries show
/// up in Console.app / Xcode's log with the right category, are stripped of `.private` values in
/// Release, and cost nothing when nobody is listening.
enum AppLog {
    private static let subsystem = "com.erichermanson.upnext"

    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let sharing = Logger(subsystem: subsystem, category: "sharing")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let discover = Logger(subsystem: subsystem, category: "discover")
    static let importer = Logger(subsystem: subsystem, category: "importer")
    static let app = Logger(subsystem: subsystem, category: "app")
}
