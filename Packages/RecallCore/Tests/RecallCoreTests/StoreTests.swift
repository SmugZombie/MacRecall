import Foundation
import Testing
@testable import RecallCore

func makeStore() throws -> RecallStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-tests-\(UUID().uuidString)")
    return try RecallStore(inMemoryWithRoot: root)
}

@discardableResult
func addCapture(_ store: RecallStore, app: String = "Terminal", bundle: String = "com.apple.Terminal", title: String = "zsh",
                at date: Date, ocr: String? = nil, windowID: UInt32 = 1) throws -> CaptureRecord {
    try store.insertCapture(NewCapture(bundleIdentifier: bundle, applicationName: app, pid: 1, systemWindowID: windowID,
                                       windowTitle: title, capturedAt: date, imagePath: "screenshots/x-\(UUID()).heic",
                                       thumbnailPath: "thumbnails/x-\(UUID()).jpg", imageHash: "0", width: 100, height: 100,
                                       ocrText: ocr))
}

@Suite struct StoreTests {
    @Test func insertAndKeywordSearch() throws {
        let store = try makeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let c = try addCapture(store, at: t, ocr: "psql: error: connection to server at \"db\" failed")
        try addCapture(store, app: "Safari", bundle: "com.apple.Safari", title: "Docs", at: t.addingTimeInterval(60), ocr: "PostgreSQL manual")

        let search = KeywordSearch(store: store)
        let hits = try search.searchCaptures("connection failed")
        #expect(hits.map(\.entityID) == [c.id])
        #expect(hits[0].snippet.contains("«"))

        // App name and title are indexed too.
        #expect(try search.searchCaptures("safari").count == 1)
    }

    @Test func ocrUpdateReindexes() throws {
        let store = try makeStore()
        let c = try addCapture(store, at: Date())
        #expect(try KeywordSearch(store: store).searchCaptures("kubectl").isEmpty)
        try store.updateOCR(captureID: c.id, text: "kubectl get pods", confidence: 0.9, status: .done)
        #expect(try KeywordSearch(store: store).searchCaptures("kubectl").count == 1)
    }

    @Test func technicalStringsMatchAsPhrases() throws {
        let store = try makeStore()
        try addCapture(store, at: Date(), ocr: "Editing /Users/me/src/truesoc/docker-compose.yml")
        let search = KeywordSearch(store: store)
        #expect(try search.searchCaptures("docker-compose.yml").count == 1)
        #expect(try search.searchCaptures("truesoc/docker").count == 1)
        #expect(try search.searchCaptures("compose").count == 1)
    }

    @Test func ftsQueryNeutralizesOperators() throws {
        let store = try makeStore()
        try addCapture(store, at: Date(), ocr: "hello world")
        // Raw FTS syntax would throw; sanitized input must not.
        for evil in ["NEAR(hello", "hello AND OR", "\"unterminated", "col:hello", "*", "^hello", "hello) OR (world"] {
            _ = try KeywordSearch(store: store).searchCaptures(evil)
        }
        #expect(KeywordSearch.ftsQuery("   ", mode: .all) == nil)
    }

    @Test func deleteRangeRemovesRowsFilesAndIndex() throws {
        let store = try makeStore()
        let t = Date()
        let c = try addCapture(store, at: t, ocr: "secretproject")
        let file = store.paths.absolute(c.imagePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        try store.saveEmbedding(entityType: "capture", entityID: c.id, model: "m", vector: [1, 0], entityTime: t)

        let removed = try store.deleteCaptures(from: t.addingTimeInterval(-1), to: t.addingTimeInterval(1))
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try KeywordSearch(store: store).searchCaptures("secretproject").isEmpty)
        #expect(try store.embeddingCount(model: "m") == 0)
    }

    @Test func projectRenameUpdatesSearch() throws {
        let store = try makeStore()
        let c = try addCapture(store, at: Date())
        let pid = try store.createProject(name: "Apollo")
        try store.setCaptureProject(captureID: c.id, projectID: pid)
        #expect(try KeywordSearch(store: store).searchCaptures("apollo").count == 1)
        var p = try store.project(id: pid)!
        p.name = "Artemis"
        try store.updateProject(p)
        #expect(try KeywordSearch(store: store).searchCaptures("apollo").isEmpty)
        #expect(try KeywordSearch(store: store).searchCaptures("artemis").count == 1)
        try store.deleteProject(id: pid)
        #expect(try KeywordSearch(store: store).searchCaptures("artemis").isEmpty)
    }

    @Test func sessionSplitAndMerge() throws {
        let store = try makeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let caps = try (0..<4).map { try addCapture(store, at: t.addingTimeInterval(Double($0) * 60)) }
        let sid = try store.createSession(start: t, end: t.addingTimeInterval(180), title: "Work", activeSeconds: 200, captureIDs: caps.map(\.id))
        let newID = try #require(try store.splitSession(id: sid, at: t.addingTimeInterval(120)))
        #expect(try store.captures(inSession: sid).count == 2)
        #expect(try store.captures(inSession: newID).count == 2)
        // Original capture timestamps are preserved.
        #expect(try store.captures(inSession: newID).first?.capturedAt == t.addingTimeInterval(120))

        try store.mergeSessions(target: sid, others: [newID])
        #expect(try store.captures(inSession: sid).count == 4)
        #expect(try store.session(id: newID) == nil)
        #expect(try store.session(id: sid)?.userLocked == true)
    }

    @Test func userProjectCorrectionIsNotOverridden() throws {
        let store = try makeStore()
        let c = try addCapture(store, at: Date())
        let sid = try store.createSession(start: Date(), end: Date(), title: "x", activeSeconds: 0, captureIDs: [c.id])
        let a = try store.createProject(name: "A")
        let b = try store.createProject(name: "B")
        try store.setSessionProject(id: sid, projectID: a, source: "user")
        try store.setSessionProject(id: sid, projectID: b, source: "auto")
        #expect(try store.session(id: sid)?.projectID == a)
        try store.applyAISessionResult(id: sid, title: "AI title", summary: "s", confidence: 0.5)
        #expect(try store.session(id: sid)?.title == "x")
    }

    @Test func migrationsAreIdempotent() throws {
        let store = try makeStore()
        try Migrations.migrate(store.db)
        #expect(try store.db.scalarInt("SELECT MAX(version) FROM schema_migrations") == Int64(Migrations.all.count))
        #expect(try store.db.integrityCheck())
    }
}

@Suite struct JobQueueTests {
    @Test func enqueueDeduplicatesAndRaisesPriority() throws {
        let store = try makeStore()
        try store.enqueueJob(.ocr, entityType: "capture", entityID: 1, priority: 1)
        try store.enqueueJob(.ocr, entityType: "capture", entityID: 1, priority: 9)
        #expect(try store.queueCounts().pending == 1)
        let job = try #require(try store.claimJobs(types: [.ocr], limit: 5).first)
        #expect(job.priority == 9)
        // While running, a re-enqueue is still a duplicate.
        try store.enqueueJob(.ocr, entityType: "capture", entityID: 1)
        #expect(try store.queueCounts().pending == 0)
        try store.completeJob(id: job.id)
        // Once done, the same work may be queued again (e.g. user asks to reprocess).
        try store.enqueueJob(.ocr, entityType: "capture", entityID: 1)
        #expect(try store.queueCounts().pending == 1)
    }

    @Test func claimOrdersByPriorityThenRecency() throws {
        let store = try makeStore()
        let t = Date().addingTimeInterval(-100)
        try store.enqueueJob(.ocr, entityType: "capture", entityID: 1, priority: 0, at: t)
        try store.enqueueJob(.ocr, entityType: "capture", entityID: 2, priority: 0, at: t.addingTimeInterval(10))
        try store.enqueueJob(.ocr, entityType: "capture", entityID: 3, priority: 5, at: t)
        let ids = try store.claimJobs(types: [.ocr], limit: 3).map(\.entityID)
        #expect(ids == [3, 2, 1])
    }

    @Test func claimRespectsTypes() throws {
        let store = try makeStore()
        try store.enqueueJob(.visionAnalysis, entityType: "capture", entityID: 1)
        #expect(try store.claimJobs(types: [.ocr], limit: 5).isEmpty)
        #expect(try store.claimJobs(types: [], limit: 5).isEmpty)
    }

    @Test func failureBacksOffThenGivesUp() throws {
        let store = try makeStore()
        let now = Date()
        try store.enqueueJob(.embedding, entityType: "capture", entityID: 1, at: now)
        var job = try #require(try store.claimJobs(types: [.embedding], limit: 1, now: now).first)
        #expect(try store.failJob(id: job.id, error: "boom", retryable: true, maxAttempts: 3, now: now) == .pending)
        // Not ready until backoff elapses.
        #expect(try store.claimJobs(types: [.embedding], limit: 1, now: now.addingTimeInterval(1)).isEmpty)
        job = try #require(try store.claimJobs(types: [.embedding], limit: 1, now: now.addingTimeInterval(31)).first)
        #expect(try store.failJob(id: job.id, error: "boom", retryable: true, maxAttempts: 3, now: now) == .pending)
        job = try #require(try store.claimJobs(types: [.embedding], limit: 1, now: now.addingTimeInterval(1000)).first)
        #expect(try store.failJob(id: job.id, error: "boom", retryable: true, maxAttempts: 3, now: now) == .failed)
        #expect(try store.queueCounts().failed == 1)
    }

    @Test func nonRetryableFailsImmediately() throws {
        let store = try makeStore()
        try store.enqueueJob(.embedding, entityType: "capture", entityID: 1)
        let job = try #require(try store.claimJobs(types: [.embedding], limit: 1).first)
        #expect(try store.failJob(id: job.id, error: "model missing", retryable: false) == .failed)
    }

    @Test func interruptedJobsRecover() throws {
        let store = try makeStore()
        try store.enqueueJob(.ocr, entityType: "capture", entityID: 1)
        _ = try store.claimJobs(types: [.ocr], limit: 1)
        #expect(try store.queueCounts().running == 1)
        #expect(try store.recoverInterruptedJobs() == 1)
        #expect(try store.queueCounts().pending == 1)
    }

    @Test func backoffIsBounded() {
        #expect(RecallStore.backoff(attempt: 1, base: 30, cap: 3600) == 30)
        #expect(RecallStore.backoff(attempt: 3, base: 30, cap: 3600) == 120)
        #expect(RecallStore.backoff(attempt: 20, base: 30, cap: 3600) == 3600)
    }
}
