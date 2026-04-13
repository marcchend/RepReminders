import SwiftUI
import SwiftData

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
            .navigationTitle("Rappels")
        }
        .task {
            _ = await NotificationManager.shared.requestAuthorization()
            NotificationManager.shared.setupCategories()
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

            Text(reminder.startDate.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("/ \(reminder.intervalMinutes) min")
                .font(.caption2)
                .foregroundStyle(.blue)

            Button {
                withAnimation {
                    reminder.isCompleted = true
                    NotificationManager.shared.cancelReminder(reminder)
                }
            } label: {
                Label("Validé !", systemImage: "checkmark")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }
}
