import Foundation

public enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case ollama, lmStudio, openAI, bedrock

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .openAI: return "OpenAI"
        case .bedrock: return "Amazon Bedrock"
        }
    }

    /// Cloud providers always send data off this Mac.
    public var isCloud: Bool { self == .openAI || self == .bedrock }
}

public enum ModelCapability: String, Sendable, Hashable, Codable {
    case completion, vision, embedding
}

public struct AIModel: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// Identifier passed to the API (model name, model ID or inference profile ID).
    public var name: String
    public var displayName: String?
    /// Empty when the provider doesn't report capabilities.
    public var capabilities: Set<ModelCapability>
    public var detail: String?

    public init(name: String, displayName: String? = nil, capabilities: Set<ModelCapability> = [], detail: String? = nil) {
        self.name = name
        self.displayName = displayName
        self.capabilities = capabilities
        self.detail = detail
    }

    public func supports(_ capability: ModelCapability) -> Bool? {
        capabilities.isEmpty ? nil : capabilities.contains(capability)
    }
}

public enum EmbeddingPurpose: Sendable { case document, query }

public struct ChatMessage: Sendable {
    public var role: String
    public var content: String
    /// JPEG image bytes attached to this message.
    public var images: [Data]

    public init(role: String, content: String, images: [Data]? = nil) {
        self.role = role
        self.content = content
        self.images = images ?? []
    }
}

/// A source of chat completions and embeddings. Implementations: Ollama, OpenAI-compatible
/// (OpenAI, LM Studio) and Amazon Bedrock. All network traffic for AI goes through one of these.
public protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    func listModels() async throws -> [AIModel]
    /// True when the server is reachable and accepts our credentials.
    func ping() async -> Bool
    /// Throws if `model` is unset or known not to exist. Providers that can't list reliably may only check it's set.
    func validate(model: String, role: String) async throws
    /// Non-streaming chat. With a `schema`, output is constrained to (or instructed to match) that JSON schema.
    func chat(model: String, messages: [ChatMessage], schema: [String: Any]?, temperature: Double) async throws -> String
    func embed(model: String, inputs: [String], purpose: EmbeddingPurpose) async throws -> [[Float]]
}

extension AIProvider {
    public func chat(model: String, messages: [ChatMessage]) async throws -> String {
        try await chat(model: model, messages: messages, schema: nil, temperature: 0.1)
    }

    public func chat(model: String, messages: [ChatMessage], schema: [String: Any]) async throws -> String {
        try await chat(model: model, messages: messages, schema: schema, temperature: 0.1)
    }

    public func chat(model: String, messages: [ChatMessage], temperature: Double) async throws -> String {
        try await chat(model: model, messages: messages, schema: nil, temperature: temperature)
    }

    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        try await embed(model: model, inputs: inputs, purpose: .document)
    }
}

public enum AIProviderError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case unreachable(String)
    case unauthorized(String)
    case missingCredentials(String)
    case modelNotConfigured(String)
    case modelUnavailable(String)
    case http(Int, String)
    case invalidResponse(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "The AI endpoint URL is invalid."
        case .unreachable(let m): return "The AI server is unreachable: \(m)"
        case .unauthorized(let m): return "The AI provider rejected the credentials: \(m)"
        case .missingCredentials(let m): return "Credentials are missing: \(m)"
        case .modelNotConfigured(let role): return "No \(role) model is selected."
        case .modelUnavailable(let m): return "Model “\(m)” is not available on this provider."
        case .http(let code, let m): return "The AI provider returned HTTP \(code): \(m)"
        case .invalidResponse(let m): return "Invalid response from model: \(m)"
        case .unsupported(let m): return m
        }
    }

    /// Whether retrying later could succeed without the user changing anything.
    public var isTransient: Bool {
        switch self {
        case .unreachable: return true
        case .http(let code, _): return code >= 500 || code == 429 || code == 408
        case .invalidResponse: return true
        default: return false
        }
    }

    /// The provider as a whole is unusable right now (down, or credentials rejected/missing).
    /// Jobs wait instead of spending retry attempts; fixing settings resumes them.
    public var isOutage: Bool {
        switch self {
        case .unreachable, .unauthorized, .missingCredentials, .invalidEndpoint: return true
        default: return false
        }
    }
}

/// Shared HTTP transport: ephemeral session, no cookies/cache, no system proxy.
struct AIHTTP: Sendable {
    let session: URLSession

    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        // Traffic must go directly to the configured server.
        if configuration == nil { config.connectionProxyDictionary = [:] }
        session = URLSession(configuration: config)
    }

    /// Performs the request and maps transport failures. Returns body and status for any HTTP response.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIProviderError.http(504, "request timed out")
        } catch {
            throw AIProviderError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse("not HTTP") }
        return (data, http)
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Extracts a human-readable error message from common JSON error shapes.
    static func errorMessage(_ data: Data) -> String {
        guard let obj = object(data) else { return String(data: data.prefix(200), encoding: .utf8) ?? "" }
        if let e = obj["error"] as? String { return e.clipped(300) }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m.clipped(300) }
        if let m = obj["message"] as? String { return m.clipped(300) }
        if let m = obj["Message"] as? String { return m.clipped(300) }
        return ""
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Pretty schema text for prompt-based fallbacks when a provider can't enforce a schema.
    var schemaDescription: String {
        (try? String(data: JSONSerialization.data(withJSONObject: self, options: [.sortedKeys]), encoding: .utf8)) ?? "{}"
    }
}

enum SchemaPrompt {
    static func instruction(_ schema: [String: Any]) -> String {
        "Respond with a single JSON object, and nothing else, that conforms to this JSON schema:\n\(schema.schemaDescription)"
    }
}
