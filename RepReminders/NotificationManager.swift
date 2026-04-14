import UserNotifications
import Foundation

final class NotificationManager: NSObject {
    static let shared = NotificationManager()
    private override init() {}

    // MARK: – Permission

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    // MARK: – Categories (action buttons on notifications)

    func setupCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_APP_ACTION",
            title: "Ouvrir",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "REMINDER_CATEGORY",
            actions: [openAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: – Schedule

    func scheduleReminder(_ reminder: Reminder) {
        let center = UNUserNotificationCenter.current()

        for i in 0..<reminder.maxRepetitions {
            let fireDate = reminder.startDate
                .addingTimeInterval(Double(i * reminder.intervalMinutes) * 60)

            // Don't schedule notifications in the past
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
            content.userInfo = ["reminderID": reminder.id.uuidString]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )
            let identifier = "\(reminder.id.uuidString)-\(i)"
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error {
                    print("⚠️ Notification scheduling error for index \(i): \(error)")
                }
            }
        }
    }

    // MARK: – Cancel

    func cancelReminder(_ reminder: Reminder) {
        let center = UNUserNotificationCenter.current()
        let reminderID = reminder.id.uuidString
        let identifierPrefix = "\(reminderID)-"

        // Remove any pending request that belongs to this reminder,
        // even if maxRepetitions was changed after initial scheduling.
        center.getPendingNotificationRequests { requests in
            let identifiers = requests.compactMap { request in
                if request.identifier.hasPrefix(identifierPrefix) {
                    return request.identifier
                }
                if let userInfoID = request.content.userInfo["reminderID"] as? String,
                   userInfoID == reminderID {
                    return request.identifier
                }
                return nil
            }

            if !identifiers.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }

        center.getDeliveredNotifications { notifications in
            let identifiers = notifications.compactMap { notification in
                let request = notification.request
                if request.identifier.hasPrefix(identifierPrefix) {
                    return request.identifier
                }
                if let userInfoID = request.content.userInfo["reminderID"] as? String,
                   userInfoID == reminderID {
                    return request.identifier
                }
                return nil
            }

            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }

    // Remove notifications that no longer map to existing reminders.
    func removeOrphanedNotifications(validReminderIDs: Set<UUID>) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()

        var orphanIdentifiers: [String] = []

        for request in pending {
            let content = request.content

            if content.categoryIdentifier != "REMINDER_CATEGORY" {
                continue
            }

            guard let reminderIDString = content.userInfo["reminderID"] as? String,
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
}
