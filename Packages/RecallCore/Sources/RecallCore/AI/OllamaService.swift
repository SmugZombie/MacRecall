import Foundation

public struct OllamaModel: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { name }
    public var name: String
    public var size: Int64?
    public var family: String?
    public var parameterSize: String?

    enum CodingKeys: String, CodingKey { case name, size, details }
    enum DetailKeys: String, CodingKey { case family, parameter_size }

    public init(name: String, size: Int64? = nil, family: String? = nil, parameterSize: String? = nil) {
        self.name = name
        self.size = size
        self.family = family
        self.parameterSize = parameterSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        let d = try? c.nestedContainer(keyedBy: DetailKeys.self, forKey: .details)
        family = try d?.decodeIfPresent(String.self, forKey: .family)
        parameterSize = try d?.decodeIfPresent(String.self, forKey: .parameter_size)
    }
}

public enum OllamaError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case unreachable(String)
    case modelNotConfigured(String)
    case modelUnavailable(String)
    case http(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "The Ollama endpoint URL is invalid."
        case .unreachable(let m): return "Ollama is unreachable: \(m)"
        case .modelNotConfigured(let role): return "No \(role) model is selected."
        case .modelUnavailable(let m): return "Model “\(m)” is not installed on the Ollama server."
        case .http(let code, let m): return "Ollama returned HTTP \(code): \(m)"
        case .invalidResponse(let m): return "Invalid response from model: \(m)"
        }
    }

    /// Whether retrying later could succeed without the user changing anything.
    public var isTransient: Bool {
        switch self {
        case .unreachable: return true
        case .http(let code, _): return code >= 500 || code == 429
        case .invalidResponse: return true
        default: return false
        }
    }

    /// Whether the server itself is down (jobs should wait, not burn attempts).
    public var isOutage: Bool { if case .unreachable = self { return true }; return false }
}

public struct ChatMessage: Sendable, Encodable {
    public var role: String
    public var content: String
    public var images: [String]?

    public init(role: String, content: String, images: [Data]? = nil) {
        self.role = role
        self.content = content
        self.images = images?.map { $0.base64EncodedString() }
    }
}

/// The only component that talks to the network, and only to the configured Ollama endpoint.
public actor OllamaService {
    private var baseURL: URL?
    private var timeout: TimeInterval
    private let session: URLSession
    private var capabilityCache: [String: [String]] = [:]

    public init(endpoint: String, timeout: TimeInterval = 120) {
        self.baseURL = URL(string: endpoint)
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        // Never route through a system proxy: traffic must go directly to the configured server.
        config.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: config)
    }

    public func configure(endpoint: String, timeout: TimeInterval) {
        let newURL = URL(string: endpoint)
        if newURL != baseURL { capabilityCache = [:] }
        baseURL = newURL
        self.timeout = timeout
    }

    public var endpointDescription: String { baseURL?.absoluteString ?? "(invalid)" }

    // MARK: API

    public func listModels() async throws -> [OllamaModel] {
        struct Tags: Decodable { var models: [OllamaModel] }
        let data = try await request("api/tags", method: "GET", body: Optional<String>.none, timeout: 10)
        return try JSONDecoder().decode(Tags.self, from: data).models.sorted { $0.name < $1.name }
    }

    /// Capabilities reported by `/api/show` (e.g. "completion", "vision", "embedding"). Empty if unknown.
    public func capabilities(of model: String) async throws -> [String] {
        if let cached = capabilityCache[model] { return cached }
        struct Show: Decodable { var capabilities: [String]? }
        let data = try await request("api/show", method: "POST", body: ["model": model], timeout: 15)
        let caps = (try? JSONDecoder().decode(Show.self, from: data).capabilities) ?? []
        capabilityCache[model] = caps
        return caps
    }

    public func ping() async -> Bool {
        (try? await request("api/tags", method: "GET", body: Optional<String>.none, timeout: 3)) != nil
    }

    /// Ensures `model` is installed. Never pulls models automatically.
    public func validate(model: String, role: String) async throws {
        guard !model.isEmpty else { throw OllamaError.modelNotConfigured(role) }
        let names = try await listModels().map(\.name)
        let normalized = model.contains(":") ? model : model + ":latest"
        guard names.contains(model) || names.contains(normalized) else { throw OllamaError.modelUnavailable(model) }
    }

    /// Non-streaming chat. When `schema` is given, Ollama constrains output to that JSON schema.
    public func chat(model: String, messages: [ChatMessage], schema: [String: Any]? = nil, temperature: Double = 0.1) async throws -> String {
        guard !model.isEmpty else { throw OllamaError.modelNotConfigured("chat") }
        var body: [String: Any] = [
            "model": model,
            "messages": try messages.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
            "stream": false,
            "options": ["temperature": temperature],
            "keep_alive": "5m",
        ]
        if let schema { body["format"] = schema }
        let data = try await request("api/chat", method: "POST", jsonObject: body, timeout: timeout)
        struct Response: Decodable { struct Message: Decodable { var content: String }; var message: Message }
        do {
            return try JSONDecoder().decode(Response.self, from: data).message.content
        } catch {
            throw OllamaError.invalidResponse("missing message content")
        }
    }

    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        guard !model.isEmpty else { throw OllamaError.modelNotConfigured("embedding") }
        let data = try await request("api/embed", method: "POST", jsonObject: ["model": model, "input": inputs, "truncate": true], timeout: timeout)
        struct Response: Decodable { var embeddings: [[Float]] }
        guard let vectors = try? JSONDecoder().decode(Response.self, from: data).embeddings, vectors.count == inputs.count else {
            throw OllamaError.invalidResponse("embedding count mismatch")
        }
        return vectors
    }

    // MARK: Transport

    private func request<B: Encodable>(_ path: String, method: String, body: B?, timeout: TimeInterval) async throws -> Data {
        let json = try body.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return try await request(path, method: method, jsonObject: json, timeout: timeout)
    }

    private func request(_ path: String, method: String, jsonObject: Any?, timeout: TimeInterval) async throws -> Data {
        guard let baseURL, let scheme = baseURL.scheme, ["http", "https"].contains(scheme) else { throw OllamaError.invalidEndpoint }
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        if let jsonObject {
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .timedOut {
            throw OllamaError.http(504, "request timed out")
        } catch {
            throw OllamaError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            if http.statusCode == 404, message.contains("not found") { throw OllamaError.modelUnavailable(message) }
            throw OllamaError.http(http.statusCode, String(message.prefix(200)))
        }
        return data
    }
}
