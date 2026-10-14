import Foundation

extension RecallStore {
    static let sessionSelect = """
        SELECT s.*, p.name AS project_name,
            (SELECT COUNT(*) FROM captures c WHERE c.activity_session_id = s.id) AS capture_count,
            (SELECT GROUP_CONCAT(DISTINCT a.name) FROM captures c JOIN applications a ON a.id = c.application_id
                WHERE c.activity_session_id = s.id) AS app_names,
            (SELECT GROUP_CONCAT(DISTINCT a.bundle_identifier) FROM captures c JOIN applications a ON a.id = c.application_id
                WHERE c.activity_session_id = s.id) AS bundle_ids,
            (SELECT c.thumbnail_path FROM captures c WHERE c.activity_session_id = s.id
                ORDER BY c.captured_at DESC LIMIT 1) AS thumb
        FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
        """

    static func session(from row: Row) -> SessionRecord {
        SessionRecord(
            id: row.int("id")!,
            startedAt: row.date("started_at") ?? .distantPast,
            endedAt: row.date("ended_at") ?? .distantPast,
            title: row.string("title") ?? "",
            titleSource: row.string("title_source") ?? "deterministic",
            summary: row.string("summary") ?? "",
            projectID: row.int("project_id"),
            projectName: row.string("project_name"),
            projectSource: row.string("project_source") ?? "none",
            classificationConfidence: row.double("classification_confidence"),
            activeSeconds: row.double("active_seconds") ?? 0,
            userLocked: row.bool("user_locked"),
            captureCount: Int(row.int("capture_count") ?? 0),
            applicationNames: (row.string("app_names") ?? "").split(separator: ",").map(String.init),
            bundleIdentifiers: (row.string("bundle_ids") ?? "").split(separator: ",").map(String.init),
            thumbnailPath: row.string("thumb"))
    }

    public func session(id: Int64) throws -> SessionRecord? {
        try db.queryOne("\(Self.sessionSelect) WHERE s.id = ?", [id]).map(Self.session(from:))
    }

    public func sessions(ids: [Int64]) throws -> [SessionRecord] {
        guard !ids.isEmpty else { return [] }
        let rows = try db.query("\(Self.sessionSelect) WHERE s.id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))", ids)
        let byID = Dictionary(uniqueKeysWithValues: rows.map(Self.session(from:)).map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Sessions overlapping a range, newest first.
    public func sessions(from start: Date, to end: Date, projectID: Int64? = nil, ascending: Bool = false,
                         limit: Int = 500, offset: Int = 0) throws -> [SessionRecord] {
        var sql = "\(Self.sessionSelect) WHERE s.ended_at >= ? AND s.started_at < ?"
        var params: [SQLBindable] = [start, end]
        if let projectID {
            sql += " AND s.project_id = ?"
            params.append(projectID)
        }
        sql += " ORDER BY s.started_at \(ascending ? "ASC" : "DESC") LIMIT ? OFFSET ?"
        params += [limit, offset]
        return try db.query(sql, params).map(Self.session(from:))
    }

    public func latestOpenSession() throws -> SessionRecord? {
        try db.queryOne("\(Self.sessionSelect) ORDER BY s.ended_at DESC LIMIT 1").map(Self.session(from:))
    }

    public func createSession(start: Date, end: Date, title: String, activeSeconds: Double, captureIDs: [Int64]) throws -> Int64 {
        try db.transaction {
            let id = try db.insert("INSERT INTO sessions (started_at, ended_at, title, active_seconds) VALUES (?, ?, ?, ?)",
                                   [start, end, title, activeSeconds])
            try assign(captureIDs: captureIDs, toSession: id)
            return id
        }
    }

    public func extendSession(id: Int64, end: Date, activeSeconds: Double, title: String?, captureIDs: [Int64]) throws {
        try db.transaction {
            try db.run("UPDATE sessions SET ended_at = MAX(ended_at, ?), active_seconds = ? WHERE id = ?", [end, activeSeconds, id])
            if let title {
                try db.run("UPDATE sessions SET title = ? WHERE id = ? AND title_source = 'deterministic' AND user_locked = 0", [title, id])
            }
            try assign(captureIDs: captureIDs, toSession: id)
        }
    }

    private func assign(captureIDs: [Int64], toSession id: Int64) throws {
        for captureID in captureIDs {
            try db.run("UPDATE captures SET activity_session_id = ? WHERE id = ?", [id, captureID])
        }
    }

    /// Updates title/summary from AI unless the user has edited the session.
    public func applyAISessionResult(id: Int64, title: String, summary: String, confidence: Double?) throws {
        try db.run("""
            UPDATE sessions SET
                title = CASE WHEN user_locked = 0 THEN ? ELSE title END,
                title_source = CASE WHEN user_locked = 0 THEN 'ai' ELSE title_source END,
                summary = ?, classification_confidence = ?
            WHERE id = ?
            """, [title, summary, confidence, id])
    }

    public func renameSession(id: Int64, title: String) throws {
        try db.run("UPDATE sessions SET title = ?, title_source = 'user', user_locked = 1 WHERE id = ?", [title, id])
    }

    public func setSessionProject(id: Int64, projectID: Int64?, source: String, confidence: Double? = nil) throws {
        try db.transaction {
            if source == "user" {
                try db.run("UPDATE sessions SET project_id = ?, project_source = 'user', user_locked = 1 WHERE id = ?", [projectID, id])
            } else {
                // Never override a user's correction with an automatic association.
                try db.run("""
                    UPDATE sessions SET project_id = ?, project_source = ?, classification_confidence = COALESCE(?, classification_confidence)
                    WHERE id = ? AND project_source != 'user'
                    """, [projectID, source, confidence, id])
            }
            try db.run("UPDATE captures SET project_id = (SELECT project_id FROM sessions WHERE id = ?) WHERE activity_session_id = ?", [id, id])
        }
    }

    /// Merges `others` into `target`, keeping all capture timestamps.
    public func mergeSessions(target: Int64, others: [Int64]) throws {
        try db.transaction {
            for other in others where other != target {
                try db.run("UPDATE captures SET activity_session_id = ? WHERE activity_session_id = ?", [target, other])
                try db.run("DELETE FROM sessions WHERE id = ?", [other])
            }
            try recomputeBounds(sessionID: target)
            try db.run("UPDATE sessions SET user_locked = 1 WHERE id = ?", [target])
        }
    }

    /// Splits a session so captures at or after `date` move to a new session. Returns the new id.
    @discardableResult
    public func splitSession(id: Int64, at date: Date) throws -> Int64? {
        try db.transaction {
            guard let original = try session(id: id) else { return nil }
            let moving = try db.query("SELECT id FROM captures WHERE activity_session_id = ? AND captured_at >= ?", [id, date])
            let staying = try db.scalarInt("SELECT COUNT(*) FROM captures WHERE activity_session_id = ? AND captured_at < ?", [id, date])
            guard !moving.isEmpty, staying > 0 else { return nil }
            let newID = try db.insert("""
                INSERT INTO sessions (started_at, ended_at, title, title_source, project_id, project_source, user_locked)
                VALUES (?, ?, ?, 'user', ?, ?, 1)
                """, [date, original.endedAt, original.title + " (continued)", original.projectID, original.projectSource])
            try db.run("UPDATE captures SET activity_session_id = ? WHERE activity_session_id = ? AND captured_at >= ?", [newID, id, date])
            try recomputeBounds(sessionID: id)
            try recomputeBounds(sessionID: newID)
            try db.run("UPDATE sessions SET user_locked = 1 WHERE id = ?", [id])
            return newID
        }
    }

    func recomputeBounds(sessionID: Int64) throws {
        let caps = try captures(inSession: sessionID)
        guard let first = caps.first, let last = caps.last else { return }
        let active = SessionBuilder.activeSeconds(for: caps.map { ($0.capturedAt, $0.lastSeenAt) })
        try db.run("UPDATE sessions SET started_at = ?, ended_at = ?, active_seconds = ? WHERE id = ?",
                   [first.capturedAt, max(last.lastSeenAt, last.capturedAt), active, sessionID])
    }

    public func deleteEmptySessions() throws {
        try db.run("DELETE FROM sessions WHERE id NOT IN (SELECT DISTINCT activity_session_id FROM captures WHERE activity_session_id IS NOT NULL)")
    }

    // MARK: Daily summaries

    public func dailySummary(localDate: String, timezone: String) throws -> DailySummaryRecord? {
        try db.queryOne("SELECT * FROM daily_summaries WHERE local_date = ? AND timezone = ?", [localDate, timezone]).map {
            DailySummaryRecord(localDate: $0.string("local_date") ?? "", timezone: $0.string("timezone") ?? "",
                               summary: $0.string("summary") ?? "", generatedAt: $0.date("generated_at") ?? Date())
        }
    }

    public func saveDailySummary(_ record: DailySummaryRecord) throws {
        try db.run("""
            INSERT INTO daily_summaries (local_date, timezone, summary, generated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(local_date, timezone) DO UPDATE SET summary = excluded.summary, generated_at = excluded.generated_at
            """, [record.localDate, record.timezone, record.summary, record.generatedAt])
    }
}
