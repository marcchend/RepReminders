import SwiftData
import Foundation

@Model
final class Reminder {
    var id: UUID
    var title: String
    var intervalMinutes: Int
    var startDate: Date
    var maxRepetitions: Int
    var isCompleted: Bool
    var createdAt: Date

    init(
        title: String,
        intervalMinutes: Int,
        startDate: Date,
        maxRepetitions: Int = 18
    ) {
        self.id = UUID()
        self.title = title
        self.intervalMinutes = intervalMinutes
        self.startDate = startDate
        self.maxRepetitions = maxRepetitions
        self.isCompleted = false
        self.createdAt = Date()
    }
}
