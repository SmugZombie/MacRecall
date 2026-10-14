import Foundation

/// Ollama's native API: `/api/tags`, `/api/show`, `/api/chat`, `/api/embed`.
public final class OllamaProvider: AIProvider, @unchecked Sendable {
    public let kind: AIProviderKind = .ollama
    private let baseURL: URL?
    private let timeout: TimeInterval
    private let http: AIHTTP
    private let lock = NSLock()
    private var capabilityCache: [String: Set<ModelCapability>] = [:]

    public init(endpoint: String, timeout: TimeInterval = 120, configuration: URLSessionConfiguration? = nil) {
        self.baseURL = URL(string: endpoint)
        self.timeout = timeout
        self.http = AIHTTP(configuration: configuration)
    }

    public func listModels() async throws -> [AIModel] {
        struct Tags: Decodable {
            struct Model: Decodable {
                struct Details: Decodable { var family: String?; var parameter_size: String? }
                var name: String
                var details: Details?
            }
            var models: [Model]
        }
        let data = try await request("api/tags", body: nil, timeout: 10)
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        var result: [AIModel] = []
        for m in tags.models.sorted(by: { $0.name < $1.name }) {
            let caps = (try? await capabilities(of: m.name)) ?? []
            result.append(AIModel(name: m.name, capabilities: caps, detail: m.details?.parameter_size))
        }
        return result
    }

    /// Capabilities from `/api/show` (newer Ollama versions). Empty if unknown.
    func capabilities(of model: String) async throws -> Set<ModelCapability> {
        if let cached = lock.withLock({ capabilityCache[model] }) { return cached }
        struct Show: Decodable { var capabilities: [String]? }
        let data = try await request("api/show", body: ["model": model], timeout: 15)
        let raw = (try? JSONDecoder().decode(Show.self, from: data).capabilities) ?? nil
        let caps = Set((raw ?? []).compactMap(ModelCapability.init(rawValue:)))
        lock.withLock { capabilityCache[model] = caps }
        return caps
    }

    public func ping() async -> Bool {
        (try? await request("api/tags", body: nil, timeout: 3)) != nil
    }

    /// Ensures `model` is installed. Never pulls models automatically.
    public func validate(model: String, role: String) async throws {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured(role) }
        struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }
        let names = try JSONDecoder().decode(Tags.self, from: try await request("api/tags", body: nil, timeout: 10)).models.map(\.name)
        let normalized = model.contains(":") ? model : model + ":latest"
        guard names.contains(model) || names.contains(normalized) else { throw AIProviderError.modelUnavailable(model) }
    }

    public func chat(model: String, messages: [ChatMessage], schema: [String: Any]?, temperature: Double) async throws -> String {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured("chat") }
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { m -> [String: Any] in
                var dict: [String: Any] = ["role": m.role, "content": m.content]
                if !m.images.isEmpty { dict["images"] = m.images.map { $0.base64EncodedString() } }
                return dict
            },
            "stream": false,
            "options": ["temperature": temperature],
            "keep_alive": "5m",
        ]
        if let schema { body["format"] = schema }
        let data = try await request("api/chat", body: body, timeout: timeout)
        guard let message = AIHTTP.object(data)?["message"] as? [String: Any], let content = message["content"] as? String else {
            throw AIProviderError.invalidResponse("missing message content")
        }
        return content
    }

    public func embed(model: String, inputs: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured("embedding") }
        let data = try await request("api/embed", body: ["model": model, "input": inputs, "truncate": true], timeout: timeout)
        struct Response: Decodable { var embeddings: [[Float]] }
        guard let vectors = try? JSONDecoder().decode(Response.self, from: data).embeddings, vectors.count == inputs.count else {
            throw AIProviderError.invalidResponse("embedding count mismatch")
        }
        return vectors
    }

    private func request(_ path: String, body: Any?, timeout: TimeInterval) async throws -> Data {
        guard let baseURL, let scheme = baseURL.scheme, ["http", "https"].contains(scheme) else { throw AIProviderError.invalidEndpoint }
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            req.httpBody = try AIHTTP.json(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, http) = try await self.http.send(req)
        guard (200..<300).contains(http.statusCode) else {
            let message = AIHTTP.errorMessage(data)
            if http.statusCode == 404, message.contains("not found") { throw AIProviderError.modelUnavailable(message) }
            throw AIProviderError.http(http.statusCode, message)
        }
        return data
    }
}
