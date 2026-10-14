import Foundation

/// Incrementally folds new captures into sessions and schedules summaries for closed sessions.
public struct ActivitySessionManager: Sendable {
    let store: RecallStore
    public var config: SessionBuilder.Config

    /// A session is "closed" (eligible for an AI summary) once nothing has joined it for this long.
    public var closeAfter: TimeInterval = 10 * 60

    public init(store: RecallStore, config: SessionBuilder.Config = .init()) {
        self.store = store
        self.config = config
    }

    /// Groups unsessioned captures. Captures from the last minute are left for the next pass so
    /// the off-topic lookahead has something to look at. Returns the number of captures placed.
    @discardableResult
    public func update(now: Date = Date()) throws -> Int {
        let pending = try store.unsessionedCaptures(before: now.addingTimeInterval(-60))
        guard !pending.isEmpty else {
            try scheduleSummaries(now: now)
            return 0
        }

        // 1. A capture inside an existing session's span (e.g. a hole left by regrouping) rejoins it,
        //    rather than starting a second session that overlaps the first.
        var remaining: [CaptureRecord] = []
        var rejoin: [Int64: [Int64]] = [:]
        for capture in pending {
            if let session = try store.sessionContaining(capture.capturedAt) {
                rejoin[session.id, default: []].append(capture.id)
            } else {
                remaining.append(capture)
            }
        }
        for (sessionID, captureIDs) in rejoin { try store.attach(captureIDs: captureIDs, toSession: sessionID) }

        // 2. Group the rest. Continue the session that ended just before them, unless the user
        //    curated it; other sessions' boundaries are hard breaks so no group straddles one.
        if let first = remaining.first, let last = remaining.last {
            var open = try store.sessionEnding(atOrBefore: first.capturedAt)
            if open?.userLocked == true { open = nil }
            let openItems = try open.map { try store.captures(inSession: $0.id).suffix(12).map(SessionBuilder.Item.init) } ?? []
            let windowStart = openItems.first?.start ?? first.capturedAt
            let windowEnd = max(now, last.lastSeenAt)
            let interruptions = try store.events(from: windowStart, to: windowEnd, types: [.idle, .screenLocked, .sleep, .recordingPaused]).map(\.timestamp)
                + store.sessionBoundaries(from: windowStart, to: windowEnd, excluding: open?.id)
            let groups = SessionBuilder(config: config).group(remaining.map(SessionBuilder.Item.init), openSessionID: open?.id,
                                                               openItems: openItems, interruptions: interruptions)
            for group in groups where !group.items.isEmpty {
                let ids = group.items.map(\.captureID)
                if let existing = group.existingSessionID {
                    let all = try store.captures(inSession: existing).map(SessionBuilder.Item.init) + group.items
                    let active = SessionBuilder.activeSeconds(for: all.map { ($0.start, $0.lastSeen) }, credit: config.sampleCredit, maxGap: config.maxGap)
                    // extendSession only replaces deterministic titles, so AI and user titles survive.
                    try store.extendSession(id: existing, end: group.end, activeSeconds: active,
                                            title: SessionBuilder.deterministicTitle(for: all), captureIDs: ids)
                } else {
                    let active = SessionBuilder.activeSeconds(for: group.items.map { ($0.start, $0.lastSeen) }, credit: config.sampleCredit, maxGap: config.maxGap)
                    let id = try store.createSession(start: group.start, end: group.end,
                                                     title: SessionBuilder.deterministicTitle(for: group.items),
                                                     activeSeconds: active, captureIDs: ids)
                    try store.enqueueJob(.projectAssociation, entityType: "session", entityID: id, priority: 6)
                }
            }
        }
        try scheduleSummaries(now: now)
        return pending.count
    }

    /// After a summary job exhausts its retries, wait this long before scheduling another round.
    public var failedSummaryCooldown: TimeInterval = 60 * 60
    /// Stop rescheduling after this many failed rounds (e.g. the model is permanently unavailable).
    public var maxFailedSummaryRounds = 3

    /// Enqueues AI summaries for recently closed sessions that don't have one, including sessions
    /// whose earlier attempt failed (after a cooldown, a bounded number of times).
    func scheduleSummaries(now: Date) throws {
        let rows = try store.db.query("""
            SELECT s.id FROM sessions s
            WHERE s.summary = '' AND s.ended_at < ? AND s.ended_at > ?
            AND NOT EXISTS (
                SELECT 1 FROM ai_jobs j
                WHERE j.entity_type = 'session' AND j.entity_id = s.id AND j.job_type = 'session_summary'
                AND (j.status IN ('pending', 'running', 'done') OR (j.status = 'failed' AND j.completed_at > ?)))
            AND (SELECT COUNT(*) FROM ai_jobs j
                 WHERE j.entity_type = 'session' AND j.entity_id = s.id AND j.job_type = 'session_summary'
                 AND j.status = 'failed') < ?
            ORDER BY s.ended_at DESC LIMIT 50
            """, [now.addingTimeInterval(-closeAfter), now.addingTimeInterval(-14 * 86400),
                  now.addingTimeInterval(-failedSummaryCooldown), maxFailedSummaryRounds])
        for row in rows {
            if let id = row.int("id") {
                try store.enqueueJob(.sessionSummary, entityType: "session", entityID: id, priority: 8)
                try store.enqueueJob(.projectAssociation, entityType: "session", entityID: id, priority: 6)
            }
        }
    }

    /// Regroups a range from scratch (after the user tunes rules). User-curated sessions are kept;
    /// automatic sessions overlapping the range are dissolved whole, so none is left half-detached.
    public func rebuild(from start: Date, to end: Date, now: Date = Date()) throws {
        try store.db.transaction {
            try store.db.run("""
                UPDATE captures SET activity_session_id = NULL
                WHERE activity_session_id IN (SELECT id FROM sessions WHERE user_locked = 0 AND ended_at >= ? AND started_at < ?)
                """, [start, end])
            try store.deleteEmptySessions()
        }
        // update() places a bounded batch per call; every capture it fetches gets placed, so this
        // terminates, but cap it anyway rather than trust that forever.
        for _ in 0..<1000 {
            if try update(now: now) == 0 { break }
        }
    }
}
