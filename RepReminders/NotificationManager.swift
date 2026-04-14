import Foundation
import SwiftData
import UserNotifications

final class NotificationManager: NSObject {
    static let shared = NotificationManager()
    private override init() {}

    private let reminderNotificationKey = "reminderID"

    // MARK: – Permission

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: – Categories (action buttons on notifications)

    func setupCategories() {
        let completeAction = UNNotificationAction(
            identifier: "VALIDATE_ACTION",
            title: "✓ Terminer",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: "REMINDER_CATEGORY",
            actions: [completeAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: – Schedule

    func scheduleReminder(_ reminder: Reminder) {
        let center = UNUserNotificationCenter.current()

        for index in 0..<reminder.maxRepetitions {
            let fireDate = reminder.startDate
                .addingTimeInterval(Double(index * reminder.intervalMinutes) * 60)

            guard fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.subtitle = fireDate.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(.autoupdatingCurrent)
            )
            content.body = ""
            content.sound = .default
            content.categoryIdentifier = "REMINDER_CATEGORY"
            content.userInfo = [reminderNotificationKey: reminder.id.uuidString]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = "\(reminder.id.uuidString)-\(index)"

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )

            center.add(request) { error in
                if let error {
                    print("⚠️ Notification scheduling error for index \(index): \(error)")
                }
            }
        }

        Task { @MainActor [self] in
            await self.performPostScheduleIntegrityCheck(for: reminder)
        }
    }

    func plannedFireDates(for reminder: Reminder, referenceDate: Date = Date()) -> [Date] {
        guard reminder.intervalMinutes > 0, reminder.maxRepetitions > 0 else { return [] }

        return (0..<reminder.maxRepetitions).compactMap { index in
            let fireDate = reminder.startDate
                .addingTimeInterval(Double(index * reminder.intervalMinutes) * 60)
            return fireDate > referenceDate ? fireDate : nil
        }
    }

    func verifyAndRepairNotifications(for reminders: [Reminder]) async {
        let activeReminders = reminders.filter { !$0.isCompleted }

        for reminder in activeReminders {
            let expectedCount = plannedFireDates(for: reminder).count
            let pendingCount = await notificationCount(for: reminder)

            if expectedCount == 0 {
                await removeNotifications(for: reminder)
                continue
            }

            if pendingCount < expectedCount {
                print("⚠️ Repairing reminder \(reminder.id.uuidString): expected \(expectedCount) pending notifications, found \(pendingCount)")
                await removeNotifications(for: reminder)
                scheduleReminder(reminder)

                let repairedCount = await notificationCount(for: reminder)
                if repairedCount < expectedCount {
                    print("⚠️ Reminder \(reminder.id.uuidString) still has only \(repairedCount)/\(expectedCount) notifications after repair")
                }
            }
        }

        await removeOrphanedNotifications(validReminderIDs: Set(reminders.map(\.id)))
    }

    func pendingCount(for reminder: Reminder) async -> Int {
        await notificationCount(for: reminder, includeDelivered: false)
    }

    func removeNotifications(for reminder: Reminder) async {
        let center = UNUserNotificationCenter.current()
        let reminderID = reminder.id.uuidString
        let identifierPrefix = "\(reminderID)-"

        let pendingRequests = await center.pendingNotificationRequests()
        let pendingIdentifiers = pendingRequests.compactMap { request in
            if request.identifier.hasPrefix(identifierPrefix) {
                return request.identifier
            }
            if let userInfoID = request.content.userInfo[reminderNotificationKey] as? String,
               userInfoID == reminderID {
                return request.identifier
            }
            return nil
        }

        if !pendingIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let deliveredNotifications = await deliveredNotifications()
        let deliveredIdentifiers = deliveredNotifications.compactMap { notification in
            let request = notification.request
            if request.identifier.hasPrefix(identifierPrefix) {
                return request.identifier
            }
            if let userInfoID = request.content.userInfo[reminderNotificationKey] as? String,
               userInfoID == reminderID {
                return request.identifier
            }
            return nil
        }

        if !deliveredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    func cancelReminder(_ reminder: Reminder) {
        Task {
            await removeNotifications(for: reminder)
        }
    }

    func cancelReminderAndWait(_ reminder: Reminder) async {
        await removeNotifications(for: reminder)
    }

    @MainActor
    func completeReminderIfExists(reminderIDString: String) async {
        do {
            let container = try makeSharedContainer()
            let context = container.mainContext
            let all = try context.fetch(FetchDescriptor<Reminder>())

            guard let reminder = all.first(where: { $0.id.uuidString == reminderIDString }) else { return }

            reminder.isCompleted = true
            await cancelReminderAndWait(reminder)
            try context.save()
            #if !os(watchOS)
            PhoneWatchSyncManager.shared.sendCurrentState()
            #endif
        } catch {
            print("⚠️ Could not complete reminder from notification: \(error)")
        }
    }

    // Remove notifications that no longer map to existing reminders.
    func removeOrphanedNotifications(validReminderIDs: Set<UUID>) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()

        var orphanIdentifiers: [String] = []

        for request in pending {
            let content = request.content

            guard content.categoryIdentifier == "REMINDER_CATEGORY" else {
                continue
            }

            guard let reminderIDString = content.userInfo[reminderNotificationKey] as? String,
                  let reminderID = UUID(uuidString: reminderIDString)
            else {
                orphanIdentifiers.append(request.identifier)
                continue
            }

            if !validReminderIDs.contains(reminderID) {
                orphanIdentifiers.append(request.identifier)
            }
        }

        if !orphanIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: orphanIdentifiers)
            center.removeDeliveredNotifications(withIdentifiers: orphanIdentifiers)
        }
    }

    private func notificationCount(for reminder: Reminder, includeDelivered: Bool = true) async -> Int {
        let reminderID = reminder.id.uuidString
        let identifierPrefix = "\(reminderID)-"
        let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()

        var matches = pendingRequests.filter { request in
            guard request.content.categoryIdentifier == "REMINDER_CATEGORY" else { return false }
            if request.identifier.hasPrefix(identifierPrefix) {
                return true
            }
            if let userInfoID = request.content.userInfo[reminderNotificationKey] as? String {
                return userInfoID == reminderID
            }
            return false
        }.count

        guard includeDelivered else { return matches }

        let delivered = await deliveredNotifications()
        matches += delivered.filter { notification in
            let request = notification.request
            guard request.content.categoryIdentifier == "REMINDER_CATEGORY" else { return false }
            if request.identifier.hasPrefix(identifierPrefix) {
                return true
            }
            if let userInfoID = request.content.userInfo[reminderNotificationKey] as? String {
                return userInfoID == reminderID
            }
            return false
        }.count

        return matches
    }

    private func performPostScheduleIntegrityCheck(for reminder: Reminder) async {
        let expectedCount = plannedFireDates(for: reminder).count
        guard expectedCount > 0 else { return }

        let retryDelaysInNanoseconds: [UInt64] = [250_000_000, 750_000_000, 1_500_000_000]

        for delay in retryDelaysInNanoseconds {
            let currentCount = await notificationCount(for: reminder)
            if currentCount >= expectedCount {
                return
            }

            try? await Task.sleep(nanoseconds: delay)
        }

        await verifyAndRepairNotifications(for: [reminder])
    }

    private func deliveredNotifications() async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }
    }
}
