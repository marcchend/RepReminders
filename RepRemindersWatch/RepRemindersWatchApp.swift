import SwiftUI
import SwiftData
import UserNotifications

@main
struct RepRemindersWatchApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = WatchNotificationDelegate.shared
    }

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

final class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationDelegate()

    private override init() {}

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == "VALIDATE_ACTION",
              let reminderIDString = response.notification.request.content.userInfo["reminderID"] as? String,
              let reminderID = UUID(uuidString: reminderIDString)
        else { return }

        WatchSyncManager.shared.completeReminder(reminderID: reminderID)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
