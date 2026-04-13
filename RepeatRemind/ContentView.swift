import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Reminder.startDate, order: .forward) private var reminders: [Reminder]
    @State private var showingAddReminder = false

    private var activeReminders: [Reminder] { reminders.filter { !$0.isCompleted } }
    private var completedReminders: [Reminder] { reminders.filter { $0.isCompleted } }

    var body: some View {
        NavigationStack {
            Group {
                if reminders.isEmpty {
                    emptyState
                } else {
                    reminderList
                }
            }
            .navigationTitle("RepeatRemind")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddReminder = true
                    } label: {
                        Label("Ajouter", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddReminder) {
                AddReminderView()
            }
        }
        .task {
            _ = await NotificationManager.shared.requestAuthorization()
        }
    }

    // MARK: – Sub-views

    private var reminderList: some View {
        List {
            if !activeReminders.isEmpty {
                Section("Actifs (\(activeReminders.count))") {
                    ForEach(activeReminders) { reminder in
                        ReminderRow(reminder: reminder)
                    }
                    .onDelete { offsets in delete(from: activeReminders, at: offsets) }
                }
            }

            if !completedReminders.isEmpty {
                Section("Complétés") {
                    ForEach(completedReminders) { reminder in
                        CompletedReminderRow(reminder: reminder)
                    }
                    .onDelete { offsets in delete(from: completedReminders, at: offsets) }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Aucun rappel", systemImage: "bell.slash.fill")
        } description: {
            Text("Appuie sur **+** pour créer un rappel répétitif.")
        } actions: {
            Button("Créer un rappel") { showingAddReminder = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: – Actions

    private func delete(from list: [Reminder], at offsets: IndexSet) {
        for index in offsets {
            let reminder = list[index]
            NotificationManager.shared.cancelReminder(reminder)
            modelContext.delete(reminder)
        }
    }
}

// MARK: – Active Reminder Row

struct ReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    let reminder: Reminder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reminder.title)
                .font(.headline)

            HStack(spacing: 12) {
                Label(
                    reminder.startDate.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label("/ \(reminder.intervalMinutes) min", systemImage: "repeat")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation {
                    reminder.isCompleted = true
                    NotificationManager.shared.cancelReminder(reminder)
                }
            } label: {
                Label("Validé !", systemImage: "checkmark.circle.fill")
            }
            .tint(.green)
        }
    }
}

// MARK: – Completed Reminder Row

struct CompletedReminderRow: View {
    let reminder: Reminder

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.subheadline)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text(reminder.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
