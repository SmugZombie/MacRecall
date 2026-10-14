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
    /// the off-topic lookahead has something to look at.
    @discardableResult
    public func update(now: Date = Date()) throws -> Int {
        let pending = try store.unsessionedCaptures(before: now.addingTimeInterval(-60))
        guard let first = pending.first else {
            try scheduleSummaries(now: now)
            return 0
        }
        let open = try store.latestOpenSession()
        var openItems: [SessionBuilder.Item] = []
        if let open, open.endedAt <= first.capturedAt {
            openItems = try store.captures(inSession: open.id).suffix(12).map(SessionBuilder.Item.init)
        }
        let interruptions = try store.events(from: openItems.first?.start ?? first.capturedAt, to: now,
                                             types: [.idle, .screenLocked, .sleep, .recordingPaused]).map(\.timestamp)
        let builder = SessionBuilder(config: config)
        let groups = builder.group(pending.map(SessionBuilder.Item.init), openSessionID: openItems.isEmpty ? nil : open?.id,
                                   openItems: openItems, interruptions: interruptions)
        for group in groups where !group.items.isEmpty {
            let ids = group.items.map(\.captureID)
            if let existing = group.existingSessionID, let session = open {
                let all = try store.captures(inSession: existing).map(SessionBuilder.Item.init) + group.items
                let active = SessionBuilder.activeSeconds(for: all.map { ($0.start, $0.lastSeen) }, credit: config.sampleCredit, maxGap: config.maxGap)
                try store.extendSession(id: existing, end: group.end, activeSeconds: active,
                                        title: session.userLocked ? nil : SessionBuilder.deterministicTitle(for: all), captureIDs: ids)
            } else {
                let active = SessionBuilder.activeSeconds(for: group.items.map { ($0.start, $0.lastSeen) }, credit: config.sampleCredit, maxGap: config.maxGap)
                let id = try store.createSession(start: group.start, end: group.end,
                                                 title: SessionBuilder.deterministicTitle(for: group.items),
                                                 activeSeconds: active, captureIDs: ids)
                try store.enqueueJob(.projectAssociation, entityType: "session", entityID: id, priority: 6)
            }
        }
        try scheduleSummaries(now: now)
        return pending.count
    }

    /// Enqueues AI summaries for recently closed sessions that don't have one.
    func scheduleSummaries(now: Date) throws {
        let rows = try store.db.query("""
            SELECT id FROM sessions WHERE summary = '' AND ended_at < ? AND ended_at > ?
            AND id NOT IN (SELECT entity_id FROM ai_jobs WHERE entity_type = 'session' AND job_type = 'session_summary')
            ORDER BY ended_at DESC LIMIT 50
            """, [now.addingTimeInterval(-closeAfter), now.addingTimeInterval(-14 * 86400)])
        for row in rows {
            if let id = row.int("id") {
                try store.enqueueJob(.sessionSummary, entityType: "session", entityID: id, priority: 8)
                try store.enqueueJob(.projectAssociation, entityType: "session", entityID: id, priority: 6)
            }
        }
    }

    /// Regroups a day from scratch (after the user tunes rules). User-edited sessions are kept.
    public func rebuild(from start: Date, to end: Date) throws {
        try store.db.transaction {
            try store.db.run("""
                UPDATE captures SET activity_session_id = NULL WHERE captured_at >= ? AND captured_at < ?
                AND activity_session_id IN (SELECT id FROM sessions WHERE user_locked = 0)
                """, [start, end])
            try store.deleteEmptySessions()
        }
        try update(now: Date())
    }
}
