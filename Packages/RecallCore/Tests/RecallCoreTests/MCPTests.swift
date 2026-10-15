import Foundation
import Testing
@testable import RecallCore

@Suite struct MCPTests {
    /// 2026-10-14 10:00 in a fixed zone, so formatting and day boundaries are deterministic.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Phoenix")!
        return c
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!

    func makeMCP(_ store: RecallStore, enabled: Bool = true) -> RecallMCP {
        var settings = RecallSettings()
        settings.mcpEnabled = enabled
        let fixed = settings
        return RecallMCP(store: store, settings: { fixed }, calendar: Self.calendar, now: { Self.now })
    }

    func call(_ server: MCPServer, _ message: [String: Any]) async throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let reply = await server.handle(data) else { return nil }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    func callTool(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
        let reply = try await call(server, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let result = try #require(reply?["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    // MARK: Protocol

    @Test func handshakeAndToolList() async throws {
        let server = makeMCP(try makeStore()).server(version: "1.2.0")
        let initialize = try await call(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                 "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2"]]])
        let result = try #require(initialize?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as? [String: Any])?["version"] as? String == "1.2.0")
        #expect((result["instructions"] as? String)?.contains("America/Phoenix") == true)
        // Agents once concluded Recall keeps no screenshots; the instructions must say it does, and that they stay local.
        let instructions = try #require(result["instructions"] as? String)
        #expect(instructions.contains("takes a screenshot"))
        #expect(instructions.contains("Don't say Recall has no screenshots"))

        // Notifications get no reply.
        #expect(try await call(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)

        let list = try await call(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try #require((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["search_history", "get_capture", "get_session", "list_sessions",
                                                                    "usage_report", "daily_summary", "list_projects"])
        for tool in tools {
            #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
            #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        }
    }

    @Test func unknownVersionGetsLatestAndErrorsAreJSONRPC() async throws {
        let server = makeMCP(try makeStore()).server(version: "1")
        let initialize = try await call(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect((initialize?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.supportedVersions[0])

        let unknown = try await call(server, ["jsonrpc": "2.0", "id": "a", "method": "resources/list"])
        #expect((unknown?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(unknown?["id"] as? String == "a")

        let badTool = try await call(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "drop_tables"]])
        #expect((badTool?["error"] as? [String: Any])?["code"] as? Int == -32602)

        let garbage = await server.handle(Data("{not json".utf8))
        let parsed = try JSONSerialization.jsonObject(with: try #require(garbage)) as? [String: Any]
        #expect((parsed?["error"] as? [String: Any])?["code"] as? Int == -32700)

        let ping = try await call(server, ["jsonrpc": "2.0", "id": 4, "method": "ping"])
        #expect(ping?["result"] != nil)
    }

    @Test func toolsRefuseWhileAccessIsOff() async throws {
        let store = try makeStore()
        try addCapture(store, at: Self.now, ocr: "secret plans")
        let server = makeMCP(store, enabled: false).server(version: "1")
        let result = try await callTool(server, "search_history", ["query": "secret"])
        #expect(result.isError)
        #expect(result.text == RecallMCP.accessOffMessage)
        #expect(!result.text.contains("plans"))
    }

    @Test func reportsTheCallingClient() async throws {
        let calls = LockedBox<[String?]>([])
        let server = makeMCP(try makeStore()).server(version: "1") { client in calls.mutate { $0.append(client) } }
        _ = try await call(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "Claude Desktop"]]])
        _ = try await callTool(server, "list_projects")
        #expect(calls.value == ["Claude Desktop"])
    }

    // MARK: Tools

    @Test func searchFindsCapturesAndRespectsFilters() async throws {
        let store = try makeStore()
        let yesterday = Self.now.addingTimeInterval(-86400)
        let match = try addCapture(store, at: yesterday, ocr: "panic: runtime error: index out of range")
        try addCapture(store, app: "Safari", bundle: "com.apple.Safari", title: "Go docs", at: Self.now.addingTimeInterval(-600), ocr: "runtime package docs")
        let server = makeMCP(store).server(version: "1")

        let all = try await callTool(server, "search_history", ["query": "runtime"])
        #expect(!all.isError)
        #expect(all.text.contains("C\(match.id)"))
        #expect(all.text.contains("Safari"))
        #expect(all.text.contains("**"))

        let terminalOnly = try await callTool(server, "search_history", ["query": "runtime", "app": "terminal"])
        #expect(terminalOnly.text.contains("C\(match.id)"))
        #expect(!terminalOnly.text.contains("Go docs"))

        let today = try await callTool(server, "search_history", ["query": "runtime", "from": "2026-10-14"])
        #expect(!today.text.contains("C\(match.id) "))
        #expect(today.text.contains("Go docs"))

        let browse = try await callTool(server, "search_history", ["query": "", "when": "yesterday"])
        #expect(browse.text.contains("C\(match.id)"))

        let badApp = try await callTool(server, "search_history", ["query": "x", "app": "Photoshop"])
        #expect(badApp.isError)
        #expect(badApp.text.contains("Safari"))

        let badDate = try await callTool(server, "search_history", ["query": "x", "from": "next blue moon"])
        #expect(badDate.isError)
    }

    @Test func captureDetailIncludesFullTextAndContext() async throws {
        let store = try makeStore()
        let c = try addCapture(store, title: "deploy.sh", at: Self.now, ocr: String(repeating: "line of output\n", count: 50) + "DONE")
        try store.updateAI(captureID: c.id, description: "Running a deploy script.", json: nil, status: .done)
        let server = makeMCP(store).server(version: "1")

        let full = try await callTool(server, "get_capture", ["id": "C\(c.id)"])
        #expect(full.text.contains("Window: deploy.sh"))
        #expect(full.text.contains("Running a deploy script."))
        #expect(full.text.contains("DONE"))
        #expect(full.text.contains("Wed 2026-10-14 10:00"))
        #expect(full.text.contains("Screenshot: 100×100, stored encrypted in Recall"))

        let clipped = try await callTool(server, "get_capture", ["id": c.id, "max_chars": 200])
        #expect(!clipped.text.contains("DONE"))
        #expect(clipped.text.contains("more characters"))

        let missing = try await callTool(server, "get_capture", ["id": 999_999])
        #expect(missing.isError)
    }

    @Test func sessionsAndUsage() async throws {
        let store = try makeStore()
        let start = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 8))!
        var ids: [Int64] = []
        for i in 0..<10 { ids.append(try addCapture(store, app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Recall", at: start.addingTimeInterval(Double(i) * 30)).id) }
        for i in 10..<14 { ids.append(try addCapture(store, app: "Slack", bundle: "com.tinyspeck.slackmacgap", title: "general", at: start.addingTimeInterval(Double(i) * 30)).id) }
        let project = try store.createProject(name: "Recall")
        let session = try store.createSession(start: start, end: start.addingTimeInterval(420), title: "Building Recall",
                                              activeSeconds: 420, captureIDs: ids)
        try store.setSessionProject(id: session, projectID: project, source: "user")
        let server = makeMCP(store).server(version: "1")

        let sessions = try await callTool(server, "list_sessions", [:])
        #expect(sessions.text.contains("S\(session)"))
        #expect(sessions.text.contains("Building Recall"))
        #expect(sessions.text.contains("project: Recall"))

        let detail = try await callTool(server, "get_session", ["id": "S\(session)", "max_captures": 3])
        #expect(detail.text.contains("Captures (14)"))
        #expect(detail.text.contains("C\(ids.first!)"))
        #expect(detail.text.contains("C\(ids.last!)"))

        let byApp = try await callTool(server, "usage_report", ["when": "today"])
        #expect(byApp.text.contains("Total: 7m"))
        #expect(byApp.text.contains("- Xcode: 5m"))
        #expect(byApp.text.contains("- Slack: 2m"))
        #expect(byApp.text.range(of: "Xcode")!.lowerBound < byApp.text.range(of: "Slack")!.lowerBound)

        let byProject = try await callTool(server, "usage_report", ["group_by": "project"])
        #expect(byProject.text.contains("- Recall: 7m (100%)"))

        let slackOnly = try await callTool(server, "usage_report", ["app": "slack", "group_by": "window"])
        #expect(slackOnly.text.contains("Slack — general"))
        #expect(!slackOnly.text.contains("Xcode"))

        let projects = try await callTool(server, "list_projects")
        #expect(projects.text.contains("Recall: 7m active"))

        let summary = try await callTool(server, "daily_summary", ["date": "2026-10-14"])
        #expect(summary.text.contains("Building Recall"))

        let empty = try await callTool(server, "list_sessions", ["from": "2026-10-01", "to": "2026-10-02"])
        #expect(empty.text.contains("No sessions"))
        #expect(empty.text.contains("from Thu 2026-10-01 to Fri 2026-10-02"))
    }

    @Test func dateArguments() throws {
        let mcp = makeMCP(try makeStore())
        let day = try #require(try mcp.range(["from": "2026-10-13", "to": "2026-10-13"], default: nil))
        #expect(day.duration == 86400)
        #expect(mcp.describe(day) == "on Tue 2026-10-13")
        let span = try #require(try mcp.range(["from": "2026-10-13T09:30", "to": "2026-10-13T11:00"], default: nil))
        #expect(span.duration == 5400)
        #expect(try mcp.range(["when": "yesterday"], default: nil)?.start == Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 13)))
        #expect(throws: MCPToolError.self) { try mcp.range(["from": "2026-10-14", "to": "2026-10-13T00:00"], default: nil) }
        #expect(try mcp.range([:], default: nil) == nil)
    }

    @Test func readOnlyStoreSeesTheAppsWritesAndCantWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        #expect(throws: SQLiteError.self) { try RecallStore(readOnlyPaths: paths, keyStore: InMemoryScreenshotKeyStore()) }

        let app = try RecallStore(paths: paths, keyStore: InMemoryScreenshotKeyStore())
        let reader = try RecallStore(readOnlyPaths: paths, keyStore: InMemoryScreenshotKeyStore())
        let c = try addCapture(app, at: Date(), ocr: "written by the app")
        #expect(try reader.capture(id: c.id)?.ocrText == "written by the app")
        #expect(throws: SQLiteError.self) { try reader.setSetting("x", "y") }
    }

    @Test func settingDefaultsOffAndSurvivesOlderBlobs() throws {
        #expect(RecallSettings().mcpEnabled == false)
        let old = try JSONDecoder().decode(RecallSettings.self, from: Data(#"{"retentionDays": 9}"#.utf8))
        #expect(old.mcpEnabled == false)
        var on = RecallSettings()
        on.mcpEnabled = true
        #expect(try JSONDecoder().decode(RecallSettings.self, from: JSONEncoder().encode(on)).mcpEnabled)
    }

    @Test func samplingKeepsEnds() {
        #expect(RecallMCP.sample(Array(0..<100), 5) == [0, 25, 50, 74, 99])
        #expect(RecallMCP.sample([1, 2], 5) == [1, 2])
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
