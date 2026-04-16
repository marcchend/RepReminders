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

    // Handle notification action from iPhone notifications.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == "VALIDATE_ACTION",
              let reminderIDString = response.notification.request.content.userInfo["reminderID"] as? String
        else {
            completionHandler()
            return
        }

        Task { @MainActor in
            await NotificationManager.shared.completeReminderIfExists(reminderIDString: reminderIDString)
            completionHandler()
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

// MARK: - iPhone <-> Watch sync (no CloudKit)

final class PhoneWatchSyncManager: NSObject, ObservableObject {
    static let shared = PhoneWatchSyncManager()
    private var isActivated = false
    private var pendingForcedSync = false
    private var scheduledSyncWorkItem: DispatchWorkItem?
    private let lastSyncRequestKey = "PhoneWatchSyncManager.lastSyncRequestAt"

    @MainActor @Published private(set) var isWatchPaired = false
    @MainActor @Published private(set) var isWatchAppInstalled = false

    private override init() {}

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        updateWatchAvailability(from: session)
        #endif
    }

    func forceSyncSnapshot() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        updateWatchAvailability(from: session)

        guard canSyncToWatch(session: session) else {
            pendingForcedSync = true
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

    /// Schedules a delayed sync once.
    /// Additional requests are ignored until the pending sync has executed.
    /// A persistent throttle avoids repeated forced sync bursts from Shortcut batch actions.
    func requestSyncSnapshot(
        delayNanoseconds: UInt64 = 4_000_000_000,
        minimumInterval: TimeInterval = 6,
        bypassThrottle: Bool = false
    ) {
        #if canImport(WatchConnectivity)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if !bypassThrottle {
                let now = Date().timeIntervalSince1970
                let last = UserDefaults.standard.double(forKey: self.lastSyncRequestKey)
                if now - last < minimumInterval {
                    return
                }
                UserDefaults.standard.set(now, forKey: self.lastSyncRequestKey)
            }

            guard self.scheduledSyncWorkItem == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scheduledSyncWorkItem = nil
                self.forceSyncSnapshot()
            }

            self.scheduledSyncWorkItem = workItem
            let clampedDelay = Int(clamping: delayNanoseconds)
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(clampedDelay), execute: workItem)
        }
        #endif
    }

    func pushSnapshot(reminders: [Reminder]) {
        #if canImport(WatchConnectivity)
        let session = WCSession.default
        updateWatchAvailability(from: session)

        guard canSyncToWatch(session: session) else {
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
            await sendCurrentStateNow()
        }
    }

    @MainActor
    func sendCurrentStateNow() async {
        do {
            let container = try makeSharedContainer()
            let context = container.mainContext
            let reminders = try context.fetch(FetchDescriptor<Reminder>())
            pushSnapshot(reminders: reminders)
        } catch {
            print("⚠️ Could not fetch reminders for sync: \(error)")
        }
    }

    @MainActor
    func syncWatchNow() async {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        updateWatchAvailability(from: session)

        guard canSyncToWatch(session: session) else {
            pendingForcedSync = true
            activate()
            return
        }

        if !isActivated {
            pendingForcedSync = true
            activate()
            return
        }

        pendingForcedSync = false
        await sendCurrentStateNow()
        #endif
    }

    #if canImport(WatchConnectivity)
    private func canSyncToWatch(session: WCSession = .default) -> Bool {
        return session.isPaired && session.isWatchAppInstalled
    }

    private func updateWatchAvailability(from session: WCSession = .default) {
        Task { @MainActor in
            isWatchPaired = session.isPaired
            isWatchAppInstalled = session.isWatchAppInstalled
        }
    }
    #endif

    func resetAllDataAndSync() {
        Task { @MainActor in
            do {
                let container = try makeSharedContainer()
                let context = container.mainContext
                let reminders = try context.fetch(FetchDescriptor<Reminder>())

                for reminder in reminders {
                    await NotificationManager.shared.cancelReminderAndWait(reminder)
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

    func sessionWatchStateDidChange(_ session: WCSession) {
        updateWatchAvailability(from: session)

        if pendingForcedSync, canSyncToWatch(session: session) {
            pendingForcedSync = false
            sendCurrentState()
        }
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

        if type == "snapshot" {
            applySnapshotFromWatch(message)
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
                    await NotificationManager.shared.cancelReminderAndWait(reminder)
                case "delete":
                    await NotificationManager.shared.cancelReminderAndWait(reminder)
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

    private func applySnapshotFromWatch(_ payload: [String: Any]) {
        guard let rawReminders = payload["reminders"] as? [[String: Any]] else { return }

        Task { @MainActor in
            do {
                let container = try makeSharedContainer()
                let context = container.mainContext
                let existing = try context.fetch(FetchDescriptor<Reminder>())
                var existingByID: [UUID: Reminder] = [:]

                for reminder in existing {
                    existingByID[reminder.id] = reminder
                }

                var incomingIDs: Set<UUID> = []

                for item in rawReminders {
                    guard let idString = item["id"] as? String,
                          let id = UUID(uuidString: idString),
                          let title = item["title"] as? String,
                          let intervalMinutes = item["intervalMinutes"] as? Int,
                          let startTimestamp = item["startDate"] as? TimeInterval,
                          let maxRepetitions = item["maxRepetitions"] as? Int,
                          let isCompleted = item["isCompleted"] as? Bool,
                          let createdAtTimestamp = item["createdAt"] as? TimeInterval
                    else { continue }

                    incomingIDs.insert(id)

                    if let current = existingByID[id] {
                        current.title = title
                        current.intervalMinutes = intervalMinutes
                        current.startDate = Date(timeIntervalSince1970: startTimestamp)
                        current.maxRepetitions = maxRepetitions
                        current.isCompleted = isCompleted
                        current.createdAt = Date(timeIntervalSince1970: createdAtTimestamp)
                    } else {
                        let reminder = Reminder(
                            title: title,
                            intervalMinutes: intervalMinutes,
                            startDate: Date(timeIntervalSince1970: startTimestamp),
                            maxRepetitions: maxRepetitions
                        )
                        reminder.id = id
                        reminder.isCompleted = isCompleted
                        reminder.createdAt = Date(timeIntervalSince1970: createdAtTimestamp)
                        context.insert(reminder)
                    }
                }

                for reminder in existing where !incomingIDs.contains(reminder.id) {
                    await NotificationManager.shared.cancelReminderAndWait(reminder)
                    context.delete(reminder)
                }

                try context.save()

                let syncedReminders = try context.fetch(FetchDescriptor<Reminder>())
                for reminder in syncedReminders {
                    await NotificationManager.shared.cancelReminderAndWait(reminder)
                    if !reminder.isCompleted {
                        NotificationManager.shared.scheduleReminder(reminder)
                    }
                }

                await NotificationManager.shared.removeOrphanedNotifications(
                    validReminderIDs: Set(syncedReminders.map(\.id))
                )
                await NotificationManager.shared.verifyAndRepairNotifications(for: syncedReminders)
            } catch {
                print("⚠️ Could not apply watch snapshot: \(error)")
            }
        }
    }
}
#endif
