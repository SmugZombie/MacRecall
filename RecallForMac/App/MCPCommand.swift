import Foundation
import RecallCore

/// Starts the app, or with `--mcp` serves the history to an AI agent over stdin/stdout instead.
@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.dropFirst().contains(MCPCommand.flag) {
            MCPCommand.run()
        } else {
            RecallApp.main()
        }
    }
}

/// `RecallForMac --mcp`: a read-only MCP server started by an MCP client such as Claude Code or Claude Desktop.
/// It runs alongside the app (or without it) and never starts the UI, captures, or touches the network.
enum MCPCommand {
    static let flag = "--mcp"
    static let lastAccessKey = "MCPLastAccess"

    static func run() -> Never {
        let store: RecallStore
        do {
            store = try RecallStore(readOnlyPaths: .default)
        } catch {
            // stdout belongs to the protocol; diagnostics go to stderr, which MCP clients log.
            FileHandle.standardError.write(Data("Recall MCP: \(error)\n".utf8))
            exit(1)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let server = RecallMCP(store: store, settings: { RecallSettings.load() })
            .server(version: version, onToolCall: recordAccess)
        Task {
            await server.run()
            exit(0)
        }
        dispatchMain()
    }

    /// Lets Settings show which agent last read the history, and when.
    @Sendable static func recordAccess(client: String?) {
        UserDefaults.standard.set(["date": Date(), "client": client ?? "An MCP client"], forKey: lastAccessKey)
    }

    static func lastAccess() -> (date: Date, client: String)? {
        guard let entry = UserDefaults.standard.dictionary(forKey: lastAccessKey),
              let date = entry["date"] as? Date, let client = entry["client"] as? String else { return nil }
        return (date, client)
    }
}
