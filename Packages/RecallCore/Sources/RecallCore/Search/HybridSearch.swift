import Foundation

public struct CaptureHit: Sendable, Identifiable, Hashable {
    public var id: Int64 { capture.id }
    public var capture: CaptureRecord
    public var snippet: String
    public var score: Double
    public var matchedKeyword: Bool
    public var matchedSemantic: Bool
}

public struct SessionHit: Sendable, Identifiable, Hashable {
    public var id: Int64 { session.id }
    public var session: SessionRecord
    public var snippet: String
    public var score: Double
}

public struct NoteHit: Sendable, Identifiable, Hashable {
    public var id: Int64 { note.id }
    public var note: NoteRecord
    public var snippet: String
}

public struct SearchResults: Sendable {
    public var interpretation: QueryInterpretation
    public var captures: [CaptureHit]
    public var sessions: [SessionHit]
    /// Notes the user wrote, most relevant first. Keyword matches only.
    public var notes: [NoteHit] = []
    public var semanticUsed: Bool
    /// Filters that were relaxed because they produced no results.
    public var relaxedFilters: [String]
}

/// Hybrid retrieval: interpret dates/apps → filter → FTS5 + vector search → reciprocal-rank fusion.
public struct HybridSearch: Sendable {
    let store: RecallStore
    let ai: (any AIProvider)?
    let vectorIndex: VectorIndex
    let embeddingModel: String
    /// Key the vectors were stored under (provider-namespaced, see `RecallSettings.embeddingIndexKey`).
    let embeddingKey: String

    public init(store: RecallStore, ai: (any AIProvider)?, embeddingModel: String, embeddingKey: String? = nil, vectorIndex: VectorIndex? = nil) {
        self.store = store
        self.ai = ai
        self.embeddingModel = embeddingModel
        self.embeddingKey = embeddingKey ?? embeddingModel
        self.vectorIndex = vectorIndex ?? ScanVectorIndex(store: store)
    }

    /// `range` and `applicationNames` replace what the query itself implies; explicit filters are never relaxed.
    public func search(_ query: String, projectID: Int64? = nil, range: DateInterval? = nil, applicationNames: [String]? = nil,
                       exact: Bool = false, limit: Int = 60, now: Date = Date()) async throws -> SearchResults {
        let apps = try store.applications().map(\.name)
        let interpretation = QueryInterpreter(now: now, knownApplications: apps).interpret(query)
        var relaxed: [String] = []

        var scope = SearchScope(range: range ?? interpretation.range, applicationNames: applicationNames ?? interpretation.applicationNames,
                                projectID: projectID)
        let text = exact ? query : interpretation.keywordText
        let keyword = KeywordSearch(store: store)

        // Natural-language queries match any term (ranked by BM25); exact mode requires all terms.
        var kwHits = try keyword.searchCaptures(text, mode: exact ? .all : .any, scope: scope, limit: 150)
        var vecHits = try await semantic(query, scope: scope)
        if kwHits.isEmpty && vecHits.isEmpty && !scope.applicationNames.isEmpty && applicationNames == nil {
            relaxed.append("application")
            scope.applicationNames = []
            kwHits = try keyword.searchCaptures(text, mode: exact ? .all : .any, scope: scope, limit: 150)
            vecHits = try await semantic(query, scope: scope)
        }
        // A query that is only a time/app filter ("what was I doing yesterday morning") lists that period.
        var browse: [CaptureRecord] = []
        if kwHits.isEmpty && vecHits.isEmpty && interpretation.keywords.isEmpty && interpretation.quotedPhrases.isEmpty,
           let range = scope.range {
            browse = try store.captures(from: range.start, to: range.end, limit: limit).filter {
                scope.applicationNames.isEmpty || scope.applicationNames.contains($0.applicationName)
            }
        }

        // Reciprocal rank fusion (k = 60).
        var fused: [Int64: (score: Double, snippet: String, kw: Bool, sem: Bool)] = [:]
        for (rank, hit) in kwHits.enumerated() {
            fused[hit.entityID, default: (0, "", false, false)].score += 1 / (60 + Double(rank))
            fused[hit.entityID]!.snippet = hit.snippet
            fused[hit.entityID]!.kw = true
        }
        for (rank, hit) in vecHits.enumerated() where hit.entityType == "capture" {
            fused[hit.entityID, default: (0, "", false, false)].score += 1 / (60 + Double(rank))
            fused[hit.entityID]!.sem = true
        }
        for (rank, capture) in browse.enumerated() {
            fused[capture.id, default: (0, "", false, false)].score += 1 / (60 + Double(rank))
        }
        var ranked = fused.sorted { $0.value.score > $1.value.score }.prefix(limit * 2).map { $0 }
        let records = Dictionary(uniqueKeysWithValues: try store.captures(ids: ranked.map(\.key)).map { ($0.id, $0) })
        if interpretation.wantsLatest {
            // "the last time I…": among relevant results, prefer recency.
            ranked = ranked.sorted { (records[$0.key]?.capturedAt ?? .distantPast) > (records[$1.key]?.capturedAt ?? .distantPast) }
        }
        let captureHits = ranked.prefix(limit).compactMap { entry -> CaptureHit? in
            guard let record = records[entry.key] else { return nil }
            let snippet = entry.value.snippet.isEmpty ? Self.fallbackSnippet(record) : entry.value.snippet
            return CaptureHit(capture: record, snippet: snippet, score: entry.value.score,
                              matchedKeyword: entry.value.kw, matchedSemantic: entry.value.sem)
        }

        // Sessions: keyword + semantic, fused the same way.
        let sessionKW = try keyword.searchSessions(text, mode: exact ? .all : .any, scope: scope, limit: 20)
        var sessionScores: [Int64: (Double, String)] = [:]
        for (rank, hit) in sessionKW.enumerated() { sessionScores[hit.entityID] = (1 / (60 + Double(rank)), hit.snippet) }
        for (rank, hit) in vecHits.filter({ $0.entityType == "session" }).enumerated() {
            sessionScores[hit.entityID, default: (0, "")].0 += 1 / (60 + Double(rank))
        }
        // Sessions containing top captures are relevant too.
        for hit in captureHits.prefix(10) {
            if let sid = hit.capture.sessionID { sessionScores[sid, default: (0, "")].0 += hit.score * 0.5 }
        }
        let topSessions = sessionScores.sorted { $0.value.0 > $1.value.0 }.prefix(12)
        let sessionRecords = Dictionary(uniqueKeysWithValues: try store.sessions(ids: topSessions.map(\.key)).map { ($0.id, $0) })
        let sessionHits = topSessions.compactMap { entry -> SessionHit? in
            guard let s = sessionRecords[entry.key] else { return nil }
            return SessionHit(session: s, snippet: entry.value.1.isEmpty ? s.summary : entry.value.1, score: entry.value.0)
        }

        // Notes: keyword matches, or every note in the period for a time-only query. Notes have no app, so only an
        // explicit app filter excludes them; an app named in the query ("the slack integration") doesn't.
        let noteScope = SearchScope(range: scope.range, applicationNames: applicationNames ?? [], projectID: projectID)
        var noteIDs = try keyword.searchNotes(text, mode: exact ? .all : .any, scope: noteScope, limit: 20)
        var snippets = Dictionary(noteIDs.map { ($0.entityID, $0.snippet) }, uniquingKeysWith: { a, _ in a })
        if noteIDs.isEmpty && interpretation.keywords.isEmpty && interpretation.quotedPhrases.isEmpty && scope.applicationNames.isEmpty,
           let range = scope.range {
            noteIDs = try store.notes(from: range.start, to: range.end, projectID: projectID, limit: 20)
                .map { KeywordHit(entityType: "note", entityID: $0.id, snippet: "", rank: 0) }
            snippets = [:]
        }
        var noteHits = try store.notes(ids: noteIDs.map(\.entityID)).map {
            NoteHit(note: $0, snippet: snippets[$0.id].flatMap { $0.isEmpty ? nil : $0 } ?? $0.text.clipped(200))
        }
        if interpretation.wantsLatest { noteHits.sort { $0.note.createdAt > $1.note.createdAt } }

        return SearchResults(interpretation: interpretation, captures: captureHits, sessions: sessionHits, notes: noteHits,
                             semanticUsed: !vecHits.isEmpty, relaxedFilters: relaxed)
    }

    private func semantic(_ query: String, scope: SearchScope) async throws -> [VectorHit] {
        guard let ai, !embeddingModel.isEmpty, try store.embeddingCount(model: embeddingKey) > 0 else { return [] }
        guard let vector = try? await ai.embed(model: embeddingModel, inputs: [query], purpose: .query).first else { return [] }
        let range = scope.range ?? DateInterval(start: .distantPast, end: .distantFuture)
        var hits = try vectorIndex.search(query: vector, model: embeddingKey, entityTypes: ["capture", "session"],
                                          from: range.start, to: range.end, limit: 80)
        // Drop weak matches: cosine below this is mostly noise for typical embedding models.
        hits = hits.filter { $0.score >= 0.3 }
        if !scope.applicationNames.isEmpty {
            let allowed = Set(try store.captures(ids: hits.filter { $0.entityType == "capture" }.map(\.entityID))
                .filter { scope.applicationNames.contains($0.applicationName) }.map(\.id))
            hits = hits.filter { $0.entityType != "capture" || allowed.contains($0.entityID) }
        }
        return hits
    }

    static func fallbackSnippet(_ c: CaptureRecord) -> String {
        if !c.aiDescription.isEmpty { return c.aiDescription.clipped(200) }
        return c.ocrText.replacingOccurrences(of: "\n", with: " ").clipped(200)
    }
}
