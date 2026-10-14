import Foundation

public struct QueueCounts: Sendable, Equatable {
    public var pending = 0
    public var running = 0
    public var failed = 0
    public var byType: [JobType: Int] = [:]
    public init() {}
}

extension RecallStore {
    static func job(from row: Row) -> JobRecord? {
        guard let type = JobType(rawValue: row.string("job_type") ?? "") else { return nil }
        return JobRecord(
            id: row.int("id")!, type: type, entityType: row.string("entity_type") ?? "",
            entityID: row.int("entity_id") ?? 0,
            status: ProcessingStatus(rawValue: row.string("status") ?? "") ?? .pending,
            priority: Int(row.int("priority") ?? 0), attempts: Int(row.int("attempts") ?? 0),
            lastError: row.string("last_error"), createdAt: row.date("created_at") ?? Date(),
            nextAttemptAt: row.date("next_attempt_at") ?? Date(), completedAt: row.date("completed_at"))
    }

    /// Enqueues a job unless an identical one is already pending/running.
    /// Re-enqueueing raises the priority of the existing job (user-requested work jumps the queue).
    public func enqueueJob(_ type: JobType, entityType: String, entityID: Int64, priority: Int = 0, at date: Date = Date()) throws {
        try db.run("""
            INSERT INTO ai_jobs (job_type, entity_type, entity_id, priority, created_at, next_attempt_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(job_type, entity_type, entity_id) WHERE status IN ('pending', 'running')
            DO UPDATE SET priority = MAX(priority, excluded.priority), next_attempt_at = MIN(next_attempt_at, excluded.next_attempt_at)
            """, [type.rawValue, entityType, entityID, priority, date, date])
    }

    /// Atomically claims up to `limit` ready jobs of the allowed types, highest priority and newest first.
    public func claimJobs(types: Set<JobType>, limit: Int, now: Date = Date()) throws -> [JobRecord] {
        guard !types.isEmpty, limit > 0 else { return [] }
        return try db.transaction {
            let typeList = types.map(\.rawValue).sorted()
            let rows = try db.query("""
                SELECT * FROM ai_jobs WHERE status = 'pending' AND next_attempt_at <= ?
                AND job_type IN (\(Array(repeating: "?", count: typeList.count).joined(separator: ",")))
                ORDER BY priority DESC, created_at DESC LIMIT ?
                """, [now] + (typeList as [SQLBindable]) + [limit])
            let jobs = rows.compactMap(Self.job(from:))
            for job in jobs {
                try db.run("UPDATE ai_jobs SET status = 'running', started_at = ? WHERE id = ?", [now, job.id])
            }
            return jobs
        }
    }

    public func completeJob(id: Int64, at date: Date = Date()) throws {
        try db.run("UPDATE ai_jobs SET status = 'done', completed_at = ?, last_error = NULL WHERE id = ?", [date, id])
    }

    /// Returns the job to the queue without counting an attempt (e.g. Ollama went offline mid-flight).
    public func deferJob(id: Int64, until date: Date) throws {
        try db.run("UPDATE ai_jobs SET status = 'pending', next_attempt_at = ? WHERE id = ?", [date, id])
    }

    /// Records a failure. Retryable failures back off exponentially up to `maxAttempts`.
    @discardableResult
    public func failJob(id: Int64, error: String, retryable: Bool, maxAttempts: Int = 5,
                        baseDelay: TimeInterval = 30, maxDelay: TimeInterval = 3600, now: Date = Date()) throws -> ProcessingStatus {
        guard let row = try db.queryOne("SELECT attempts FROM ai_jobs WHERE id = ?", [id]) else { return .failed }
        let attempts = Int(row.int("attempts") ?? 0) + 1
        let truncated = String(error.prefix(500))
        if retryable && attempts < maxAttempts {
            let delay = Self.backoff(attempt: attempts, base: baseDelay, cap: maxDelay)
            try db.run("UPDATE ai_jobs SET status = 'pending', attempts = ?, last_error = ?, next_attempt_at = ? WHERE id = ?",
                       [attempts, truncated, now.addingTimeInterval(delay), id])
            return .pending
        }
        try db.run("UPDATE ai_jobs SET status = 'failed', attempts = ?, last_error = ?, completed_at = ? WHERE id = ?",
                   [attempts, truncated, now, id])
        return .failed
    }

    public static func backoff(attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        min(cap, base * pow(2, Double(max(0, attempt - 1))))
    }

    /// Jobs left `running` by a previous process are returned to the queue.
    public func recoverInterruptedJobs() throws -> Int {
        try requeueOrphanedJobs(excluding: [])
    }

    /// Returns `running` jobs that no live worker holds to `pending` (e.g. after a bookkeeping write
    /// failed). `inFlight` are the IDs this process is actually working on.
    @discardableResult
    public func requeueOrphanedJobs(excluding inFlight: Set<Int64>) throws -> Int {
        guard !inFlight.isEmpty else { return try db.run("UPDATE ai_jobs SET status = 'pending' WHERE status = 'running'") }
        let ids = inFlight.sorted()
        return try db.run("UPDATE ai_jobs SET status = 'pending' WHERE status = 'running' AND id NOT IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))",
                          ids as [SQLBindable])
    }

    public func retryFailedJobs(types: Set<JobType>? = nil) throws {
        if let types {
            for type in types {
                try db.run("UPDATE ai_jobs SET status = 'pending', attempts = 0, next_attempt_at = ? WHERE status = 'failed' AND job_type = ?",
                           [Date(), type.rawValue])
            }
        } else {
            try db.run("UPDATE ai_jobs SET status = 'pending', attempts = 0, next_attempt_at = ? WHERE status = 'failed'", [Date()])
        }
    }

    public func queueCounts() throws -> QueueCounts {
        var counts = QueueCounts()
        for row in try db.query("SELECT status, job_type, COUNT(*) AS n FROM ai_jobs WHERE status IN ('pending','running','failed') GROUP BY status, job_type") {
            let n = Int(row.int("n") ?? 0)
            switch row.string("status") {
            case "pending": counts.pending += n
            case "running": counts.running += n
            case "failed": counts.failed += n
            default: break
            }
            if row.string("status") != "failed", let type = JobType(rawValue: row.string("job_type") ?? "") {
                counts.byType[type, default: 0] += n
            }
        }
        return counts
    }

    public func recentJobs(limit: Int = 100) throws -> [JobRecord] {
        try db.query("SELECT * FROM ai_jobs ORDER BY COALESCE(completed_at, created_at) DESC LIMIT ?", [limit]).compactMap(Self.job(from:))
    }

    public func purgeCompletedJobs(olderThan date: Date) throws {
        try db.run("DELETE FROM ai_jobs WHERE status = 'done' AND completed_at < ?", [date])
    }
}
