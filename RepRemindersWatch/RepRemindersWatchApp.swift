import SwiftUI
import SwiftData
import UserNotifications

@main
struct RepRemindersWatchApp: App {
    var sharedModelContainer: ModelContainer = {
        do {
            return try makeSharedContainer()
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
