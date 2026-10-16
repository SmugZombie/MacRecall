import CoreGraphics
import Foundation
import Testing
@testable import RecallCore

@Suite struct SessionBuilderTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func item(_ id: Int64, _ minutes: Double, _ app: String, _ title: String, _ text: String = "", project: Int64? = nil) -> SessionBuilder.Item {
        let start = t0.addingTimeInterval(minutes * 60)
        return SessionBuilder.Item(captureID: id, start: start, lastSeen: start, applicationName: app, windowTitle: title, text: text, projectID: project)
    }

    @Test func specExampleFormsOneSession() {
        // 10:00 VS Code API source, 10:05 Terminal docker compose, 10:09 browser PostgreSQL docs, 10:12 terminal db troubleshooting.
        let items = [
            item(1, 0, "Code", "api/server.ts — truesoc", "postgres client connection pool docker"),
            item(2, 3, "Code", "api/db.ts — truesoc", "postgres connection docker compose"),
            item(3, 5, "Terminal", "truesoc — docker compose up", "postgres docker compose truesoc connection refused"),
            item(4, 9, "Safari", "PostgreSQL: Documentation: connection settings", "postgres connection listen_addresses docker"),
            item(5, 12, "Terminal", "truesoc — psql", "psql connection postgres docker truesoc"),
        ]
        let groups = SessionBuilder().group(items)
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 5)
    }

    @Test func idleGapSplits() {
        let items = [item(1, 0, "Code", "a.swift"), item(2, 1, "Code", "a.swift"), item(3, 20, "Code", "a.swift")]
        #expect(SessionBuilder().group(items).map { $0.items.count } == [2, 1])
    }

    @Test func interruptionSplits() {
        let items = [item(1, 0, "Code", "a.swift"), item(2, 2, "Code", "a.swift")]
        let groups = SessionBuilder().group(items, interruptions: [t0.addingTimeInterval(60)])
        #expect(groups.count == 2)
    }

    @Test func briefGlanceStaysInSession() {
        let items = [
            item(1, 0, "Xcode", "MacRecall — SessionBuilder.swift", "session builder grouping"),
            item(2, 1, "Xcode", "MacRecall — SessionBuilder.swift", "session builder grouping"),
            item(3, 2, "Slack", "general — Acme", "lunch plans pizza"),
            item(4, 3, "Xcode", "MacRecall — SessionBuilder.swift", "session builder grouping"),
        ]
        let groups = SessionBuilder().group(items)
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 4)
    }

    @Test func sustainedTopicChangeSplits() {
        let items = [
            item(1, 0, "Xcode", "MacRecall — SessionBuilder.swift", "session builder grouping"),
            item(2, 1, "Xcode", "MacRecall — SessionBuilder.swift", "session builder grouping"),
            item(3, 2, "Numbers", "Q3 Budget.numbers", "revenue forecast expenses"),
            item(4, 3, "Numbers", "Q3 Budget.numbers", "revenue forecast expenses"),
        ]
        let groups = SessionBuilder().group(items)
        #expect(groups.map { $0.items.map(\.captureID) } == [[1, 2], [3, 4]])
    }

    @Test func differentProjectsNeverShare() {
        let items = [item(1, 0, "Code", "x", project: 1), item(2, 1, "Code", "x", project: 2)]
        #expect(SessionBuilder().group(items).count == 2)
    }

    @Test func continuesOpenSession() {
        let open = [item(1, 0, "Code", "server.ts truesoc")]
        let groups = SessionBuilder().group([item(2, 1, "Code", "server.ts truesoc")], openSessionID: 42, openItems: open)
        #expect(groups.count == 1)
        #expect(groups[0].existingSessionID == 42)
    }

    @Test func activeSecondsCountsObservedTimeOnly() {
        let a = t0
        // Two captures 30s apart, then a 20 minute gap, then one more.
        let intervals = [(a, a), (a.addingTimeInterval(30), a.addingTimeInterval(30)), (a.addingTimeInterval(1230), a.addingTimeInterval(1230))]
        let secs = SessionBuilder.activeSeconds(for: intervals.map { (start: $0.0, lastSeen: $0.1) }, credit: 30)
        #expect(secs == 90) // 0–30, 30–60, 1230–1260
    }

    @Test func deterministicTitle() {
        let items = [item(1, 0, "Code", "server.ts — truesoc"), item(2, 1, "Code", "server.ts — truesoc"), item(3, 2, "Terminal", "zsh")]
        #expect(SessionBuilder.deterministicTitle(for: items) == "Code, Terminal: server.ts — truesoc")
    }
}

@Suite struct ProjectClassifierTests {
    let projects = [
        ProjectRecord(id: 1, name: "TrueSOC", description: "", rules: ProjectRules(keywords: ["truesoc", "minio", "elasticmq"]), createdAt: Date()),
        ProjectRecord(id: 2, name: "MacRecall", description: "", rules: ProjectRules(repositoryPaths: ["~/Github/MacRecall"]), createdAt: Date()),
    ]

    @Test func matchesByTitle() {
        let s = ProjectClassifier.Signals(windowTitles: ["docker-compose.yml — truesoc"], text: "minio bucket", bundleIdentifiers: [])
        #expect(ProjectClassifier().classify(s, projects: projects)?.projectID == 1)
    }

    @Test func ambiguousIsUnclassified() {
        let s = ProjectClassifier.Signals(windowTitles: ["TrueSOC vs MacRecall"], text: "", bundleIdentifiers: [])
        #expect(ProjectClassifier().classify(s, projects: projects) == nil)
    }

    @Test func weakSignalIsUnclassified() {
        let s = ProjectClassifier.Signals(windowTitles: ["Inbox"], text: "minio", bundleIdentifiers: [])
        #expect(ProjectClassifier().classify(s, projects: projects) == nil)
    }

    @Test func wordBoundaries() {
        #expect(ProjectClassifier.containsWord("the truesoc repo", "truesoc"))
        #expect(!ProjectClassifier.containsWord("untruesocial", "truesoc"))
    }
}

@Suite struct CapturePolicyTests {
    let policy = CapturePolicy(excludedBundleIdentifiers: ["com.1password.1password"], ownBundleIdentifier: "me.recall", pauseOnBattery: true)

    @Test func capturesNormally() {
        #expect(policy.decide(CaptureContext(frontmostBundleIdentifier: "com.apple.Terminal")) == .capture)
    }

    @Test func skipReasons() {
        #expect(policy.decide(CaptureContext(frontmostBundleIdentifier: "com.1password.1password")) == .skip(.excludedApplication))
        #expect(policy.decide(CaptureContext(frontmostBundleIdentifier: "me.recall")) == .skip(.ownApplication))
        #expect(policy.decide(CaptureContext(screenLocked: true, frontmostBundleIdentifier: "x")) == .skip(.screenLocked))
        #expect(policy.decide(CaptureContext(systemAsleep: true, frontmostBundleIdentifier: "x")) == .skip(.asleep))
        #expect(policy.decide(CaptureContext(userIdle: true, frontmostBundleIdentifier: "x")) == .skip(.idle))
        #expect(policy.decide(CaptureContext(onBattery: true, frontmostBundleIdentifier: "x")) == .skip(.onBattery))
        #expect(policy.decide(CaptureContext(secureInputActive: true, frontmostBundleIdentifier: "x")) == .skip(.secureInput))
        #expect(policy.decide(CaptureContext(recordingEnabled: false, frontmostBundleIdentifier: "x")) == .skip(.recordingDisabled))
        #expect(policy.decide(CaptureContext(hasScreenCapturePermission: false, frontmostBundleIdentifier: "x")) == .skip(.noPermission))
        #expect(policy.decide(CaptureContext(frontmostBundleIdentifier: nil)) == .skip(.noFrontmostApplication))
    }

    @Test func pauseExpires() {
        let now = Date()
        #expect(policy.decide(CaptureContext(pausedUntil: now.addingTimeInterval(60), frontmostBundleIdentifier: "x", now: now)) == .skip(.paused))
        #expect(policy.decide(CaptureContext(pausedUntil: now.addingTimeInterval(-1), frontmostBundleIdentifier: "x", now: now)) == .capture)
    }
}

@Suite struct QueryInterpreterTests {
    // Wednesday 2026-10-14 15:00 local.
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15))! }
    func interpreter(_ apps: [String] = []) -> QueryInterpreter { QueryInterpreter(calendar: calendar, now: now, knownApplications: apps) }
    func day(_ d: Int, _ h: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }

    @Test func yesterday() {
        let i = interpreter().interpret("What did I work on yesterday?")
        #expect(i.range == DateInterval(start: day(13), end: day(14)))
        #expect(i.keywords.isEmpty)
    }

    @Test func beforeLunchYesterday() {
        let i = interpreter().interpret("What did I work on before lunch yesterday?")
        #expect(i.range == DateInterval(start: day(13, 0), end: day(13, 12)))
    }

    @Test func lastTuesday() {
        let i = interpreter().interpret("What was I working on last Tuesday?")
        #expect(i.range == DateInterval(start: day(13), end: day(14)))
    }

    @Test func sameWeekdayMeansPreviousWeek() {
        let i = interpreter().interpret("wednesday")
        #expect(i.range?.start == day(7))
    }

    @Test func appsAndKeywords() {
        let i = interpreter(["Terminal", "Safari"]).interpret("Find the terminal where I saw a PostgreSQL error.")
        #expect(i.applicationNames == ["Terminal"])
        #expect(i.keywords == ["postgresql", "error"])
        #expect(i.range == nil)
    }

    @Test func lastTimeWantsLatest() {
        let i = interpreter().interpret("Show the last time I used that AWS deployment command")
        #expect(i.wantsLatest)
        #expect(i.keywords.contains("aws"))
        #expect(i.keywords.contains("deployment"))
    }

    @Test func quotedPhrase() {
        let i = interpreter().interpret("when did I see \"connection refused\" today")
        #expect(i.quotedPhrases == ["connection refused"])
        #expect(i.range?.start == day(14))
    }
}

@Suite struct PrivacyTests {
    let rules = SensitiveContentRules()

    @Test func detectsSecrets() {
        #expect(rules.matches("export AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP"))
        #expect(rules.matches("-----BEGIN OPENSSH PRIVATE KEY-----"))
        #expect(rules.matches("password: hunter22"))
        #expect(rules.matches("postgres://admin:s3cret@db:5432/app"))
        #expect(rules.matches("card 4111 1111 1111 1111"))
        #expect(!rules.matches("order 1234 5678 9012 3456"))  // fails Luhn
        #expect(!rules.matches("git status"))
    }

    @Test func redactsSpans() {
        let out = rules.redact("key AKIAABCDEFGHIJKLMNOP end")
        #expect(out == "key [REDACTED] end")
    }

    @Test func loopbackDetection() {
        #expect(OllamaEndpoint.isLoopback("http://127.0.0.1:11434"))
        #expect(OllamaEndpoint.isLoopback("http://localhost:11434"))
        #expect(OllamaEndpoint.isLoopback("http://[::1]:11434"))
        #expect(!OllamaEndpoint.isLoopback("http://192.168.1.20:11434"))
        #expect(!OllamaEndpoint.isLoopback("http://127.0.0.1.evil.com"))
    }

    @Test func settingsDecodeToleratesMissingKeys() throws {
        let partial = #"{"captureInterval": 5, "retentionDays": 7}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RecallSettings.self, from: partial).validated()
        #expect(s.captureInterval == 10) // clamped
        #expect(s.retentionDays == 7)
        #expect(s.ollamaEndpoint == "http://127.0.0.1:11434")
    }
}

@Suite struct ImageTests {
    func image(lines: Int, width: Int = 800, height: Int = 600) -> CGImage {
        ImageProcessing.draw(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for i in 0..<lines { ctx.fill(CGRect(x: 20, y: height - 30 - i * 24, width: 300 + (i * 37) % 300, height: 12)) }
        }!
    }

    @Test func identicalIsDuplicate() throws {
        let a = try #require(ImageFingerprint(image: image(lines: 10)))
        let b = try #require(ImageFingerprint(image: image(lines: 10)))
        #expect(a.isDuplicate(of: b, sensitivity: 0.5))
    }

    @Test func newTerminalLinesAreNotDuplicate() throws {
        let a = try #require(ImageFingerprint(image: image(lines: 10)))
        let b = try #require(ImageFingerprint(image: image(lines: 13)))
        #expect(!a.isDuplicate(of: b, sensitivity: 0.5))
    }

    @Test func resizePreservesAspect() {
        let r = ImageProcessing.resize(image(lines: 1, width: 4000, height: 2000), maxWidth: 1000, maxHeight: 1000)
        #expect(r.width == 1000 && r.height == 500)
        let small = ImageProcessing.resize(image(lines: 1, width: 400, height: 200), maxWidth: 1000, maxHeight: 1000)
        #expect(small.width == 400)
    }
}

@Suite struct AIValidationTests {
    @Test func parsesFencedJSON() throws {
        let raw = """
        ```json
        {"activity":"Backend development","description":"Reviewing Docker networking","project":"null",
         "applications":["Terminal"],"topics":["Docker"],"confidence":1.7}
        ```
        """
        let a = try ActivityAnalysis.parse(raw)
        #expect(a.project == nil)
        #expect(a.confidence == 1)
    }

    @Test func rejectsInvalid() {
        #expect(throws: AIProviderError.self) { try ActivityAnalysis.parse("I think the user is coding") }
        #expect(throws: AIProviderError.self) { try ActivityAnalysis.parse(#"{"activity":"","description":"x","applications":[],"topics":[],"confidence":0.5}"#) }
    }

    @Test func groundedAnswerStripsFabricatedCitations() {
        let a = GroundedAnswerer.validate("You debugged Postgres [C5] and deployed [C99].", captureIDs: [5], sessionIDs: [])
        #expect(a.sufficientEvidence)
        #expect(a.citations == [.capture(5)])
        #expect(!a.text.contains("C99"))
    }

    @Test func uncitedAnswerIsInsufficient() {
        #expect(!GroundedAnswerer.validate("You were coding.", captureIDs: [1], sessionIDs: []).sufficientEvidence)
        #expect(!GroundedAnswerer.validate("INSUFFICIENT_EVIDENCE", captureIDs: [1], sessionIDs: []).sufficientEvidence)
    }
}

@Suite struct VectorTests {
    @Test func scanReturnsTopK() throws {
        let store = try makeStore()
        let t = Date()
        for i in 0..<50 {
            let angle = Float(i) / 50 * .pi / 2
            try store.saveEmbedding(entityType: "capture", entityID: Int64(i), model: "m", vector: [cos(angle), sin(angle)], entityTime: t)
        }
        let hits = try ScanVectorIndex(store: store).search(query: [1, 0], model: "m", entityTypes: ["capture"],
                                                            from: .distantPast, to: .distantFuture, limit: 3)
        #expect(hits.map(\.entityID) == [0, 1, 2])
        // Time filter excludes everything.
        #expect(try ScanVectorIndex(store: store).search(query: [1, 0], model: "m", entityTypes: ["capture"],
                                                         from: t.addingTimeInterval(10), to: .distantFuture, limit: 3).isEmpty)
    }
}

@Suite struct ProjectSuggesterTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func obs(day: Int, app: String = "Code", title: String = "", ai: String? = nil, text: String = "") -> ProjectSuggester.Observation {
        ProjectSuggester.Observation(capturedAt: t0.addingTimeInterval(Double(day) * 86400), applicationName: app,
                                     windowTitle: title, aiProject: ai, pathText: text)
    }

    @Test func extractsRepositories() {
        let repos = ProjectSuggester.repositories(in: "regli@mac ~/Github/MacRecall/Packages % cd /Users/regli/src/truesoc.git")
        #expect(repos.map(\.name) == ["MacRecall", "truesoc"])
        #expect(repos.map(\.path) == ["~/Github/MacRecall", "~/src/truesoc"])
        #expect(ProjectSuggester.repositories(in: "~/Documents/notes.txt /usr/local/src/x").isEmpty)
    }

    @Test func recurringNamesBecomeSuggestions() {
        var items: [ProjectSuggester.Observation] = []
        for day in 0..<3 {
            items.append(obs(day: day, ai: "MacRecall"))
            items.append(obs(day: day, ai: "Mac Recall"))
            items.append(obs(day: day, app: "Terminal", text: "~/Github/MacRecall % swift test"))
        }
        items.append(obs(day: 0, ai: "OneOff"))
        let suggestions = ProjectSuggester().suggest(items, existing: [])
        #expect(suggestions.count == 1)
        let s = suggestions[0]
        #expect(s.name == "MacRecall")
        #expect(s.aliases == ["Mac Recall"])
        #expect(s.repositoryPaths == ["~/Github/MacRecall"])
        #expect(s.captureCount == 9)
        #expect(s.dayCount == 3)
    }

    @Test func skipsKnownGenericAndDismissedNames() {
        var items: [ProjectSuggester.Observation] = []
        for day in 0..<3 {
            for name in ["truesoc", "Xcode", "Personal", "Hidden", "Fresh"] {
                items += Array(repeating: obs(day: day, app: "Xcode", ai: name), count: 2)
            }
            items.append(obs(day: day, text: "~/Github/old-repo"))
            items.append(obs(day: day, text: "~/Github/old-repo"))
        }
        let existing = [ProjectRecord(id: 1, name: "TrueSOC", description: "",
                                      rules: ProjectRules(repositoryPaths: ["~/Github/old-repo"]), createdAt: t0)]
        let names = ProjectSuggester().suggest(items, existing: existing, dismissed: ["hidden"]).map(\.name)
        #expect(names == ["Fresh"])
    }

    @Test func storeSuggestsOnlyUnassignedActivity() throws {
        let store = try makeStore()
        let json = #"{"activity":"Dev","description":"Editing","project":"Atlas","applications":[],"topics":[],"confidence":0.9}"#
        for day in 0..<3 {
            for i in 0..<2 {
                let c = try addCapture(store, app: "Code", bundle: "com.microsoft.VSCode", title: "main.go",
                                       at: Date().addingTimeInterval(-Double(day) * 86400 - Double(i) * 60))
                try store.updateAI(captureID: c.id, description: "Editing", json: json, status: .done)
            }
        }
        #expect(try store.projectSuggestions().map(\.name) == ["Atlas"])

        try store.dismissProjectSuggestion(try store.projectSuggestions()[0])
        #expect(try store.projectSuggestions().isEmpty)
    }
}

@Suite struct ClipboardTests {
    @Test func screenClippingIsBarePNG() {
        // What ⌃⇧⌘4 leaves on the clipboard (observed on macOS 26).
        #expect(ClipboardImageKind.classify(items: [["public.png", "com.apple.is-remote-clipboard"]]) == .screenClipping)
        #expect(ClipboardImageKind.classify(items: [["public.png"]]) == .screenClipping)
    }

    @Test func appCopiesAreCopiedImages() {
        // Preview: PNG plus TIFF and private types.
        #expect(ClipboardImageKind.classify(items: [["public.png", "Apple PNG pasteboard type", "PVPboardInfoPboardType",
                                                     "com.apple.is-remote-clipboard", "public.tiff"]]) == .copiedImage)
        #expect(ClipboardImageKind.classify(items: [["public.tiff", "public.html", "public.url"]]) == .copiedImage)
        #expect(ClipboardImageKind.classify(items: [["public.png"], ["public.png"]]) == .copiedImage)
        #expect(ClipboardImageKind.classify(items: [["public.png", "com.apple.is-remote-clipboard"]], remoteFlag: Data([1])) == .copiedImage)
    }

    @Test func ignoresNonImagesAndPrivateContent() {
        #expect(ClipboardImageKind.classify(items: [["public.utf8-plain-text", "public.html"]]) == nil)
        #expect(ClipboardImageKind.classify(items: [["public.file-url", "public.utf8-plain-text"]]) == nil)
        #expect(ClipboardImageKind.classify(items: [["public.png", "org.nspasteboard.ConcealedType"]]) == nil)
        #expect(ClipboardImageKind.classify(items: []) == nil)
    }

    @Test func settingsDefaultOffAndDecodeMissingKeys() throws {
        let decoded = try JSONDecoder().decode(RecallSettings.self, from: Data("{}".utf8))
        #expect(decoded.clipboardImageKinds.isEmpty)
        var s = RecallSettings()
        s.captureScreenClippings = true
        #expect(s.clipboardImageKinds == [.screenClipping])
    }
}
