import SwiftUI
import SwiftData
import UserNotifications

@main
struct RepeatRemindWatchApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Reminder.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
