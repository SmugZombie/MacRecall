import AppKit
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

@Suite struct RedactionPrecisionTests {
    let rules = SensitiveContentRules()

    @Test func cardRuleNeedsIssuerShape() {
        #expect(rules.matches("Visa 4111 1111 1111 1111"))
        #expect(rules.matches("amex 378282246310005"))
        // Luhn-valid but no card issuer has this prefix/length: an order or account number.
        #expect(SensitiveContentRules.luhnValid("1234567812345670".compactMap(\.wholeNumberValue)))
        #expect(!rules.matches("Order 1234567812345670 shipped"))
        // Part of a longer digit run is not a card.
        #expect(!rules.matches("trace id 9994111111111111111111"))
        #expect(!rules.matches("2026-10-14 15:53:12 build 1234567"))
    }

    func blank(_ w: Int = 400, _ h: Int = 100) -> CGImage {
        ImageProcessing.draw(width: w, height: h) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }!
    }

    @Test func withoutAVisionBoxTheWholeLineIsBlackedOut() async throws {
        // Estimating from character counts can miss the secret in a proportional font, so don't.
        let line = "Card: 4111 1111 1111 1111 exp 12/27"
        let box = CGRect(x: 0.05, y: 0.4, width: 0.9, height: 0.1)
        let ocr = OCRResult(lines: [OCRLine(text: line, confidence: 1, boundingBox: box)])
        let prepared = try await RedactionGate.prepare(blank(), rules: rules) { _ in ocr }
        #expect(prepared.redacted)
        #expect(prepared.ocrText == "Card: [REDACTED] exp 12/27")
        #expect(OCRLine(text: line, confidence: 1, boundingBox: box).box(for: line.range(of: "4111")!) == box)
        let grid = ImageFingerprint.grayscale(prepared.image, width: 400, height: 100)!
        #expect(grid[55 * 400 + 25] < 50 && grid[55 * 400 + 375] < 50)  // both ends of the line are covered
    }

    @Test func failsClosedWhenRedactionCannotBePainted() async {
        let ocr = OCRResult(lines: [OCRLine(text: "AKIAABCDEFGHIJKLMNOP", confidence: 1, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))])
        await #expect(throws: RedactionGate.Unavailable.self) {
            _ = try await RedactionGate.prepare(blank(), rules: rules, paint: { _, _ in nil }) { _ in ocr }
        }
        // Nothing sensitive means nothing to paint, so painting can't fail the capture.
        let clean = OCRResult(lines: [OCRLine(text: "ls -la", confidence: 1, boundingBox: .zero)])
        let prepared = try? await RedactionGate.prepare(blank(), rules: rules, paint: { _, _ in nil }) { _ in clean }
        #expect(prepared?.redacted == false)
    }

    @Test func implausibleVisionBoxFallsBackToTheLine() {
        let line = OCRLine(text: "abc secret", confidence: 1, boundingBox: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.1)) { _ in
            CGRect(x: 0.9, y: 0.0, width: 0.05, height: 0.05)  // nowhere near the line
        }
        #expect(line.box(for: line.text.range(of: "secret")!) == line.boundingBox)
    }

    /// End to end with real Vision on proportional text: exercises `VNRecognizedText.boundingBox(for:)`
    /// through the locator, which must neither trap nor miss the secret.
    @Test func realVisionRedactsTheSecretInProportionalText() async throws {
        let secret = "AKIAIOSFODNN7EXAMPLE"
        let prefix = "Deploy with WWWWWWWW key "
        let font = NSFont.systemFont(ofSize: 34)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let width = 1600, height = 140
        let origin = CGPoint(x: 40, y: 50)
        let image = ImageProcessing.draw(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: prefix + secret + " now", attributes: attrs).draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }!
        let prepared = try await RedactionGate.prepare(image, rules: rules) { try await VisionOCRService().recognize($0) }
        #expect(prepared.redacted)
        #expect(!prepared.ocrText.contains(secret))

        // Every column the secret was drawn in must be covered at the text's vertical middle.
        let secretStart = origin.x + NSAttributedString(string: prefix, attributes: attrs).size().width
        let secretEnd = secretStart + NSAttributedString(string: secret, attributes: attrs).size().width
        let midY = Int(origin.y + font.capHeight / 2)
        let grid = ImageFingerprint.grayscale(prepared.image, width: width, height: height)!
        let row = height - 1 - midY  // the grayscale buffer's first row is the image's top
        for x in stride(from: Int(secretStart) + 2, to: Int(secretEnd) - 2, by: 6) {
            #expect(grid[row * width + x] < 40, "secret column \(x) not covered")
        }
    }

    @Test func realVisionLocatorReturnsANarrowBoxForTheSubstring() throws {
        let text = "Deploy with key AKIAIOSFODNN7EXAMPLE now"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black]
        let image = ImageProcessing.draw(width: 1400, height: 120) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1400, height: 120))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: text, attributes: attrs).draw(at: CGPoint(x: 30, y: 40))
            NSGraphicsContext.restoreGraphicsState()
        }!
        let line = try #require(try VisionOCRService.perform(image, languages: ["en-US"]).lines.first { $0.text.contains("AKIA") })
        let range = try #require(line.text.range(of: "AKIAIOSFODNN7EXAMPLE"))
        let exact = try #require(line.locate?(range))
        #expect(exact.intersects(line.boundingBox))
        #expect(exact.width < line.boundingBox.width * 0.75)  // a span, not the whole line
        #expect(line.box(for: range) == exact)
        // Ranges from a different String instance are rebuilt safely, never trapping.
        let other = String(line.text.reversed().reversed())
        _ = line.locate?(other.range(of: "AKIA")!)
    }

    @Test func visionLocatorIsPreferred() {
        let line = OCRLine(text: "abc secret", confidence: 1, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1)) { _ in
            CGRect(x: 0.5, y: 0, width: 0.2, height: 1)
        }
        #expect(line.box(for: line.text.range(of: "secret")!) == CGRect(x: 0.5, y: 0, width: 0.2, height: 1))
    }
}

@Suite struct ProvenanceTests {
    @Test func aiRespectsUserFieldsIndependently() throws {
        let store = try makeStore()
        let c = try addCapture(store, at: Date())
        let sid = try store.createSession(start: Date(), end: Date(), title: "auto", activeSeconds: 0, captureIDs: [c.id])

        try store.renameSession(id: sid, title: "My title")
        try store.applyAISessionResult(id: sid, title: "AI title", summary: "AI summary", confidence: 0.7)
        var s = try #require(try store.session(id: sid))
        #expect(s.title == "My title" && s.summary == "AI summary" && s.summarySource == "ai")
        #expect(!s.userLocked)  // renaming doesn't freeze grouping

        try store.setSessionSummary(id: sid, summary: "My notes")
        try store.applyAISessionResult(id: sid, title: "AI 2", summary: "AI summary 2", confidence: 0.7)
        s = try #require(try store.session(id: sid))
        #expect(s.summary == "My notes" && s.summarySource == "user")

        try store.clearAIMetadata()
        #expect(try store.session(id: sid)?.summary == "My notes")

        try store.setSessionSummary(id: sid, summary: "  ")  // hand back to AI
        try store.applyAISessionResult(id: sid, title: "AI 3", summary: "AI summary 3", confidence: 0.7)
        #expect(try store.session(id: sid)?.summary == "AI summary 3")
    }

    @Test func projectAssignmentDoesNotStampCaptures() throws {
        let store = try makeStore()
        let a = try store.createProject(name: "Alpha")
        let b = try store.createProject(name: "Beta")
        let c1 = try addCapture(store, at: Date(), ocr: "kubernetes rollout")
        let c2 = try addCapture(store, at: Date().addingTimeInterval(30), ocr: "kubernetes logs")
        try store.setCaptureProject(captureID: c1.id, projectID: b)  // classifier's own signal
        let sid = try store.createSession(start: Date(), end: Date(), title: "x", activeSeconds: 0, captureIDs: [c1.id, c2.id])

        try store.setSessionProject(id: sid, projectID: a, source: "user")
        #expect(try store.capture(id: c1.id)?.projectID == b)
        #expect(try store.capture(id: c2.id)?.projectID == nil)
        // Scoped search still finds the session's captures through the session's project.
        let hits = try KeywordSearch(store: store).searchCaptures("kubernetes", scope: SearchScope(projectID: a))
        #expect(Set(hits.map(\.entityID)) == [c1.id, c2.id])
    }
}

@Suite struct RegroupingTests {
    let t0 = Date().addingTimeInterval(-3 * 3600)

    func overlaps(_ store: RecallStore) throws -> Int {
        Int(try store.db.scalarInt("""
            SELECT COUNT(*) FROM sessions a JOIN sessions b ON a.id < b.id
            WHERE a.started_at < b.ended_at AND b.started_at < a.ended_at
            """))
    }

    @Test func holeInLongSessionRejoinsIt() throws {
        let store = try makeStore()
        let caps = try (0..<20).map { try addCapture(store, title: "server.ts — truesoc", at: t0.addingTimeInterval(Double($0) * 60), ocr: "truesoc server") }
        try ActivitySessionManager(store: store).update(now: t0.addingTimeInterval(3600))
        let sid = try #require(try store.capture(id: caps[0].id)?.sessionID)
        #expect(try store.sessions(from: .distantPast, to: .distantFuture).count == 1)

        // Punch a hole in the middle (as a partial regroup would) and update again.
        try store.db.run("UPDATE captures SET activity_session_id = NULL WHERE id = ?", [caps[10].id])
        try ActivitySessionManager(store: store).update(now: t0.addingTimeInterval(3600))
        #expect(try store.capture(id: caps[10].id)?.sessionID == sid)
        #expect(try store.sessions(from: .distantPast, to: .distantFuture).count == 1)
    }

    @Test func rebuildAroundCuratedSessionCreatesNoOverlaps() throws {
        let store = try makeStore()
        // Work, a curated block in the middle, more work; all within the idle gap of each other.
        let before = try (0..<5).map { try addCapture(store, title: "notes", at: t0.addingTimeInterval(Double($0) * 60), ocr: "notes alpha") }
        let middle = try (5..<8).map { try addCapture(store, title: "notes", at: t0.addingTimeInterval(Double($0) * 60), ocr: "notes alpha") }
        let after = try (8..<12).map { try addCapture(store, title: "notes", at: t0.addingTimeInterval(Double($0) * 60), ocr: "notes alpha") }
        let manager = ActivitySessionManager(store: store)
        try manager.update(now: t0.addingTimeInterval(3600))
        let original = try #require(try store.capture(id: middle[0].id)?.sessionID)
        _ = try store.splitSession(id: original, at: middle[0].capturedAt)            // curated: locks both halves
        if let tail = try store.capture(id: after[0].id)?.sessionID, tail != original {
            _ = try store.splitSession(id: tail, at: after[0].capturedAt)
        }
        try store.db.run("UPDATE sessions SET user_locked = 0 WHERE id IN (SELECT activity_session_id FROM captures WHERE id IN (?, ?))",
                         [before[0].id, after[0].id])

        try manager.rebuild(from: t0, to: t0.addingTimeInterval(3600), now: t0.addingTimeInterval(3600))
        #expect(try overlaps(store) == 0)
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM captures WHERE activity_session_id IS NULL") == 0)
        // The curated middle block is untouched.
        let middleSessions = Set(try middle.map { try store.capture(id: $0.id)?.sessionID })
        #expect(middleSessions.count == 1)
    }
}

@Suite struct StorageLayoutTests {
    @Test func legacyLayoutMovesIntoNoIndexFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("screenshots/2026/10/14"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("screenshots/2026/10/14/a.heic"))
        do {  // a 1.0.0-era database at the old location
            let db = try SQLiteDatabase(path: root.appendingPathComponent("recall.sqlite").path)
            try Migrations.migrate(db)
            try db.run("INSERT INTO settings (key, value) VALUES ('marker', 'kept')")
        }
        let store = try RecallStore(paths: StoragePaths(root: root))
        #expect(store.paths.database.path.contains("Data.noindex"))
        #expect(try store.setting("marker") == "kept")
        #expect(FileManager.default.fileExists(atPath: store.paths.absolute("screenshots/2026/10/14/a.heic").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("recall.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: store.paths.data.appendingPathComponent(".metadata_never_index").path))
    }
}

@Suite struct RedirectTests {
    @Test func redirectPolicy() {
        let u = { (s: String) in URL(string: s) }
        #expect(RedirectGuard.allows(from: u("http://127.0.0.1:1234/v1/models"), to: u("http://127.0.0.1:1234/v1/models/")))
        #expect(RedirectGuard.allows(from: u("http://gpu.local/v1"), to: u("https://gpu.local/v1")))
        #expect(!RedirectGuard.allows(from: u("https://api.example.com/v1"), to: u("https://evil.example.net/v1")))
        #expect(!RedirectGuard.allows(from: u("https://api.example.com/v1"), to: u("http://api.example.com/v1")))
        #expect(!RedirectGuard.allows(from: u("http://127.0.0.1:1234/v1"), to: u("http://127.0.0.1:9999/v1")))
    }
}

@Suite struct ClearedSummaryTests {
    @Test func clearingASummaryQueuesANewOne() throws {
        let store = try makeStore()
        let t0 = Date().addingTimeInterval(-86400)
        let c = try addCapture(store, at: t0)
        let sid = try store.createSession(start: t0, end: t0, title: "x", activeSeconds: 0, captureIDs: [c.id])

        // The AI summary ran and completed.
        try store.enqueueJob(.sessionSummary, entityType: "session", entityID: sid)
        let job = try #require(try store.claimJobs(types: [.sessionSummary], limit: 1).first)
        try store.applyAISessionResult(id: sid, title: "AI", summary: "AI summary", confidence: 0.8)
        try store.completeJob(id: job.id)

        // The user writes their own, then clears it.
        try store.setSessionSummary(id: sid, summary: "mine")
        #expect(try store.queueCounts().byType[.sessionSummary] == nil)
        try store.setSessionSummary(id: sid, summary: "")

        // The scheduler alone would skip it (a done job exists); clearing must have queued one.
        try ActivitySessionManager(store: store).scheduleSummaries(now: Date())
        #expect(try store.queueCounts().byType[.sessionSummary] == 1)
        let next = try #require(try store.claimJobs(types: [.sessionSummary], limit: 1).first)
        #expect(next.entityID == sid && next.id != job.id)
    }
}
