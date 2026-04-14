import SwiftUI
import SwiftData

struct AddReminderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var startDate = Date()
    @State private var intervalMinutes = 5
    @State private var maxRepetitions = 18

    private var totalCoverageMinutes: Int { intervalMinutes * maxRepetitions }
    private var totalCoverageFormatted: String {
        let h = totalCoverageMinutes / 60
        let m = totalCoverageMinutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)min" }
        if h > 0 { return "\(h)h" }
        return "\(m) min"
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

                Section {
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
                } header: {
                    Text("Répétition")
                } footer: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(.secondary)
                        Text("Couverture totale : \(totalCoverageFormatted)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Nouveau rappel")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        Task {
                            await createReminder()
                        }
                    }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @MainActor
    private func createReminder() async {
        let granted = await NotificationManager.shared.requestAuthorization()
        guard granted else {
            return
        }

        let reminder = Reminder(
            title: title.trimmingCharacters(in: .whitespaces),
            intervalMinutes: intervalMinutes,
            startDate: startDate,
            maxRepetitions: maxRepetitions
        )
        modelContext.insert(reminder)
        do {
            try modelContext.save()
        } catch {
            print("⚠️ Save new reminder error: \(error)")
        }
        NotificationManager.shared.scheduleReminder(reminder)
        Task {
            await NotificationManager.shared.verifyAndRepairNotifications(for: [reminder])
        }
        dismiss()
    }
}
