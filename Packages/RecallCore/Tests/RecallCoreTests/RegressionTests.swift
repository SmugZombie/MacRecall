import CoreGraphics
import Foundation
import Testing
@testable import RecallCore

@Suite struct TransactionTests {
    @Test func mergeProjectsCommits() throws {
        let store = try makeStore()
        let c = try addCapture(store, at: Date())
        let sid = try store.createSession(start: Date(), end: Date(), title: "x", activeSeconds: 0, captureIDs: [c.id])
        let source = try store.createProject(name: "Old", rules: ProjectRules(keywords: ["legacy"]))
        let target = try store.createProject(name: "New", rules: ProjectRules(keywords: ["fresh"]))
        try store.setSessionProject(id: sid, projectID: source, source: "user")

        try store.mergeProjects(source: source, into: target)

        #expect(try store.project(id: source) == nil)
        #expect(try store.session(id: sid)?.projectID == target)
        let merged = try #require(try store.project(id: target))
        #expect(Set(merged.rules.keywords) == ["legacy", "fresh"])
        #expect(merged.rules.aliases.contains("Old"))
        #expect(try store.db.queryOne("SELECT 1 AS open")?.int("open") == 1)  // connection still usable
        #expect(try KeywordSearch(store: store).searchCaptures("new").count == 1)
    }

    @Test func nestedTransactionRollsBackOnlyInnerWork() throws {
        let store = try makeStore()
        struct Boom: Error {}
        try store.db.transaction {
            try store.setSetting("outer", "1")
            _ = try? store.db.transaction { () throws -> Void in
                try store.setSetting("inner", "1")
                throw Boom()
            }
            try store.setSetting("after", "1")
        }
        #expect(try store.setting("outer") == "1")
        #expect(try store.setting("inner") == nil)
        #expect(try store.setting("after") == "1")
    }

    @Test func outerFailureRollsBackCommittedInnerWork() throws {
        let store = try makeStore()
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try store.db.transaction { () throws -> Void in
                try store.db.transaction { try store.setSetting("inner", "1") }
                throw Boom()
            }
        }
        #expect(try store.setting("inner") == nil)
    }
}

@Suite struct QueueRobustnessTests {
    @Test func cancellationIsNotAnOutageOrAFailure() {
        #expect(AIJobQueue.disposition(for: CancellationError(), cancelled: false) == .requeue)
        // A request torn down because its task was cancelled surfaces as a transport error; the task flag wins.
        #expect(AIJobQueue.disposition(for: AIProviderError.unreachable("cancelled"), cancelled: true) == .requeue)
        #expect(AIJobQueue.disposition(for: AIProviderError.unreachable("connection refused"), cancelled: false) == .outage)
        #expect(AIJobQueue.disposition(for: AIProviderError.http(503, ""), cancelled: false) == .fail(retryable: true))
        #expect(AIJobQueue.disposition(for: AIProviderError.modelUnavailable("x"), cancelled: false) == .fail(retryable: false))
    }

    @Test func cancelledURLRequestsMapToCancellation() {
        #expect(AIHTTP.mapTransportError(URLError(.cancelled)) is CancellationError)
        #expect((AIHTTP.mapTransportError(URLError(.cannotConnectToHost)) as? AIProviderError)?.isOutage == true)
        #expect((AIHTTP.mapTransportError(URLError(.timedOut)) as? AIProviderError)?.isTransient == true)
    }

    @Test func orphanSweepSparesInFlightJobs() throws {
        let store = try makeStore()
        for id in 1...3 { try store.enqueueJob(.ocr, entityType: "capture", entityID: Int64(id)) }
        let claimed = try store.claimJobs(types: [.ocr], limit: 3)
        #expect(claimed.count == 3)
        let live = Set([claimed[0].id])
        #expect(try store.requeueOrphanedJobs(excluding: live) == 2)
        let counts = try store.queueCounts()
        #expect(counts.running == 1 && counts.pending == 2)
    }

    @Test func requeueAfterCancellationSpendsNoAttempt() throws {
        let store = try makeStore()
        try store.enqueueJob(.embedding, entityType: "capture", entityID: 1)
        let job = try #require(try store.claimJobs(types: [.embedding], limit: 1).first)
        try store.deferJob(id: job.id, until: Date())
        let again = try #require(try store.claimJobs(types: [.embedding], limit: 1).first)
        #expect(again.id == job.id && again.attempts == 0)
    }
}

@Suite struct RedactionGateTests {
    func image() -> CGImage {
        ImageProcessing.draw(width: 200, height: 100) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }!
    }

    @Test func failsClosedWhenOCRFails() async {
        struct VisionFailed: Error {}
        await #expect(throws: RedactionGate.Unavailable.self) {
            _ = try await RedactionGate.prepare(image(), rules: SensitiveContentRules()) { _ in throw VisionFailed() }
        }
    }

    @Test func redactsMatchingLines() async throws {
        let lines = [OCRLine(text: "export KEY=AKIAABCDEFGHIJKLMNOP", confidence: 1, boundingBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.2)),
                     OCRLine(text: "ls -la", confidence: 1, boundingBox: CGRect(x: 0, y: 0.1, width: 0.3, height: 0.2))]
        let prepared = try await RedactionGate.prepare(image(), rules: SensitiveContentRules()) { _ in OCRResult(lines: lines) }
        #expect(prepared.redacted)
        #expect(!prepared.ocrText.contains("AKIA"))
        #expect(prepared.ocrText.contains("ls -la"))
    }

    @Test func realVisionOnDegenerateImagesDoesNotCrash() async {
        // Tiny/blank images exercise Vision's failure and empty paths; the continuation must resume exactly once.
        let tiny = ImageProcessing.draw(width: 1, height: 1) { _ in }!
        for img in [tiny, image()] {
            let result = try? await VisionOCRService().recognize(img)
            #expect(result == nil || result!.lines.isEmpty)
        }
    }
}
