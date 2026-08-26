import Foundation
import GRDB

struct Segment: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "segments"

    var id: String
    var jobId: String
    var startTime: Double
    var endTime: Double
    var text: String
    var language: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        jobId: String = "",
        startTime: Double = 0,
        endTime: Double = 0,
        text: String = "",
        language: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jobId = jobId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.language = language
        self.createdAt = createdAt
    }
}
