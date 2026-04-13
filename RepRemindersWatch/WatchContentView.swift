import SwiftUI
import SwiftData
import WatchConnectivity

struct WatchContentView: View {
    @Query(
        filter: #Predicate<Reminder> { !$0.isCompleted },
        sort: \Reminder.startDate
    )
    private var activeReminders: [Reminder]

    var body: some View {
        NavigationStack {
            List {
                if activeReminders.isEmpty {
                    Text("Aucun rappel actif")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(activeReminders) { reminder in
                        WatchReminderRow(reminder: reminder)
                    }
                }
            }
            .listStyle(.carousel)
        }
        .tint(.primary)
        .task {
            _ = await NotificationManager.shared.requestAuthorization()
            NotificationManager.shared.setupCategories()
            WatchSyncManager.shared.activate()
            WatchSyncManager.shared.requestSyncIfPossible()
        }
    }
}

// MARK: – Watch Reminder Row

struct WatchReminderRow: View {
    let reminder: Reminder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reminder.title)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text(reminder.startDate.localizedWatchReminderTime)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("/ \(reminder.intervalMinutes) min")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                withAnimation {
                    reminder.isCompleted = true
                    NotificationManager.shared.cancelReminder(reminder)
                    WatchSyncManager.shared.sendComplete(reminderID: reminder.id)
                }
            } label: {
                Label("Terminer", systemImage: "checkmark")
                    .font(.caption2)
            }
            .tint(.white)
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white, lineWidth: 2)
                .opacity(0)
                .scaleEffect(0.985)
        )
        .contentShape(Rectangle())
    }
}

private extension Date {
    var localizedWatchReminderTime: String {
        formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(.autoupdatingCurrent)
        )
    }
}

// MARK: - Watch <-> iPhone sync (no CloudKit)

final class WatchSyncManager: NSObject {
    static let shared = WatchSyncManager()

    private override init() {}

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func requestSyncIfPossible() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default

        if session.isReachable {
            session.sendMessage(["type": "requestSync"], replyHandler: nil) { error in
                print("⚠️ Could not request sync: \(error)")
            }
        } else {
            session.transferUserInfo(["type": "requestSync"])
        }
    }

    func sendComplete(reminderID: UUID) {
        guard WCSession.isSupported() else { return }
        let payload: [String: Any] = ["type": "complete", "id": reminderID.uuidString]
        let session = WCSession.default

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                print("⚠️ Could not send completion action: \(error)")
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func sendDelete(reminderID: UUID) {
        guard WCSession.isSupported() else { return }
        let payload: [String: Any] = ["type": "delete", "id": reminderID.uuidString]
        let session = WCSession.default

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                print("⚠️ Could not send delete action: \(error)")
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func sendCreate(reminder: Reminder) {
        guard WCSession.isSupported() else { return }
        let payload: [String: Any] = [
            "type": "create",
            "id": reminder.id.uuidString,
            "title": reminder.title,
            "intervalMinutes": reminder.intervalMinutes,
            "startDate": reminder.startDate.timeIntervalSince1970,
            "maxRepetitions": reminder.maxRepetitions,
            "isCompleted": reminder.isCompleted,
            "createdAt": reminder.createdAt.timeIntervalSince1970
        ]
        let session = WCSession.default

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                print("⚠️ Could not send create action: \(error)")
            }
        } else {
            session.transferUserInfo(payload)
        }
    }
}

extension WatchSyncManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            print("⚠️ WCSession activation error on watch: \(error)")
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applySnapshot(from: applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        applySnapshot(from: userInfo)
    }

    private func applySnapshot(from payload: [String: Any]) {
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
                    context.delete(reminder)
                }

                try context.save()

                let syncedReminders = try context.fetch(FetchDescriptor<Reminder>())
                for reminder in syncedReminders {
                    NotificationManager.shared.cancelReminder(reminder)
                    if !reminder.isCompleted {
                        NotificationManager.shared.scheduleReminder(reminder)
                    }
                }
                Task {
                    await NotificationManager.shared.removeOrphanedNotifications(
                        validReminderIDs: Set(syncedReminders.map(\.id))
                    )
                }
            } catch {
                print("⚠️ Could not apply iPhone snapshot on watch: \(error)")
            }
        }
    }
}

