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

@Suite struct SummarySchedulingTests {
    func pendingSummaries(_ store: RecallStore) throws -> Int {
        Int(try store.db.scalarInt("SELECT COUNT(*) FROM ai_jobs WHERE job_type = 'session_summary' AND status = 'pending'"))
    }

    func failRound(_ store: RecallStore, at date: Date) throws {
        let job = try #require(try store.claimJobs(types: [.sessionSummary], limit: 1, now: date).first)
        try store.failJob(id: job.id, error: "model unavailable", retryable: false, now: date)
    }

    @Test func failedSummariesAreRescheduledAfterCooldownAndBounded() throws {
        let store = try makeStore()
        let t0 = Date().addingTimeInterval(-3 * 86400)
        let c = try addCapture(store, at: t0)
        _ = try store.createSession(start: t0, end: t0.addingTimeInterval(60), title: "x", activeSeconds: 60, captureIDs: [c.id])
        let manager = ActivitySessionManager(store: store)

        // Jobs are enqueued at the real current time, so simulated time starts now and moves forward.
        var now = Date().addingTimeInterval(1)
        try manager.scheduleSummaries(now: now)
        #expect(try pendingSummaries(store) == 1)
        try manager.scheduleSummaries(now: now)
        #expect(try pendingSummaries(store) == 1)  // no duplicates while one is pending

        for round in 1...3 {
            try failRound(store, at: now)
            try manager.scheduleSummaries(now: now.addingTimeInterval(60))
            #expect(try pendingSummaries(store) == 0)  // cooling down
            now = now.addingTimeInterval(2 * 3600)
            try manager.scheduleSummaries(now: now)
            #expect(try pendingSummaries(store) == (round < 3 ? 1 : 0))  // retried, until the round limit
        }
    }

    @Test func summarizedSessionsAreNotRescheduled() throws {
        let store = try makeStore()
        let t0 = Date().addingTimeInterval(-86400)
        let c = try addCapture(store, at: t0)
        let sid = try store.createSession(start: t0, end: t0, title: "x", activeSeconds: 0, captureIDs: [c.id])
        try store.applyAISessionResult(id: sid, title: "Done", summary: "Something happened.", confidence: 0.9)
        try ActivitySessionManager(store: store).scheduleSummaries(now: Date())
        #expect(try pendingSummaries(store) == 0)
    }
}

@Suite struct WindowMatchingTests {
    typealias R = ActiveWindowResolver
    func ax(_ title: String?, _ frame: CGRect?, minimized: Bool = false) -> R.FocusState {
        .focused(R.AXWindowInfo(title: title, frame: frame, minimized: minimized))
    }
    let frame = CGRect(x: 100, y: 80, width: 1200, height: 800)

    @Test func toleratesSmallFrameDifferences() {
        let c = [R.WindowCandidate(id: 1, title: "a", frame: frame.offsetBy(dx: 0.5, dy: 4).insetBy(dx: 0, dy: -2), zIndex: 0)]
        #expect(R.match(focus: ax("a", frame), accessibilityAvailable: true, candidates: c) == .window(1, method: "ax_frame"))
    }

    @Test func prefersClosestFrame() {
        let c = [R.WindowCandidate(id: 1, title: "x", frame: frame.offsetBy(dx: 15, dy: 0), zIndex: 0),
                 R.WindowCandidate(id: 2, title: "x", frame: frame, zIndex: 1)]
        #expect(R.match(focus: ax("x", frame), accessibilityAvailable: true, candidates: c) == .window(2, method: "ax_frame"))
    }

    @Test func sameTitleAndFrameUsesZOrder() {
        // Two browser windows stacked exactly, both titled "New Tab": the focused one is frontmost.
        let c = [R.WindowCandidate(id: 7, title: "New Tab", frame: frame, zIndex: 3),
                 R.WindowCandidate(id: 9, title: "New Tab", frame: frame, zIndex: 1)]
        #expect(R.match(focus: ax("New Tab", frame), accessibilityAvailable: true, candidates: c) == .window(9, method: "ax_frame_z"))
    }

    @Test func titleOnlyMatchUsesZOrderForDuplicates() {
        let c = [R.WindowCandidate(id: 1, title: "main.swift", frame: .zero, zIndex: 2),
                 R.WindowCandidate(id: 2, title: "main.swift", frame: CGRect(x: 0, y: 0, width: 50, height: 50), zIndex: 0)]
        #expect(R.match(focus: ax("main.swift", nil), accessibilityAvailable: true, candidates: c) == .window(2, method: "ax_title_z"))
    }

    @Test func frameMatchPrefersTitleAmongEqualFits() {
        let c = [R.WindowCandidate(id: 1, title: "Inbox", frame: frame, zIndex: 0),
                 R.WindowCandidate(id: 2, title: "Draft", frame: frame, zIndex: 1)]
        // The title narrows equal fits to one window, so z-order isn't needed.
        #expect(R.match(focus: ax("Draft", frame), accessibilityAvailable: true, candidates: c) == .window(2, method: "ax_frame"))
    }

    @Test func unmatchedFocusIsSkippedNotGuessed() {
        let c = [R.WindowCandidate(id: 1, title: "Other", frame: frame.offsetBy(dx: 400, dy: 0), zIndex: 0)]
        #expect(R.match(focus: ax("Secret", frame), accessibilityAvailable: true, candidates: c)
            == .skip(.windowNotShareable, detail: "focused window not matched to a capturable window"))
        #expect(R.match(focus: ax("a", frame, minimized: true), accessibilityAvailable: true, candidates: c)
            == .skip(.noFocusedWindow, detail: "focused window minimized"))
    }

    @Test func withoutAccessibilityUsesFrontmost() {
        let c = [R.WindowCandidate(id: 1, title: nil, frame: frame, zIndex: 4),
                 R.WindowCandidate(id: 2, title: nil, frame: frame, zIndex: 0),
                 R.WindowCandidate(id: 3, title: nil, frame: frame, zIndex: nil)]
        #expect(R.match(focus: .unknown, accessibilityAvailable: false, candidates: c) == .window(2, method: "z_order"))
        #expect(R.match(focus: .noFocusedWindow, accessibilityAvailable: true, candidates: c)
            == .skip(.noFocusedWindow, detail: "no AX focused window"))
    }
}

@Suite struct SessionStateTests {
    @Test func lockDetectionFailsSafe() {
        #expect(SystemStateMonitor.isLocked(sessionInfo: nil))
        #expect(SystemStateMonitor.isLocked(sessionInfo: ["CGSSessionScreenIsLocked": true, kCGSessionOnConsoleKey as String: true]))
        #expect(SystemStateMonitor.isLocked(sessionInfo: [kCGSessionOnConsoleKey as String: false]))
        #expect(!SystemStateMonitor.isLocked(sessionInfo: [kCGSessionOnConsoleKey as String: true]))
    }

    @Test func liveStateReadsWithoutCrashing() {
        // Under the test runner there may be no GUI session; whatever it reports must be well-formed.
        _ = SystemStateMonitor.liveState()
    }
}
