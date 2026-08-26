import Foundation
import GRDB

final class JobRepository: ObservableObject {
    static let shared = JobRepository()

    private var dbPool: DatabasePool?

    @Published private(set) var isReady = false

    init() {
        setup()
    }

    private func setup() {
        do {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                print("JobRepository: Cannot locate Application Support directory")
                return
            }
            let dbURL = appSupport.appendingPathComponent("earpal.db")
            dbPool = try DatabasePool(path: dbURL.path)
            try createTables()
            Task { @MainActor in
                self.isReady = true
            }
        } catch {
            print("JobRepository setup failed: \(error)")
        }
    }

    private func createTables() throws {
        guard let dbPool else { return }
        try dbPool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    text TEXT NOT NULL DEFAULT '',
                    translated_text TEXT,
                    translated_language TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    error TEXT,
                    source_language TEXT,
                    target_language TEXT,
                    asr_engine TEXT,
                    translation_engine TEXT,
                    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    completed_at TIMESTAMP
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS segments (
                    id TEXT PRIMARY KEY,
                    job_id TEXT NOT NULL,
                    start_time REAL NOT NULL DEFAULT 0,
                    end_time REAL NOT NULL DEFAULT 0,
                    text TEXT NOT NULL DEFAULT '',
                    language TEXT,
                    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE
                )
            """)
        }
    }

    // MARK: - Jobs

    func createJob(name: String? = nil) throws -> Job {
        let job = Job(name: name)
        guard let dbPool else {
            throw JobRepositoryError.databaseNotReady
        }
        try dbPool.write { db in
            try job.insert(db)
        }
        return job
    }

    func getAllJobs() -> [Job] {
        guard let dbPool else { return [] }
        do {
            return try dbPool.read { db in
                try Job.fetchAll(db, sql: "SELECT * FROM jobs ORDER BY created_at DESC")
            }
        } catch {
            print("Failed to fetch jobs: \(error)")
            return []
        }
    }

    func getJob(id: String) -> Job? {
        guard let dbPool else { return nil }
        do {
            return try dbPool.read { db in
                try Job.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id])
            }
        } catch {
            print("Failed to fetch job: \(error)")
            return nil
        }
    }

    func updateJob(_ job: Job) throws {
        guard let dbPool else { throw JobRepositoryError.databaseNotReady }
        var updated = job
        updated.updatedAt = Date()
        try dbPool.write { db in
            try updated.update(db)
        }
    }

    func updateJobTranscript(id: String, text: String) throws {
        guard let dbPool else { throw JobRepositoryError.databaseNotReady }
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE jobs SET text = ?, updated_at = ? WHERE id = ?",
                arguments: [text, Date(), id]
            )
        }
    }

    func updateJobTranslation(id: String, translatedText: String, language: String) throws {
        guard let dbPool else { throw JobRepositoryError.databaseNotReady }
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE jobs SET translated_text = ?, translated_language = ?, updated_at = ? WHERE id = ?",
                arguments: [translatedText, language, Date(), id]
            )
        }
    }

    func updateJobStatus(id: String, status: JobStatus, error: String? = nil) throws {
        guard let dbPool else { throw JobRepositoryError.databaseNotReady }
        try dbPool.write { db in
            let completedAt: Date? = (status == .completed || status == .failed) ? Date() : nil
            try db.execute(
                sql: "UPDATE jobs SET status = ?, error = ?, completed_at = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, error, completedAt, Date(), id]
            )
        }
    }

    func deleteJob(id: String) throws {
        guard let dbPool else { throw JobRepositoryError.databaseNotReady }
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM segments WHERE job_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM jobs WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Segments

    func getSegments(forJobId jobId: String) -> [Segment] {
        guard let dbPool else { return [] }
        do {
            return try dbPool.read { db in
                try Segment.fetchAll(
                    db,
                    sql: "SELECT * FROM segments WHERE job_id = ? ORDER BY start_time",
                    arguments: [jobId]
                )
            }
        } catch {
            print("Failed to fetch segments: \(error)")
            return []
        }
    }

    func saveSegments(forJobId jobId: String, segments: [Segment]) throws {
        guard let dbPool else { throw JobRepositoryError.databaseNotReady }
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM segments WHERE job_id = ?", arguments: [jobId])
            for var segment in segments {
                segment.jobId = jobId
                try segment.insert(db)
            }
        }
    }

    func updateSegment(id: String, text: String) throws {
        guard let dbPool else { throw JobRepositoryError.databaseNotReady }
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE segments SET text = ? WHERE id = ?",
                arguments: [text, id]
            )
        }
    }
}

enum JobRepositoryError: LocalizedError {
    case databaseNotReady

    var errorDescription: String? {
        switch self {
        case .databaseNotReady:
            return "Database is not available."
        }
    }
}
