import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Reminder.startDate, order: .forward) private var reminders: [Reminder]
    @State private var showingAddReminder = false
    @State private var editingReminder: Reminder?
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
    private var allReminderIDs: Set<UUID> { Set(reminders.map(\.id)) }
    private var selectedReminders: [Reminder] {
        reminders.filter { selectedReminderIDs.contains($0.id) }
    }
    private var areAllRemindersSelected: Bool {
        !allReminderIDs.isEmpty && allReminderIDs.isSubset(of: selectedReminderIDs)
    }
    private var shouldShowMarkAsNotCompleted: Bool {
        !selectedReminders.isEmpty && selectedReminders.allSatisfy(\.isCompleted)
    }

    var body: some View {
        NavigationStack {
            reminderList
            .toolbar {
                if isSelectionMode && !reminders.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            toggleSelectAll()
                        } label: {
                            Text(areAllRemindersSelected ? "Tout déselec." : "Tout sélec.")
                                .contentTransition(.opacity)
                                .animation(.easeInOut(duration: 0.18), value: areAllRemindersSelected)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.9)) {
                            isSelectionMode.toggle()
                            if !isSelectionMode {
                                selectedReminderIDs.removeAll()
                            }
                        }
                    } label: {
                        Text(isSelectionMode ? "Annuler" : "Sélectionner")
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.18), value: isSelectionMode)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .disabled(reminders.isEmpty)
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
            .sheet(
                isPresented: Binding(
                    get: { editingReminder != nil },
                    set: { if !$0 { editingReminder = nil } }
                )
            ) {
                if let reminder = editingReminder {
                    EditReminderSheet(reminder: reminder) { title, startDate, intervalMinutes, maxRepetitions in
                        applyEdit(
                            for: reminder,
                            title: title,
                            startDate: startDate,
                            intervalMinutes: intervalMinutes,
                            maxRepetitions: maxRepetitions
                        )
                    }
                }
            }
        }
        .tint(.primary)
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                HStack(spacing: 12) {
                    Button {
                        performPrimarySelectionAction()
                    } label: {
                        Text(shouldShowMarkAsNotCompleted ? "Non terminé" : "Terminer")
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.18), value: shouldShowMarkAsNotCompleted)
                            .fixedSize(horizontal: true, vertical: false)
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
        .task {
            _ = await NotificationManager.shared.requestAuthorization()
            await NotificationManager.shared.removeOrphanedNotifications(
                validReminderIDs: Set(reminders.map(\.id))
            )
            await NotificationManager.shared.verifyAndRepairNotifications(for: reminders)
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
                await NotificationManager.shared.verifyAndRepairNotifications(for: reminders)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                PhoneWatchSyncManager.shared.forceSyncSnapshot()
                Task {
                    await NotificationManager.shared.verifyAndRepairNotifications(for: reminders)
                }
            }
        }
    }

    // MARK: – Sub-views

    private var reminderList: some View {
        List {
            if reminders.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Label("Aucun rappel", systemImage: "bell.slash.fill")
                            .font(.headline)
                        Text("Appuie sur **+** pour créer un rappel répétitif.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            }

            if !activeReminders.isEmpty {
                Section {
                    ForEach(activeReminders) { reminder in
                        ReminderRow(
                            reminder: reminder,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedReminderIDs.contains(reminder.id)
                        ) {
                            toggleSelection(for: reminder)
                        } onEdit: {
                            editingReminder = reminder
                        } onDelete: {
                            deleteReminder(reminder)
                        }
                        .listRowSeparator(.hidden)
                    }
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
                        } onMarkAsNotCompleted: {
                            markReminderAsNotCompleted(reminder)
                        } onEdit: {
                            editingReminder = reminder
                        } onDelete: {
                            deleteReminder(reminder)
                        }
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("TERMINÉS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden, edges: .all)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: – Actions

    private func deleteReminder(_ reminder: Reminder) {
        withAnimation(.easeInOut(duration: 0.2)) {
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

    private func toggleSelectAll() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if areAllRemindersSelected {
                selectedReminderIDs.removeAll()
            } else {
                selectedReminderIDs = allReminderIDs
            }
        }
    }

    private func performPrimarySelectionAction() {
        if shouldShowMarkAsNotCompleted {
            markSelectedAsNotCompleted()
        } else {
            completeSelected()
        }
    }

    private func applyEdit(
        for reminder: Reminder,
        title: String,
        startDate: Date,
        intervalMinutes: Int,
        maxRepetitions: Int
    ) {
        reminder.title = title
        reminder.startDate = startDate
        reminder.intervalMinutes = intervalMinutes
        reminder.maxRepetitions = maxRepetitions

        NotificationManager.shared.cancelReminder(reminder)
        if !reminder.isCompleted {
            NotificationManager.shared.scheduleReminder(reminder)
        }

        do {
            try modelContext.save()
        } catch {
            print("⚠️ Save reminder edit error: \(error)")
        }
    }

    private func completeSelected() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for reminder in reminders where selectedReminderIDs.contains(reminder.id) {
                reminder.isCompleted = true
                NotificationManager.shared.cancelReminder(reminder)
            }
        }
        do {
            try modelContext.save()
        } catch {
            print("⚠️ Save completion error: \(error)")
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedReminderIDs.removeAll()
            isSelectionMode = false
        }
        Task {
            await NotificationManager.shared.verifyAndRepairNotifications(for: reminders)
        }
    }

    private func markSelectedAsNotCompleted() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for reminder in reminders where selectedReminderIDs.contains(reminder.id) {
                reminder.isCompleted = false
                NotificationManager.shared.cancelReminder(reminder)
                NotificationManager.shared.scheduleReminder(reminder)
            }
        }
        do {
            try modelContext.save()
        } catch {
            print("⚠️ Save restore error: \(error)")
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedReminderIDs.removeAll()
            isSelectionMode = false
        }
        Task {
            await NotificationManager.shared.verifyAndRepairNotifications(for: reminders)
        }
    }

    private func deleteSelected() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for reminder in reminders where selectedReminderIDs.contains(reminder.id) {
                NotificationManager.shared.cancelReminder(reminder)
                modelContext.delete(reminder)
            }
        }
        do {
            try modelContext.save()
        } catch {
            print("⚠️ Save delete error: \(error)")
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedReminderIDs.removeAll()
            isSelectionMode = false
        }
        Task {
            await NotificationManager.shared.verifyAndRepairNotifications(for: reminders)
        }
    }

    private func markReminderAsNotCompleted(_ reminder: Reminder) {
        withAnimation(.easeInOut(duration: 0.2)) {
            reminder.isCompleted = false
            NotificationManager.shared.cancelReminder(reminder)
            NotificationManager.shared.scheduleReminder(reminder)
        }
        do {
            try modelContext.save()
        } catch {
            print("⚠️ Save single restore error: \(error)")
        }
        Task {
            await NotificationManager.shared.verifyAndRepairNotifications(for: reminders)
        }
    }
}

// MARK: – Active Reminder Row

struct ReminderRow: View {
    let reminder: Reminder
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.title)
                    .font(.headline.weight(.regular))

                HStack(spacing: 12) {
                    Label(
                        reminder.startDate.localizedReminderDateTime,
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
                    withAnimation(.easeInOut(duration: 0.25)) {
                        reminder.isCompleted = true
                        NotificationManager.shared.cancelReminder(reminder)
                    }
                } label: {
                    Label("Validé !", systemImage: "checkmark.circle.fill")
                }
                .tint(.white)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectionMode {
                Button {
                    onDelete()
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
                .tint(.red)

                Button {
                    onEdit()
                } label: {
                    Label("Modifier", systemImage: "pencil")
                }
                .tint(.gray)
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
    let onMarkAsNotCompleted: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.title)
                    .font(.headline.weight(.regular))
                    .strikethrough()
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label(
                        reminder.startDate.localizedReminderDateTime,
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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isSelectionMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        onMarkAsNotCompleted()
                    }
                } label: {
                    Label("Non terminé", systemImage: "arrow.uturn.backward.circle.fill")
                }
                .tint(.white)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectionMode {
                Button {
                    onDelete()
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
                .tint(.red)

                Button {
                    onEdit()
                } label: {
                    Label("Modifier", systemImage: "pencil")
                }
                .tint(.gray)
            }
        }
    }
}

private extension Date {
    var localizedReminderDateTime: String {
        formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(.autoupdatingCurrent)
        )
    }
}

private struct EditReminderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let reminder: Reminder
    let onSave: (String, Date, Int, Int) -> Void

    @State private var title: String
    @State private var startDate: Date
    @State private var intervalMinutes: Int
    @State private var maxRepetitions: Int

    init(
        reminder: Reminder,
        onSave: @escaping (String, Date, Int, Int) -> Void
    ) {
        self.reminder = reminder
        self.onSave = onSave
        _title = State(initialValue: reminder.title)
        _startDate = State(initialValue: reminder.startDate)
        _intervalMinutes = State(initialValue: reminder.intervalMinutes)
        _maxRepetitions = State(initialValue: reminder.maxRepetitions)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rappel") {
                    TextField("Titre", text: $title)
                        .textInputAutocapitalization(.sentences)
                    DatePicker(
                        "Date et heure",
                        selection: $startDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section("Répétition") {
                    Stepper(
                        "Intervalle : **\(intervalMinutes) min**",
                        value: $intervalMinutes,
                        in: 1...60
                    )
                    Stepper(
                        "Max répétitions : **\(maxRepetitions)**",
                        value: $maxRepetitions,
                        in: 1...48
                    )
                }
            }
            .navigationTitle("Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmedTitle, startDate, intervalMinutes, maxRepetitions)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
