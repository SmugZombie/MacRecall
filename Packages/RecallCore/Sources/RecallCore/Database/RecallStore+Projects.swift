import Foundation

extension RecallStore {
    static func project(from row: Row) -> ProjectRecord {
        let rules = (row.string("identification_rules_json")?.data(using: .utf8))
            .flatMap { try? JSONDecoder().decode(ProjectRules.self, from: $0) } ?? ProjectRules()
        return ProjectRecord(id: row.int("id")!, name: row.string("name") ?? "", description: row.string("description") ?? "",
                             rules: rules, createdAt: row.date("created_at") ?? Date())
    }

    public func projects() throws -> [ProjectRecord] {
        try db.query("SELECT * FROM projects ORDER BY name COLLATE NOCASE").map(Self.project(from:))
    }

    public func project(id: Int64) throws -> ProjectRecord? {
        try db.queryOne("SELECT * FROM projects WHERE id = ?", [id]).map(Self.project(from:))
    }

    public func project(named name: String) throws -> ProjectRecord? {
        try db.queryOne("SELECT * FROM projects WHERE name = ? COLLATE NOCASE", [name]).map(Self.project(from:))
    }

    @discardableResult
    public func createProject(name: String, description: String = "", rules: ProjectRules = ProjectRules()) throws -> Int64 {
        let json = String(data: try JSONEncoder().encode(rules), encoding: .utf8) ?? "{}"
        return try db.insert("INSERT INTO projects (name, description, identification_rules_json, created_at) VALUES (?, ?, ?, ?)",
                             [name, description, json, Date()])
    }

    public func updateProject(_ project: ProjectRecord) throws {
        let json = String(data: try JSONEncoder().encode(project.rules), encoding: .utf8) ?? "{}"
        try db.transaction {
            try db.run("UPDATE projects SET name = ?, description = ?, identification_rules_json = ? WHERE id = ?",
                       [project.name, project.description, json, project.id])
            try reindexProject(project.id)
        }
    }

    /// Moves all activity from `source` into `target` and deletes `source`.
    public func mergeProjects(source: Int64, into target: Int64) throws {
        guard source != target else { return }
        try db.transaction {
            try db.run("UPDATE sessions SET project_id = ? WHERE project_id = ?", [target, source])
            try db.run("UPDATE captures SET project_id = ? WHERE project_id = ?", [target, source])
            try db.run("UPDATE notes SET project_id = ? WHERE project_id = ?", [target, source])
            if let s = try project(id: source), var t = try project(id: target) {
                t.rules.keywords = Array(Set(t.rules.keywords + s.rules.keywords)).sorted()
                t.rules.aliases = Array(Set(t.rules.aliases + s.rules.aliases + [s.name])).sorted()
                t.rules.repositoryPaths = Array(Set(t.rules.repositoryPaths + s.rules.repositoryPaths)).sorted()
                t.rules.domains = Array(Set(t.rules.domains + s.rules.domains)).sorted()
                t.rules.bundleIdentifiers = Array(Set(t.rules.bundleIdentifiers + s.rules.bundleIdentifiers)).sorted()
                try updateProject(t)
            }
            try db.run("DELETE FROM projects WHERE id = ?", [source])
            try reindexProject(target)
        }
    }

    public func deleteProject(id: Int64) throws {
        try db.transaction {
            // Clear references explicitly (rather than relying on ON DELETE SET NULL) so FTS triggers fire.
            try db.run("UPDATE sessions SET project_id = NULL, project_source = 'none' WHERE project_id = ?", [id])
            try db.run("UPDATE captures SET project_id = NULL WHERE project_id = ?", [id])
            try db.run("UPDATE notes SET project_id = NULL WHERE project_id = ?", [id])
            try db.run("DELETE FROM projects WHERE id = ?", [id])
        }
    }

    /// Touches project references so FTS triggers pick up a renamed project.
    func reindexProject(_ id: Int64) throws {
        try db.run("UPDATE captures SET project_id = project_id WHERE project_id = ?", [id])
        try db.run("UPDATE sessions SET project_id = project_id WHERE project_id = ?", [id])
        try db.run("UPDATE notes SET project_id = project_id WHERE project_id = ?", [id])
    }

    // MARK: Suggestions

    static let dismissedSuggestionsKey = "project_suggestions_dismissed"

    /// Projects that recur in recent activity not yet assigned to any project.
    public func projectSuggestions(lookback: TimeInterval = 30 * 86400, now: Date = Date(),
                                   suggester: ProjectSuggester = ProjectSuggester()) throws -> [ProjectSuggestion] {
        // Only OCR text that can contain a path is loaded; most captures contribute just their title and AI hint.
        let rows = try db.query("""
            SELECT c.captured_at, a.name AS app_name, COALESCE(w.title, '') AS window_title,
                CASE WHEN json_valid(c.ai_json) THEN json_extract(c.ai_json, '$.project') END AS ai_project,
                CASE WHEN instr(c.ocr_text, '~/') > 0 OR instr(c.ocr_text, '/Users/') > 0 THEN c.ocr_text ELSE '' END AS path_text
            FROM captures c
            JOIN applications a ON a.id = c.application_id
            LEFT JOIN windows w ON w.id = c.window_id
            LEFT JOIN sessions s ON s.id = c.activity_session_id
            WHERE c.captured_at >= ? AND c.project_id IS NULL AND s.project_id IS NULL
                AND (ai_project IS NOT NULL OR instr(window_title, '/') > 0 OR path_text != '')
            """, [now.addingTimeInterval(-lookback)])
        let observations = rows.map {
            ProjectSuggester.Observation(capturedAt: $0.date("captured_at") ?? now, applicationName: $0.string("app_name") ?? "",
                                         windowTitle: $0.string("window_title") ?? "", aiProject: $0.string("ai_project"),
                                         pathText: $0.string("path_text") ?? "")
        }
        return suggester.suggest(observations, existing: try projects(), dismissed: try dismissedProjectSuggestions())
    }

    public func dismissedProjectSuggestions() throws -> Set<String> {
        let data = try setting(Self.dismissedSuggestionsKey)?.data(using: .utf8)
        return Set(data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    /// Hides a suggestion for good; it won't come back however often the name recurs.
    public func dismissProjectSuggestion(_ suggestion: ProjectSuggestion) throws {
        let keys = try dismissedProjectSuggestions().union([suggestion.id])
        try setSetting(Self.dismissedSuggestionsKey, String(data: try JSONEncoder().encode(keys.sorted()), encoding: .utf8) ?? "[]")
    }

    public func projectActiveSeconds(projectID: Int64, from start: Date = .distantPast, to end: Date = .distantFuture) throws -> Double {
        try db.queryOne("SELECT COALESCE(SUM(active_seconds), 0) AS total FROM sessions WHERE project_id = ? AND started_at >= ? AND started_at < ?",
                        [projectID, start, end])?.double("total") ?? 0
    }
}
