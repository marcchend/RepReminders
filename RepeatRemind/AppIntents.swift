import AppIntents
import SwiftData
import Foundation

// MARK: – Create Repeating Reminder

struct CreateRepeatingReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Créer un rappel répétitif"
    static var description = IntentDescription(
        "Crée un rappel qui envoie une notification répétée toutes les X minutes jusqu'à validation.",
        categoryName: "RepeatRemind"
    )

    @Parameter(title: "Titre du rappel")
    var title: String

    @Parameter(title: "Date et heure de début")
    var startDate: Date

    @Parameter(title: "Intervalle (minutes)", default: 5)
    var intervalMinutes: Int

    @Parameter(title: "Nombre max de répétitions", default: 20)
    var maxRepetitions: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try ModelContainer(for: Reminder.self)
        let context = container.mainContext

        let reminder = Reminder(
            title: title,
            intervalMinutes: intervalMinutes,
            startDate: startDate,
            maxRepetitions: maxRepetitions
        )
        context.insert(reminder)
        try context.save()

        NotificationManager.shared.scheduleReminder(reminder)

        return .result(
            dialog: "Rappel '\(title)' créé ! Tu seras notifié toutes les \(intervalMinutes) minutes."
        )
    }
}

// MARK: – Complete Reminder

struct CompleteReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Valider la présence"
    static var description = IntentDescription(
        "Marque un rappel comme complété et arrête toutes les notifications en attente.",
        categoryName: "RepeatRemind"
    )

    @Parameter(title: "Titre du rappel")
    var reminderTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try ModelContainer(for: Reminder.self)
        let context = container.mainContext

        let allReminders = try context.fetch(FetchDescriptor<Reminder>())
        let matching = allReminders.filter {
            $0.title == reminderTitle && !$0.isCompleted
        }

        guard !matching.isEmpty else {
            return .result(dialog: "Aucun rappel actif trouvé avec le titre '\(reminderTitle)'.")
        }

        for reminder in matching {
            reminder.isCompleted = true
            NotificationManager.shared.cancelReminder(reminder)
        }
        try context.save()

        return .result(dialog: "Présence validée ! Les rappels ont été annulés.")
    }
}

// MARK: – Shortcuts Provider (Siri phrases)

struct RepeatRemindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateRepeatingReminderIntent(),
            phrases: [
                "Créer un rappel avec \(.applicationName)",
                "Nouveau rappel \(.applicationName)"
            ],
            shortTitle: "Créer un rappel",
            systemImageName: "bell.badge.fill"
        )
        AppShortcut(
            intent: CompleteReminderIntent(),
            phrases: [
                "Valider ma présence avec \(.applicationName)"
            ],
            shortTitle: "Valider la présence",
            systemImageName: "checkmark.circle.fill"
        )
    }
}
