import SwiftUI
import SwiftData
import UserNotifications
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

@main
struct RepRemindersApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        do {
            return try makeSharedContainer()
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
        RepRemindersShortcuts.updateAppShortcutParameters()
        #endif

        Task {
            _ = await NotificationManager.shared.requestAuthorization()
        }

        PhoneWatchSyncManager.shared.activate()

        return true
    }

    // The notification action now only opens the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
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

// MARK: - iPhone <-> Watch sync (no CloudKit)

final class PhoneWatchSyncManager: NSObject {
    static let shared = PhoneWatchSyncManager()
    private var isActivated = false
    private var pendingForcedSync = false

    private override init() {}

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    func forceSyncSnapshot() {
        #if canImport(WatchConnectivity)
        guard canSyncToWatch() else {
            pendingForcedSync = false
            return
        }
        pendingForcedSync = true
        if !isActivated {
            activate()
            return
        }
        pendingForcedSync = false
        sendCurrentState()
        #endif
    }

    func pushSnapshot(reminders: [Reminder]) {
        #if canImport(WatchConnectivity)
        guard canSyncToWatch() else {
            print("ℹ️ Watch app not installed yet, skipping sync snapshot.")
            return
        }

        let payload = reminders.map { reminder in
            [
                "id": reminder.id.uuidString,
                "title": reminder.title,
                "intervalMinutes": reminder.intervalMinutes,
                "startDate": reminder.startDate.timeIntervalSince1970,
                "maxRepetitions": reminder.maxRepetitions,
                "isCompleted": reminder.isCompleted,
                "createdAt": reminder.createdAt.timeIntervalSince1970
            ] as [String: Any]
        }

        do {
            try WCSession.default.updateApplicationContext(["reminders": payload])
        } catch {
            print("⚠️ Could not update watch context: \(error)")
        }
        #endif
    }

    func sendCurrentState() {
        Task { @MainActor in
            do {
                let container = try makeSharedContainer()
                let context = container.mainContext
                let reminders = try context.fetch(FetchDescriptor<Reminder>())
                pushSnapshot(reminders: reminders)
            } catch {
                print("⚠️ Could not fetch reminders for sync: \(error)")
            }
        }
    }

    #if canImport(WatchConnectivity)
    private func canSyncToWatch() -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.isPaired && session.isWatchAppInstalled
    }
    #endif

    func resetAllDataAndSync() {
        Task { @MainActor in
            do {
                let container = try makeSharedContainer()
                let context = container.mainContext
                let reminders = try context.fetch(FetchDescriptor<Reminder>())

                for reminder in reminders {
                    NotificationManager.shared.cancelReminder(reminder)
                    context.delete(reminder)
                }

                try context.save()
                await NotificationManager.shared.removeOrphanedNotifications(validReminderIDs: Set<UUID>())
                forceSyncSnapshot()
            } catch {
                print("⚠️ Could not reset all reminder data: \(error)")
            }
        }
    }
}

#if canImport(WatchConnectivity)
extension PhoneWatchSyncManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            print("⚠️ WCSession activation error: \(error)")
            return
        }
        isActivated = true
        if pendingForcedSync {
            pendingForcedSync = false
            sendCurrentState()
            return
        }
        sendCurrentState()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncomingWatchMessage(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncomingWatchMessage(userInfo)
    }

    private func handleIncomingWatchMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        if type == "requestSync" {
            sendCurrentState()
            return
        }

        if type == "create" {
            Task { @MainActor in
                do {
                    guard let reminderID = message["id"] as? String,
                          let uuid = UUID(uuidString: reminderID),
                          let title = message["title"] as? String,
                          let intervalMinutes = message["intervalMinutes"] as? Int,
                          let startTimestamp = message["startDate"] as? TimeInterval,
                          let maxRepetitions = message["maxRepetitions"] as? Int,
                          let isCompleted = message["isCompleted"] as? Bool,
                          let createdAtTimestamp = message["createdAt"] as? TimeInterval
                    else { return }

                    let container = try makeSharedContainer()
                    let context = container.mainContext
                    let allReminders = try context.fetch(FetchDescriptor<Reminder>())

                    if allReminders.contains(where: { $0.id == uuid }) {
                        sendCurrentState()
                        return
                    }

                    let reminder = Reminder(
                        title: title,
                        intervalMinutes: intervalMinutes,
                        startDate: Date(timeIntervalSince1970: startTimestamp),
                        maxRepetitions: maxRepetitions
                    )
                    reminder.id = uuid
                    reminder.isCompleted = isCompleted
                    reminder.createdAt = Date(timeIntervalSince1970: createdAtTimestamp)
                    context.insert(reminder)

                    if !isCompleted {
                        NotificationManager.shared.scheduleReminder(reminder)
                    }

                    try context.save()
                    sendCurrentState()
                } catch {
                    print("⚠️ Could not create reminder from watch: \(error)")
                }
            }
            return
        }

        guard let reminderID = message["id"] as? String,
              let uuid = UUID(uuidString: reminderID)
        else { return }

        Task { @MainActor in
            do {
                let container = try makeSharedContainer()
                let context = container.mainContext
                let allReminders = try context.fetch(FetchDescriptor<Reminder>())
                guard let reminder = allReminders.first(where: { $0.id == uuid }) else { return }

                switch type {
                case "complete":
                    reminder.isCompleted = true
                    NotificationManager.shared.cancelReminder(reminder)
                case "delete":
                    NotificationManager.shared.cancelReminder(reminder)
                    context.delete(reminder)
                default:
                    return
                }

                try context.save()
                sendCurrentState()
            } catch {
                print("⚠️ Could not apply watch action: \(error)")
            }
        }
    }
}
#endif
