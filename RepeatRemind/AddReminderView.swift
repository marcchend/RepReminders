import SwiftUI
import SwiftData

struct AddReminderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = "Valider ma présence"
    @State private var startDate = Date()
    @State private var intervalMinutes = 5
    @State private var maxRepetitions = 20

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
                            .foregroundStyle(.blue)
                        Text("Couverture totale : \(totalCoverageFormatted)")
                    }
                }
            }
            .navigationTitle("Nouveau rappel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { createReminder() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func createReminder() {
        let reminder = Reminder(
            title: title.trimmingCharacters(in: .whitespaces),
            intervalMinutes: intervalMinutes,
            startDate: startDate,
            maxRepetitions: maxRepetitions
        )
        modelContext.insert(reminder)
        NotificationManager.shared.scheduleReminder(reminder)
        dismiss()
    }
}
