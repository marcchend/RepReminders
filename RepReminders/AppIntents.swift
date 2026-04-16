import AppIntents
import SwiftData
import Foundation

// MARK: - SwiftData helper

private func makeContainer() throws -> ModelContainer {
    try makeSharedContainer()
}

// MARK: – Créer un rappel

struct CreateReminderIntent: AppIntent {

    static var title: LocalizedStringResource = "Créer un rappel"
    static var description = IntentDescription(
        "Crée un rappel qui envoie une notification répétée toutes les X minutes jusqu'à suppression.",
        categoryName: "RepReminders"
    )

    @Parameter(title: "Titre du rappel")
    var title: String

    @Parameter(title: "Intervalle (minutes)", default: 5)
    var intervalMinutes: Int

    @Parameter(title: "Date et heure de début")
    var startDate: Date?

    @Parameter(title: "Nombre max de répétitions", default: 18)
    var maxRepetitions: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let granted = await NotificationManager.shared.requestAuthorization()
        guard granted else {
            return .result(
                dialog: IntentDialog("Les notifications ne sont pas autorisées. Active-les dans Réglages pour recevoir les rappels.")
            )
        }

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
        PhoneWatchSyncManager.shared.requestSyncSnapshot(
            delayNanoseconds: 8_000_000_000,
            minimumInterval: 12
        )

        return .result(
            dialog: IntentDialog("Rappel « \(title) » créé ! Tu seras notifié toutes les \(intervalMinutes) minutes.")
        )
    }
}

// MARK: – Supprimer un rappel

struct DeleteReminderIntent: AppIntent {

    static var title: LocalizedStringResource = "Supprimer un rappel"
    static var description = IntentDescription(
        "Supprime un rappel existant et annule toutes ses notifications en attente.",
        categoryName: "RepReminders"
    )

    @Parameter(title: "Titre du rappel")
    var reminderTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let granted = await NotificationManager.shared.requestAuthorization()
        guard granted else {
            return .result(
                dialog: IntentDialog("Les notifications ne sont pas autorisées. Active-les dans Réglages pour recevoir les rappels.")
            )
        }

        let container = try makeContainer()
        let context = container.mainContext

        let allReminders = try context.fetch(FetchDescriptor<Reminder>())
        let matching = allReminders.filter { $0.title == reminderTitle }

        guard !matching.isEmpty else {
            return .result(dialog: IntentDialog("Aucun rappel trouvé avec le titre « \(reminderTitle) »."))
        }

        for reminder in matching {
            await NotificationManager.shared.cancelReminderAndWait(reminder)
            context.delete(reminder)
        }
        try context.save()
        Task {
            await NotificationManager.shared.removeOrphanedNotifications(
                validReminderIDs: Set((try? context.fetch(FetchDescriptor<Reminder>()))?.map(\.id) ?? [])
            )
        }
        PhoneWatchSyncManager.shared.requestSyncSnapshot(
            delayNanoseconds: 8_000_000_000,
            minimumInterval: 12
        )

        return .result(dialog: IntentDialog("Rappel « \(reminderTitle) » supprimé et notifications annulées."))
    }
}

// MARK: – Valider un rappel

struct CompleteReminderIntent: AppIntent {

    static var title: LocalizedStringResource = "Valider un rappel"
    static var description = IntentDescription(
        "Marque un rappel comme complété et arrête toutes ses notifications en attente.",
        categoryName: "RepReminders"
    )

    @Parameter(title: "Titre du rappel")
    var reminderTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let granted = await NotificationManager.shared.requestAuthorization()
        guard granted else {
            return .result(
                dialog: IntentDialog("Les notifications ne sont pas autorisées. Active-les dans Réglages pour recevoir les rappels.")
            )
        }

        let container = try makeContainer()
        let context = container.mainContext

        let allReminders = try context.fetch(FetchDescriptor<Reminder>())
        let matching = allReminders.filter { $0.title == reminderTitle && !$0.isCompleted }

        guard !matching.isEmpty else {
            return .result(dialog: IntentDialog("Aucun rappel actif trouvé avec le titre « \(reminderTitle) »."))
        }

        for reminder in matching {
            reminder.isCompleted = true
            await NotificationManager.shared.cancelReminderAndWait(reminder)
        }
        try context.save()
        Task {
            await NotificationManager.shared.removeOrphanedNotifications(
                validReminderIDs: Set((try? context.fetch(FetchDescriptor<Reminder>()))?.map(\.id) ?? [])
            )
        }
        PhoneWatchSyncManager.shared.requestSyncSnapshot(
            delayNanoseconds: 8_000_000_000,
            minimumInterval: 12
        )

        return .result(dialog: IntentDialog("Rappel « \(reminderTitle) » validé. Les notifications ont été annulées."))
    }
}

// MARK: – Synchroniser la Watch

struct SyncWatchIntent: AppIntent {

    static var title: LocalizedStringResource = "Synchroniser la Watch"
    static var description = IntentDescription(
        "Force l'envoi immédiat des rappels iPhone vers l'Apple Watch.",
        categoryName: "RepReminders"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PhoneWatchSyncManager.shared.requestSyncSnapshot(
            delayNanoseconds: 300_000_000,
            bypassThrottle: true
        )
        return .result(dialog: IntentDialog("Synchronisation Watch planifiée."))
    }
}

// MARK: – Réinitialiser toutes les données

struct ResetAllDataIntent: AppIntent {

    static var title: LocalizedStringResource = "Réinitialiser toutes les données"
    static var description = IntentDescription(
        "Supprime tous les rappels locaux, nettoie les notifications et force une synchronisation vers l'Apple Watch.",
        categoryName: "RepReminders"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PhoneWatchSyncManager.shared.resetAllDataAndSync()
        return .result(dialog: IntentDialog("Réinitialisation lancée sur iPhone et synchronisation Watch demandée."))
    }
}

// MARK: – Entité Rappel
//
// Les @Property exposent les champs dans Raccourcis :
// l'utilisateur peut y accéder avec "Rappel > Titre", "Rappel > Date de début", etc.

struct ReminderEntity: AppEntity {

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Rappel")
    static var defaultQuery = ReminderEntityQuery()

    var id: UUID

    var displayRepresentation: DisplayRepresentation {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        fmt.locale = Locale(identifier: "fr_FR")
        let dateStr = fmt.string(from: startDate)
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(dateStr) · toutes les \(intervalMinutes) min\(isCompleted ? " · Validé" : "")"
        )
    }

    // Propriétés accessibles depuis une automatisation Raccourcis
    @Property(title: "Titre")
    var title: String

    @Property(title: "Intervalle (minutes)")
    var intervalMinutes: Int

    @Property(title: "Date de début")
    var startDate: Date

    @Property(title: "Date de création")
    var createdAt: Date

    @Property(title: "Validé")
    var isCompleted: Bool

    @Property(title: "Nombre max de répétitions")
    var maxRepetitions: Int

    init(from reminder: Reminder) {
        self.id = reminder.id
        self.title = reminder.title
        self.intervalMinutes = reminder.intervalMinutes
        self.startDate = reminder.startDate
        self.createdAt = reminder.createdAt
        self.isCompleted = reminder.isCompleted
        self.maxRepetitions = reminder.maxRepetitions
    }
}

// MARK: – Query avec filtres (EnumerableEntityQuery permet la recherche dans Raccourcis)

struct ReminderEntityQuery: EntityQuery, EnumerableEntityQuery {

    @MainActor
    func allEntities() async throws -> [ReminderEntity] {
        let container = try makeContainer()
        let context = container.mainContext
        return try context.fetch(FetchDescriptor<Reminder>()).map { ReminderEntity(from: $0) }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ReminderEntity] {
        let container = try makeContainer()
        let context = container.mainContext
        let all = try context.fetch(FetchDescriptor<Reminder>())
        return all
            .filter { identifiers.contains($0.id) }
            .map { ReminderEntity(from: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ReminderEntity] {
        let container = try makeContainer()
        let context = container.mainContext
        let descriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { !$0.isCompleted },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try context.fetch(descriptor).map { ReminderEntity(from: $0) }
    }
}

// MARK: – Enums pour les filtres

/// Champ sur lequel filtrer par date
enum ReminderDateField: String, AppEnum {
    case startDate
    case createdAt

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Champ de date")
    static var caseDisplayRepresentations: [ReminderDateField: DisplayRepresentation] = [
        .startDate: DisplayRepresentation(title: "Date de début / échéance"),
        .createdAt: DisplayRepresentation(title: "Date de création")
    ]
}

/// Opérateur de comparaison de date
enum ReminderDateOperator: String, AppEnum {
    case onDay
    case before
    case after
    case today
    case thisWeek

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Opérateur de date")
    static var caseDisplayRepresentations: [ReminderDateOperator: DisplayRepresentation] = [
        .onDay:     DisplayRepresentation(title: "Ce jour précis"),
        .before:    DisplayRepresentation(title: "Avant cette date"),
        .after:     DisplayRepresentation(title: "Après cette date"),
        .today:     DisplayRepresentation(title: "Aujourd'hui"),
        .thisWeek:  DisplayRepresentation(title: "Cette semaine")
    ]
}

/// Critère de tri
enum ReminderSortField: String, AppEnum {
    case startDate
    case createdAt
    case title

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trier par")
    static var caseDisplayRepresentations: [ReminderSortField: DisplayRepresentation] = [
        .startDate: DisplayRepresentation(title: "Date de début"),
        .createdAt: DisplayRepresentation(title: "Date de création"),
        .title:     DisplayRepresentation(title: "Titre (A→Z)")
    ]
}

/// Statut du rappel
enum ReminderStatusFilter: String, AppEnum {
    case all
    case active
    case completed

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Statut")
    static var caseDisplayRepresentations: [ReminderStatusFilter: DisplayRepresentation] = [
        .all:       DisplayRepresentation(title: "Tous"),
        .active:    DisplayRepresentation(title: "Actifs uniquement"),
        .completed: DisplayRepresentation(title: "Validés uniquement")
    ]
}

// MARK: – Obtenir rappels

struct GetRemindersIntent: AppIntent {

    static var title: LocalizedStringResource = "Obtenir rappels"
    static var description = IntentDescription(
        "Retourne des rappels filtrés par statut, date de début, date de création, etc. Compatible automatisations.",
        categoryName: "RepReminders"
    )

    // ── Filtre statut ────────────────────────────────────────────────────
    @Parameter(title: "Statut", default: ReminderStatusFilter.active)
    var statusFilter: ReminderStatusFilter

    // ── Filtre date (optionnel) ───────────────────────────────────────────
    @Parameter(title: "Filtrer par date", default: false)
    var useDateFilter: Bool

    @Parameter(title: "Champ de date", default: ReminderDateField.startDate)
    var dateField: ReminderDateField

    @Parameter(title: "Opérateur", default: ReminderDateOperator.onDay)
    var dateOperator: ReminderDateOperator

    /// Utilisée pour .onDay / .before / .after (ignorée pour .today / .thisWeek)
    @Parameter(title: "Date de référence")
    var referenceDate: Date?

    // ── Tri ───────────────────────────────────────────────────────────────
    @Parameter(title: "Trier par", default: ReminderSortField.startDate)
    var sortField: ReminderSortField

    @Parameter(title: "Ordre décroissant", default: false)
    var sortDescending: Bool

    // ── Limite ────────────────────────────────────────────────────────────
    @Parameter(title: "Nombre max de résultats (0 = tous)", default: 0)
    var limit: Int

    // ── perform ───────────────────────────────────────────────────────────

    @MainActor
    func perform() async throws -> some ReturnsValue<[ReminderEntity]> & ProvidesDialog {
        let container = try makeContainer()
        let context = container.mainContext
        var results = try context.fetch(FetchDescriptor<Reminder>())

        // 1. Filtre statut
        switch statusFilter {
        case .all:       break
        case .active:    results = results.filter { !$0.isCompleted }
        case .completed: results = results.filter {  $0.isCompleted }
        }

        // 2. Filtre date
        if useDateFilter {
            let cal = Calendar.current
            let now = Date.now

            results = results.filter { reminder in
                let fieldDate: Date
                switch dateField {
                case .startDate: fieldDate = reminder.startDate
                case .createdAt: fieldDate = reminder.createdAt
                }

                switch dateOperator {
                case .onDay:
                    guard let ref = referenceDate else { return true }
                    return cal.isDate(fieldDate, inSameDayAs: ref)
                case .before:
                    guard let ref = referenceDate else { return true }
                    return fieldDate < ref
                case .after:
                    guard let ref = referenceDate else { return true }
                    return fieldDate > ref
                case .today:
                    return cal.isDateInToday(fieldDate)
                case .thisWeek:
                    return cal.isDate(fieldDate, equalTo: now, toGranularity: .weekOfYear)
                }
            }
        }

        // 3. Tri
        results.sort {
            switch sortField {
            case .startDate: return sortDescending ? $0.startDate > $1.startDate : $0.startDate < $1.startDate
            case .createdAt: return sortDescending ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
            case .title:     return sortDescending ? $0.title > $1.title         : $0.title < $1.title
            }
        }

        // 4. Limite
        if limit > 0 {
            results = Array(results.prefix(limit))
        }

        let entities = results.map { ReminderEntity(from: $0) }
        let n = entities.count
        let s = n > 1 ? "s" : ""
        let summary = n == 0 ? "Aucun rappel trouvé." : "\(n) rappel\(s) trouvé\(s)."

        return .result(value: entities, dialog: IntentDialog("\(summary)"))
    }
}

// MARK: – App Shortcuts
//
// AppShortcutsProvider n'est pas supporté sur watchOS.
// Les phrases DOIVENT contenir \(.applicationName).

#if !os(watchOS)
struct RepRemindersShortcuts: AppShortcutsProvider {
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
        AppShortcut(
            intent: SyncWatchIntent(),
            phrases: [
                "Synchroniser la Watch avec \(.applicationName)",
                "Forcer la synchronisation avec \(.applicationName)"
            ],
            shortTitle: "Synchroniser la Watch",
            systemImageName: "applewatch"
        )
        AppShortcut(
            intent: ResetAllDataIntent(),
            phrases: [
                "Réinitialiser les données de \(.applicationName)",
                "Vider tous les rappels dans \(.applicationName)"
            ],
            shortTitle: "Reset des données",
            systemImageName: "trash.circle.fill"
        )
        AppShortcut(
            intent: GetRemindersIntent(),
            phrases: [
                "Obtenir mes rappels avec \(.applicationName)",
                "Voir mes rappels dans \(.applicationName)"
            ],
            shortTitle: "Obtenir rappels",
            systemImageName: "list.bullet.rectangle.fill"
        )
    }
}
#endif
