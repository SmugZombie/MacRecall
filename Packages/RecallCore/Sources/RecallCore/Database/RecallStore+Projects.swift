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
            try db.run("DELETE FROM projects WHERE id = ?", [id])
        }
    }

    /// Touches project references so FTS triggers pick up a renamed project.
    func reindexProject(_ id: Int64) throws {
        try db.run("UPDATE captures SET project_id = project_id WHERE project_id = ?", [id])
        try db.run("UPDATE sessions SET project_id = project_id WHERE project_id = ?", [id])
    }

    public func projectActiveSeconds(projectID: Int64, from start: Date = .distantPast, to end: Date = .distantFuture) throws -> Double {
        try db.queryOne("SELECT COALESCE(SUM(active_seconds), 0) AS total FROM sessions WHERE project_id = ? AND started_at >= ? AND started_at < ?",
                        [projectID, start, end])?.double("total") ?? 0
    }
}
