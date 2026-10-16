import Foundation
import Testing
@testable import RecallCore

@Suite struct CaptureDeletionTests {
    /// A capture whose screenshot and thumbnail files exist on disk.
    func addCaptureWithFiles(_ store: RecallStore, at date: Date, ocr: String, title: String = "zsh") throws -> CaptureRecord {
        let c = try addCapture(store, title: title, at: date, ocr: ocr)
        for path in [c.imagePath, c.thumbnailPath] { try store.vault.write(Data("img".utf8), to: path) }
        return c
    }

    func exists(_ store: RecallStore, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: store.paths.absolute(path).path)
    }

    @Test func removesTheCaptureAndEverythingDerivedFromIt() throws {
        let store = try makeStore()
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let doomed = try addCaptureWithFiles(store, at: t, ocr: "zanzibar password reset link")
        let kept = try addCaptureWithFiles(store, at: t.addingTimeInterval(30), ocr: "quarterly report draft")
        try store.updateAI(captureID: doomed.id, description: "Reading a zanzibar reset email", json: nil, status: .done)
        try store.saveEmbedding(entityType: "capture", entityID: doomed.id, model: "m", vector: [1, 0], entityTime: t)
        try store.enqueueJob(.visionAnalysis, entityType: "capture", entityID: doomed.id)

        let result = try store.deleteCaptures(ids: [doomed.id])
        #expect(result.deletedCaptures == 1)
        #expect(try store.capture(id: doomed.id) == nil)
        #expect(!exists(store, doomed.imagePath) && !exists(store, doomed.thumbnailPath))
        #expect(try KeywordSearch(store: store).searchCaptures("zanzibar").isEmpty)
        #expect(try store.embeddingCount(model: "m") == 0)
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM ai_jobs WHERE entity_type = 'capture' AND entity_id = ?", [doomed.id]) == 0)

        // Neighbors are untouched.
        #expect(try store.capture(id: kept.id) != nil)
        #expect(exists(store, kept.imagePath))
        #expect(try KeywordSearch(store: store).searchCaptures("quarterly").count == 1)
    }

    @Test func sessionsAreRebuiltOrRemoved() throws {
        let store = try makeStore()
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let a = try addCaptureWithFiles(store, at: t, ocr: "first", title: "Inbox")
        let b = try addCaptureWithFiles(store, at: t.addingTimeInterval(60), ocr: "zanzibar secret", title: "Secret plan")
        let c = try addCaptureWithFiles(store, at: t.addingTimeInterval(120), ocr: "third", title: "Inbox")
        let shared = try store.createSession(start: t, end: t.addingTimeInterval(150), title: "Mail", activeSeconds: 150,
                                             captureIDs: [a.id, b.id, c.id])
        try store.applyAISessionResult(id: shared, title: "Planning the zanzibar trip", summary: "Read the zanzibar secret.", confidence: 0.9)
        try store.saveEmbedding(entityType: "session", entityID: shared, model: "m", vector: [1, 0], entityTime: t)

        let solo = try addCaptureWithFiles(store, at: t.addingTimeInterval(3600), ocr: "alone")
        let lonely = try store.createSession(start: solo.capturedAt, end: solo.capturedAt, title: "Solo", activeSeconds: 30, captureIDs: [solo.id])

        let result = try store.deleteCaptures(ids: [b.id, solo.id, 999_999])
        #expect(result.deletedCaptures == 2)
        #expect(result.deletedSessions == [lonely])
        #expect(result.updatedSessions == [shared])
        #expect(try store.session(id: lonely) == nil)

        // The AI title and summary could describe the deleted screen, so they're reset and queued again.
        let session = try #require(try store.session(id: shared))
        #expect(session.captureCount == 2)
        #expect(session.summary.isEmpty && session.summarySource == "none")
        #expect(session.titleSource == "deterministic")
        #expect(!session.title.lowercased().contains("zanzibar"))
        #expect(try KeywordSearch(store: store).searchSessions("zanzibar").isEmpty)
        #expect(try store.embeddingCount(model: "m") == 0)
        #expect(try store.db.scalarInt("""
            SELECT COUNT(*) FROM ai_jobs WHERE entity_type = 'session' AND entity_id = ? AND job_type = 'session_summary' AND status = 'pending'
            """, [shared]) == 1)
    }

    @Test func userWrittenSessionTextIsKept() throws {
        let store = try makeStore()
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let a = try addCaptureWithFiles(store, at: t, ocr: "one")
        let b = try addCaptureWithFiles(store, at: t.addingTimeInterval(60), ocr: "two")
        let sid = try store.createSession(start: t, end: t.addingTimeInterval(90), title: "x", activeSeconds: 90, captureIDs: [a.id, b.id])
        try store.renameSession(id: sid, title: "My release work")
        try store.setSessionSummary(id: sid, summary: "Shipped 1.1.9.")
        try store.deleteCaptures(ids: [b.id])
        let session = try #require(try store.session(id: sid))
        #expect(session.title == "My release work")
        #expect(session.summary == "Shipped 1.1.9.")
        #expect(session.endedAt == a.lastSeenAt)
    }

    @Test func dailySummariesOfAffectedDaysAreCleared() throws {
        let store = try makeStore()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9))!
        let c = try store.insertCapture(NewCapture(bundleIdentifier: "b", applicationName: "A", pid: 1, systemWindowID: 1, windowTitle: "w",
                                                   capturedAt: day, timezone: "UTC", imagePath: "screenshots/a.heic",
                                                   thumbnailPath: "thumbnails/a.jpg", imageHash: "0", width: 1, height: 1))
        for date in ["2026-03-04", "2026-03-05"] {
            try store.saveDailySummary(DailySummaryRecord(localDate: date, timezone: "UTC", summary: "s", generatedAt: Date()))
        }
        let result = try store.deleteCaptures(ids: [c.id], calendar: cal)
        #expect(result.clearedDailySummaries == ["2026-03-04"])
        #expect(try store.dailySummary(localDate: "2026-03-04", timezone: "UTC") == nil)
        #expect(try store.dailySummary(localDate: "2026-03-05", timezone: "UTC") != nil)
    }

    @Test func nothingToDelete() throws {
        let store = try makeStore()
        #expect(try store.deleteCaptures(ids: []) == RecallStore.CaptureDeletion())
        #expect(try store.deleteCaptures(ids: [42]).deletedCaptures == 0)
    }
}
