import Foundation

/// One tool an MCP client can call. Handlers return plain text for the agent to read.
public struct MCPTool: @unchecked Sendable {
    public var name: String
    public var title: String
    public var description: String
    /// JSON Schema for the arguments object.
    public var inputSchema: [String: Any]
    public var handler: @Sendable ([String: Any]) async throws -> String

    public init(name: String, title: String, description: String, inputSchema: [String: Any],
                handler: @escaping @Sendable ([String: Any]) async throws -> String) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// A tool failure the agent should see and can correct (bad arguments, nothing found, access turned off).
public struct MCPToolError: Error, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A minimal Model Context Protocol server: JSON-RPC 2.0, one message per line on stdin/stdout,
/// tools only. https://modelcontextprotocol.io/specification
public final class MCPServer: @unchecked Sendable {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let name: String
    let version: String
    let instructions: String
    let tools: [MCPTool]
    /// Checked before every tool call, so turning access off in the app takes effect immediately.
    let authorize: @Sendable () -> String?
    /// Called with the client's name after a successful tool call.
    let onToolCall: @Sendable (String?) -> Void
    private var clientName: String?

    public init(name: String, version: String, instructions: String, tools: [MCPTool],
                authorize: @escaping @Sendable () -> String? = { nil },
                onToolCall: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.authorize = authorize
        self.onToolCall = onToolCall
    }

    /// Serves requests until stdin closes. Requests are handled one at a time, in order.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        do {
            for try await line in input.bytes.lines {
                guard let response = await handle(Data(line.utf8)) else { continue }
                output.write(response + Data("\n".utf8))
            }
        } catch {
            // stdin failed; the client has gone.
        }
    }

    /// Handles one message. Returns nil for notifications and responses, which get no reply.
    public func handle(_ data: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try await dispatch(method, params)
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RPCError {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]])
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    private func dispatch(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            clientName = (params["clientInfo"] as? [String: Any])?["name"] as? String
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "title": tool.title,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                    "annotations": ["title": tool.title, "readOnlyHint": true, "openWorldHint": false],
                ]
            }]
        case "tools/call":
            guard let toolName = params["name"] as? String, let tool = tools.first(where: { $0.name == toolName }) else {
                throw RPCError(code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "")")
            }
            if let denied = authorize() { return Self.toolResult(denied, isError: true) }
            do {
                let text = try await tool.handler(params["arguments"] as? [String: Any] ?? [:])
                onToolCall(clientName)
                return Self.toolResult(text, isError: false)
            } catch {
                return Self.toolResult(error.localizedDescription, isError: true)
            }
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }
}
