import Foundation

public struct KeywordHit: Sendable, Hashable {
    public var entityType: String
    public var entityID: Int64
    /// Snippet with matches wrapped in «».
    public var snippet: String
    public var rank: Double
}

public struct SearchScope: Sendable, Equatable {
    public var range: DateInterval?
    public var applicationNames: [String] = []
    public var projectID: Int64?

    public init(range: DateInterval? = nil, applicationNames: [String] = [], projectID: Int64? = nil) {
        self.range = range
        self.applicationNames = applicationNames
        self.projectID = projectID
    }
}

/// SQLite FTS5 search over captures and sessions.
public struct KeywordSearch: Sendable {
    public enum Mode: Sendable { case all, any }

    let store: RecallStore
    public init(store: RecallStore) { self.store = store }

    /// Converts free text into a safe FTS5 expression. User input is never passed through raw:
    /// every term is quoted, so FTS operators and syntax errors can't be injected.
    public static func ftsQuery(_ text: String, mode: Mode) -> String? {
        var terms: [String] = []
        var remainder = text
        if let regex = try? NSRegularExpression(pattern: "\"([^\"]+)\"") {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let words = tokenize(ns.substring(with: m.range(at: 1)))
                if !words.isEmpty { terms.append("\"" + words.joined(separator: " ") + "\"") }
            }
            remainder = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }
        // Each bare word becomes a phrase of its sub-tokens, so "docker-compose.yml" matches "docker compose yml".
        let words = remainder.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, word) in words.enumerated() {
            let parts = tokenize(word)
            guard !parts.isEmpty else { continue }
            var term = "\"" + parts.joined(separator: " ") + "\""
            // Prefix-match the final word so results appear while typing.
            if index == words.count - 1 && parts.count == 1 && parts[0].count >= 2 { term += "*" }
            terms.append(term)
        }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: mode == .all ? " " : " OR ")
    }

    static func tokenize(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    public func searchCaptures(_ text: String, mode: Mode = .all, scope: SearchScope = SearchScope(), limit: Int = 100, offset: Int = 0) throws -> [KeywordHit] {
        guard let fts = Self.ftsQuery(text, mode: mode) else { return [] }
        var sql = """
            SELECT c.id, snippet(capture_fts, -1, '«', '»', '…', 14) AS snip,
                   bm25(capture_fts, 3.0, 4.0, 1.0, 2.0, 2.0) AS score
            FROM capture_fts JOIN captures c ON c.id = capture_fts.rowid
            JOIN applications a ON a.id = c.application_id
            WHERE capture_fts MATCH ?
            """
        var params: [SQLBindable] = [fts]
        appendScope(scope, to: &sql, params: &params, timeColumn: "c.captured_at")
        if let projectID = scope.projectID {
            sql += " AND (c.project_id = ? OR c.activity_session_id IN (SELECT id FROM sessions WHERE project_id = ?))"
            params += [projectID, projectID]
        }
        sql += " ORDER BY score LIMIT ? OFFSET ?"
        params += [limit, offset]
        return try store.db.query(sql, params).map {
            KeywordHit(entityType: "capture", entityID: $0.int("id")!, snippet: $0.string("snip") ?? "", rank: $0.double("score") ?? 0)
        }
    }

    public func searchSessions(_ text: String, mode: Mode = .all, scope: SearchScope = SearchScope(), limit: Int = 30) throws -> [KeywordHit] {
        guard let fts = Self.ftsQuery(text, mode: mode) else { return [] }
        var sql = """
            SELECT s.id, snippet(session_fts, -1, '«', '»', '…', 14) AS snip, bm25(session_fts, 3.0, 1.0, 2.0) AS score
            FROM session_fts JOIN sessions s ON s.id = session_fts.rowid
            WHERE session_fts MATCH ?
            """
        var params: [SQLBindable] = [fts]
        if let range = scope.range {
            sql += " AND s.ended_at >= ? AND s.started_at < ?"
            params += [range.start, range.end]
        }
        if let projectID = scope.projectID {
            sql += " AND s.project_id = ?"
            params.append(projectID)
        }
        sql += " ORDER BY score LIMIT ?"
        params.append(limit)
        return try store.db.query(sql, params).map {
            KeywordHit(entityType: "session", entityID: $0.int("id")!, snippet: $0.string("snip") ?? "", rank: $0.double("score") ?? 0)
        }
    }

    private func appendScope(_ scope: SearchScope, to sql: inout String, params: inout [SQLBindable], timeColumn: String) {
        if let range = scope.range {
            sql += " AND \(timeColumn) >= ? AND \(timeColumn) < ?"
            params += [range.start, range.end]
        }
        if !scope.applicationNames.isEmpty {
            sql += " AND a.name COLLATE NOCASE IN (\(Array(repeating: "?", count: scope.applicationNames.count).joined(separator: ",")))"
            params += scope.applicationNames as [SQLBindable]
        }
    }
}
