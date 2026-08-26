import Foundation
import GRDB

enum JobStatus: String, Codable, DatabaseValueConvertible {
    case pending
    case recording
    case transcribing
    case translating
    case completed
    case failed
    case cancelled
}

struct Job: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "jobs"

    var id: String
    var name: String?
    var text: String
    var translatedText: String?
    var translatedLanguage: String?
    var status: JobStatus
    var error: String?
    var sourceLanguage: String?
    var targetLanguage: String?
    var asrEngine: String?
    var translationEngine: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String? = nil,
        text: String = "",
        translatedText: String? = nil,
        translatedLanguage: String? = nil,
        status: JobStatus = .pending,
        error: String? = nil,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        asrEngine: String? = nil,
        translationEngine: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.translatedText = translatedText
        self.translatedLanguage = translatedLanguage
        self.status = status
        self.error = error
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.asrEngine = asrEngine
        self.translationEngine = translationEngine
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    var displayText: String {
        text.isEmpty ? "(No transcript)" : String(text.prefix(100))
    }

    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}
