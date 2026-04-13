import SwiftUI
import SwiftData
import WatchConnectivity

struct WatchContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Reminder> { !$0.isCompleted },
        sort: \Reminder.startDate
    )
    private var activeReminders: [Reminder]
    @State private var isSelectionMode = false
    @State private var selectedReminderIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                if activeReminders.isEmpty {
                    Text("Aucun rappel actif")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(activeReminders) { reminder in
                        WatchReminderRow(
                            reminder: reminder,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedReminderIDs.contains(reminder.id)
                        ) {
                            toggleSelection(for: reminder)
                        }
                    }
                }
            }
            .listStyle(.carousel)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.9)) {
                            isSelectionMode.toggle()
                            if !isSelectionMode {
                                selectedReminderIDs.removeAll()
                            }
                        }
                    } label: {
                        Text(isSelectionMode ? "Annuler" : "Sélect.")
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.18), value: isSelectionMode)
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }
            }
        }
        .tint(.primary)
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                HStack(spacing: 8) {
                    Button("Terminer") {
                        completeSelected()
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelectionMode ? .white : .secondary)
                    .disabled(selectedReminderIDs.isEmpty)

                    Button("Supprimer") {
                        deleteSelected()
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelectionMode ? .white : .secondary)
                    .disabled(selectedReminderIDs.isEmpty)
                }
                .padding(.vertical, 4)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    )
                )
                .animation(.easeInOut(duration: 0.26), value: isSelectionMode)
            }
        }
        .task {
            _ = await NotificationManager.shared.requestAuthorization()
            NotificationManager.shared.setupCategories()
            WatchSyncManager.shared.activate()
            WatchSyncManager.shared.requestSyncIfPossible()
        }
    }

    private func completeSelected() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for reminder in activeReminders where selectedReminderIDs.contains(reminder.id) {
                reminder.isCompleted = true
                NotificationManager.shared.cancelReminder(reminder)
                WatchSyncManager.shared.sendComplete(reminderID: reminder.id)
            }
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedReminderIDs.removeAll()
            isSelectionMode = false
        }
    }

    private func deleteSelected() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for reminder in activeReminders where selectedReminderIDs.contains(reminder.id) {
                NotificationManager.shared.cancelReminder(reminder)
                modelContext.delete(reminder)
                WatchSyncManager.shared.sendDelete(reminderID: reminder.id)
            }
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedReminderIDs.removeAll()
            isSelectionMode = false
        }
    }

    private func toggleSelection(for reminder: Reminder) {
        if selectedReminderIDs.contains(reminder.id) {
            selectedReminderIDs.remove(reminder.id)
        } else {
            selectedReminderIDs.insert(reminder.id)
        }
    }
}

// MARK: – Watch Reminder Row

struct WatchReminderRow: View {
    let reminder: Reminder
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void

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

            if !isSelectionMode {
                Button {
                    withAnimation {
                        reminder.isCompleted = true
                        NotificationManager.shared.cancelReminder(reminder)
                        WatchSyncManager.shared.sendComplete(reminderID: reminder.id)
                    }
                } label: {
                    Label("Validé !", systemImage: "checkmark")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .tint(.white)
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
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
                .opacity(isSelectionMode && isSelected ? 1 : 0)
                .scaleEffect(isSelectionMode && isSelected ? 1 : 0.985)
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.22), value: isSelectionMode)
        .animation(.easeInOut(duration: 0.22), value: isSelected)
        .onTapGesture {
            if isSelectionMode {
                onToggleSelection()
            }
        }
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
            } catch {
                print("⚠️ Could not apply iPhone snapshot on watch: \(error)")
            }
        }
    }
}
