import SwiftUI
import SwiftData
import UserNotifications

@main
struct RepeatRemindApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: – App Delegate (notification handling)

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationManager.shared.setupCategories()

        // ⚠️ Indispensable : enregistre les App Shortcuts auprès du système
        // Sans cela, les actions n'apparaissent pas dans l'app Raccourcis.
        #if !os(watchOS)
        RepeatRemindShortcuts.updateAppShortcutParameters()
        #endif

        return true
    }

    // Handle tapping the "Valider ma présence" action button in a notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == "VALIDATE_ACTION",
              let reminderIDString = response.notification.request.content
                  .userInfo["reminderID"] as? String
        else { return }

        Task { @MainActor in
            do {
                let container = try ModelContainer(for: Reminder.self)
                let context = container.mainContext
                let all = try context.fetch(FetchDescriptor<Reminder>())
                if let reminder = all.first(where: { $0.id.uuidString == reminderIDString }) {
                    reminder.isCompleted = true
                    NotificationManager.shared.cancelReminder(reminder)
                    try context.save()
                }
            } catch {
                print("⚠️ Error completing reminder from notification: \(error)")
            }
        }
    }

    // Display notifications while the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
