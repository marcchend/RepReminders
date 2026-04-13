import AppIntents
import SwiftData
import Foundation

// MARK: - SwiftData helper (compatible MainActor isolation)
//
// ModelContainer.mainContext est @MainActor — on crée le container dans une
// fonction nonisolated, puis on accède à mainContext uniquement depuis @MainActor.

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: Reminder.self)
}

// MARK: – Créer un rappel

struct CreateReminderIntent: AppIntent {

    static var title: LocalizedStringResource = "Créer un rappel"
    static var description = IntentDescription(
        "Crée un rappel qui envoie une notification répétée toutes les X minutes jusqu'à suppression.",
        categoryName: "RepeatRemind"
    )

    @Parameter(title: "Titre du rappel")
    var title: String

    @Parameter(title: "Intervalle (minutes)", default: 5)
    var intervalMinutes: Int

    // Date : pas de valeur par défaut via IntentParameter.defaultValue (API inexistante).
    // On utilise Optional<Date> — si nil, on prend Date.now dans perform().
    @Parameter(title: "Date et heure de début")
    var startDate: Date?

    @Parameter(title: "Nombre max de répétitions", default: 20)
    var maxRepetitions: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try makeContainer()
        let context = container.mainContext
        let date = startDate ?? Date.now

        let reminder = Reminder(
            title: title,
            intervalMinutes: intervalMinutes,
            startDate: date,
            maxRepetitions: maxRepetitions
        )
        context.insert(reminder)
        try context.save()

        NotificationManager.shared.scheduleReminder(reminder)

        return .result(
            dialog: "Rappel « \(title) » créé ! Tu seras notifié toutes les \(intervalMinutes) minutes."
        )
    }
}

// MARK: – Supprimer un rappel

struct DeleteReminderIntent: AppIntent {

    static var title: LocalizedStringResource = "Supprimer un rappel"
    static var description = IntentDescription(
        "Supprime un rappel existant et annule toutes ses notifications en attente.",
        categoryName: "RepeatRemind"
    )

    @Parameter(title: "Titre du rappel")
    var reminderTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try makeContainer()
        let context = container.mainContext

        let allReminders = try context.fetch(FetchDescriptor<Reminder>())
        let matching = allReminders.filter { $0.title == reminderTitle }

        guard !matching.isEmpty else {
            return .result(dialog: "Aucun rappel trouvé avec le titre « \(reminderTitle) ».")
        }

        for reminder in matching {
            NotificationManager.shared.cancelReminder(reminder)
            context.delete(reminder)
        }
        try context.save()

        return .result(dialog: "Rappel « \(reminderTitle) » supprimé et notifications annulées.")
    }
}

// MARK: – Valider (compléter) un rappel

struct CompleteReminderIntent: AppIntent {

    static var title: LocalizedStringResource = "Valider un rappel"
    static var description = IntentDescription(
        "Marque un rappel comme complété et arrête toutes ses notifications en attente.",
        categoryName: "RepeatRemind"
    )

    @Parameter(title: "Titre du rappel")
    var reminderTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try makeContainer()
        let context = container.mainContext

        let allReminders = try context.fetch(FetchDescriptor<Reminder>())
        let matching = allReminders.filter { $0.title == reminderTitle && !$0.isCompleted }

        guard !matching.isEmpty else {
            return .result(dialog: "Aucun rappel actif trouvé avec le titre « \(reminderTitle) ».")
        }

        for reminder in matching {
            reminder.isCompleted = true
            NotificationManager.shared.cancelReminder(reminder)
        }
        try context.save()

        return .result(dialog: "Rappel « \(reminderTitle) » validé. Les notifications ont été annulées.")
    }
}

// MARK: – App Shortcuts
//
// AppShortcutsProvider n'est pas supporté sur watchOS — on conditionne la compilation.
// Les phrases DOIVENT contenir \(.applicationName), sinon iOS les rejette silencieusement.

#if !os(watchOS)
struct RepeatRemindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateReminderIntent(),
            phrases: [
                "Créer un rappel avec \(.applicationName)",
                "Nouveau rappel dans \(.applicationName)"
            ],
            shortTitle: "Créer un rappel",
            systemImageName: "bell.badge.fill"
        )
        AppShortcut(
            intent: DeleteReminderIntent(),
            phrases: [
                "Supprimer un rappel dans \(.applicationName)",
                "Effacer un rappel avec \(.applicationName)"
            ],
            shortTitle: "Supprimer un rappel",
            systemImageName: "trash.fill"
        )
        AppShortcut(
            intent: CompleteReminderIntent(),
            phrases: [
                "Valider un rappel avec \(.applicationName)"
            ],
            shortTitle: "Valider un rappel",
            systemImageName: "checkmark.circle.fill"
        )
    }
}
#endif
