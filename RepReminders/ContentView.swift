import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Reminder.startDate, order: .forward) private var reminders: [Reminder]
    @State private var showingAddReminder = false
    @State private var isSelectionMode = false
    @State private var selectedReminderIDs: Set<UUID> = []

    private var syncToken: String {
        reminders
            .map {
                "\($0.id.uuidString)|\($0.title)|\($0.intervalMinutes)|\($0.maxRepetitions)|\($0.isCompleted)|\($0.startDate.timeIntervalSince1970)|\($0.createdAt.timeIntervalSince1970)"
            }
            .joined(separator: "#")
    }

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
            .navigationTitle("Rappels")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelectionMode ? "Annuler" : "Sélectionner") {
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.9)) {
                            isSelectionMode.toggle()
                        }
                        if !isSelectionMode {
                            selectedReminderIDs.removeAll()
                        }
                    }
                }
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
        .tint(.primary)
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                HStack(spacing: 12) {
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
                .padding(.horizontal)
                .padding(.vertical, 10)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    )
                )
                .animation(.easeInOut(duration: 0.26), value: isSelectionMode)
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.9), value: isSelectionMode)
        .task {
            _ = await NotificationManager.shared.requestAuthorization()
            await NotificationManager.shared.removeOrphanedNotifications(
                validReminderIDs: Set(reminders.map(\.id))
            )
        }
        .onAppear {
            PhoneWatchSyncManager.shared.pushSnapshot(reminders: reminders)
        }
        .onChange(of: syncToken) { _, _ in
            PhoneWatchSyncManager.shared.pushSnapshot(reminders: reminders)
            Task {
                await NotificationManager.shared.removeOrphanedNotifications(
                    validReminderIDs: Set(reminders.map(\.id))
                )
            }
        }
    }

    // MARK: – Sub-views

    private var reminderList: some View {
        List {
            if !activeReminders.isEmpty {
                Section {
                    ForEach(activeReminders) { reminder in
                        ReminderRow(
                            reminder: reminder,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedReminderIDs.contains(reminder.id)
                        ) {
                            toggleSelection(for: reminder)
                        }
                    }
                    .onDelete { offsets in delete(from: activeReminders, at: offsets) }
                } header: {
                    Text("ACTIFS · \(activeReminders.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if !completedReminders.isEmpty {
                Section {
                    ForEach(completedReminders) { reminder in
                        CompletedReminderRow(
                            reminder: reminder,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedReminderIDs.contains(reminder.id)
                        ) {
                            toggleSelection(for: reminder)
                        }
                    }
                    .onDelete { offsets in delete(from: completedReminders, at: offsets) }
                } header: {
                    Text("TERMINÉS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Aucun rappel", systemImage: "bell.slash.fill")
        } description: {
            Text("Appuie sur **+** pour créer un rappel répétitif.")
        } actions: {
            Button("Créer un rappel") { showingAddReminder = true }
                .buttonStyle(.bordered)
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

    private func toggleSelection(for reminder: Reminder) {
        if selectedReminderIDs.contains(reminder.id) {
            selectedReminderIDs.remove(reminder.id)
        } else {
            selectedReminderIDs.insert(reminder.id)
        }
    }

    private func completeSelected() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for reminder in reminders where selectedReminderIDs.contains(reminder.id) {
                reminder.isCompleted = true
                NotificationManager.shared.cancelReminder(reminder)
            }
        }
        selectedReminderIDs.removeAll()
        isSelectionMode = false
    }

    private func deleteSelected() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for reminder in reminders where selectedReminderIDs.contains(reminder.id) {
                NotificationManager.shared.cancelReminder(reminder)
                modelContext.delete(reminder)
            }
        }
        selectedReminderIDs.removeAll()
        isSelectionMode = false
    }
}

// MARK: – Active Reminder Row

struct ReminderRow: View {
    let reminder: Reminder
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.title)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(
                        reminder.startDate.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "clock"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Label("/ \(reminder.intervalMinutes) min", systemImage: "repeat")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white, lineWidth: 2)
                .opacity(isSelectionMode && isSelected ? 1 : 0)
                .scaleEffect(isSelectionMode && isSelected ? 1 : 0.985)
        )
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.22), value: isSelectionMode)
        .animation(.easeInOut(duration: 0.22), value: isSelected)
        .onTapGesture {
            if isSelectionMode {
                onToggleSelection()
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isSelectionMode {
                Button {
                    withAnimation {
                        reminder.isCompleted = true
                        NotificationManager.shared.cancelReminder(reminder)
                    }
                } label: {
                    Label("Validé !", systemImage: "checkmark.circle.fill")
                }
                .tint(.white)
            }
        }
    }
}

// MARK: – Completed Reminder Row

struct CompletedReminderRow: View {
    let reminder: Reminder
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.subheadline)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text(reminder.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white, lineWidth: 2)
                .opacity(isSelectionMode && isSelected ? 1 : 0)
                .scaleEffect(isSelectionMode && isSelected ? 1 : 0.985)
        )
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .listRowBackground(Color.clear)
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
