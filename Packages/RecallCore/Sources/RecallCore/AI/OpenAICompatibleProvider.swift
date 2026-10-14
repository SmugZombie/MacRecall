import Foundation

/// OpenAI Chat Completions–compatible servers: OpenAI itself and LM Studio's local server.
/// Uses `/models`, `/chat/completions` and `/embeddings` under a base URL ending in `/v1`.
public final class OpenAICompatibleProvider: AIProvider, @unchecked Sendable {
    public let kind: AIProviderKind
    private let baseURL: URL?
    private let apiKey: String?
    private let timeout: TimeInterval
    private let http: AIHTTP
    private let lock = NSLock()
    private var cachedModels: (Date, [AIModel])?
    /// Request features a model rejected, so we stop sending them (e.g. temperature on reasoning models).
    private var rejected: [String: Set<String>] = [:]

    public static let defaultOpenAIEndpoint = "https://api.openai.com/v1"
    public static let defaultLMStudioEndpoint = "http://127.0.0.1:1234/v1"

    public init(kind: AIProviderKind, endpoint: String, apiKey: String?, timeout: TimeInterval = 120,
                configuration: URLSessionConfiguration? = nil) {
        self.kind = kind
        self.baseURL = URL(string: endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint)
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.timeout = timeout
        self.http = AIHTTP(configuration: configuration)
    }

    // MARK: Models

    public func listModels() async throws -> [AIModel] {
        if let (date, models) = lock.withLock({ cachedModels }), Date().timeIntervalSince(date) < 300 { return models }
        if kind == .openAI && apiKey == nil { throw AIProviderError.missingCredentials("OpenAI API key") }
        var models: [AIModel]
        if kind == .lmStudio, let typed = try? await lmStudioModels() {
            models = typed
        } else {
            let data = try await send("models", body: nil, timeout: 15)
            let ids = ((AIHTTP.object(data)?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            models = ids.compactMap(Self.classify).sorted { $0.name < $1.name }
        }
        lock.withLock { cachedModels = (Date(), models) }
        return models
    }

    /// LM Studio's REST API reports model types (llm / vlm / embeddings).
    private func lmStudioModels() async throws -> [AIModel] {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw AIProviderError.invalidEndpoint }
        components.path = "/api/v0/models"
        guard let url = components.url else { throw AIProviderError.invalidEndpoint }
        var req = URLRequest(url: url, timeoutInterval: 10)
        authorize(&req)
        let (data, response) = try await http.send(req)
        guard response.statusCode == 200, let items = AIHTTP.object(data)?["data"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse("no LM Studio model list")
        }
        return items.compactMap { item -> AIModel? in
            guard let id = item["id"] as? String else { return nil }
            let caps: Set<ModelCapability>
            switch item["type"] as? String {
            case "embeddings": caps = [.embedding]
            case "vlm": caps = [.completion, .vision]
            case "llm": caps = [.completion]
            default: caps = []
            }
            let state = (item["state"] as? String).map { $0 == "loaded" ? "loaded" : "not loaded" }
            return AIModel(name: id, capabilities: caps, detail: state)
        }.sorted { $0.name < $1.name }
    }

    /// OpenAI's `/models` has no capability metadata; infer from well-known naming and drop non-chat models.
    static func classify(_ id: String) -> AIModel? {
        let l = id.lowercased()
        if l.contains("embed") { return AIModel(name: id, capabilities: [.embedding]) }
        let excluded = ["whisper", "tts", "dall-e", "davinci", "babbage", "moderation", "realtime", "audio", "transcribe", "image", "search", "computer-use", "sora"]
        if excluded.contains(where: { l.contains($0) }) { return nil }
        let visionFamilies = ["gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-5", "o1", "o3", "o4", "chatgpt-4o", "vision", "llava", "vl"]
        if visionFamilies.contains(where: { l.hasPrefix($0) || l.contains($0) }) { return AIModel(name: id, capabilities: [.completion, .vision]) }
        return AIModel(name: id, capabilities: [.completion])
    }

    public func ping() async -> Bool {
        if kind == .openAI && apiKey == nil { return false }
        return (try? await send("models", body: nil, timeout: 5)) != nil
    }

    public func validate(model: String, role: String) async throws {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured(role) }
        // Only reject when we could list models and the model clearly isn't there.
        if let models = try? await listModels(), !models.isEmpty, !models.contains(where: { $0.name == model }) {
            throw AIProviderError.modelUnavailable(model)
        }
    }

    // MARK: Chat

    func chatBody(model: String, messages: [ChatMessage], schema: [String: Any]?, temperature: Double, omit: Set<String>) -> [String: Any] {
        var msgs = messages.map { m -> [String: Any] in
            guard !m.images.isEmpty else { return ["role": m.role, "content": m.content] }
            var parts: [[String: Any]] = [["type": "text", "text": m.content]]
            for image in m.images {
                parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]])
            }
            return ["role": m.role, "content": parts]
        }
        var body: [String: Any] = ["model": model, "stream": false]
        if !omit.contains("temperature") { body["temperature"] = temperature }
        // OpenAI's newer models require max_completion_tokens; LM Studio understands max_tokens.
        body[kind == .openAI ? "max_completion_tokens" : "max_tokens"] = 1500
        if let schema {
            if omit.contains("response_format") {
                // Fall back to instructing the schema in the system prompt.
                if let i = msgs.firstIndex(where: { ($0["role"] as? String) == "system" }), let text = msgs[i]["content"] as? String {
                    msgs[i]["content"] = text + "\n" + SchemaPrompt.instruction(schema)
                } else {
                    msgs.insert(["role": "system", "content": SchemaPrompt.instruction(schema)], at: 0)
                }
            } else {
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": "result", "schema": schema, "strict": false]]
            }
        }
        body["messages"] = msgs
        return body
    }

    public func chat(model: String, messages: [ChatMessage], schema: [String: Any]?, temperature: Double) async throws -> String {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured("chat") }
        var omit = lock.withLock { rejected[model] ?? [] }
        // Up to two downgrades: some models reject a custom temperature or JSON-schema response formats.
        for _ in 0..<3 {
            do {
                let data = try await send("chat/completions", body: chatBody(model: model, messages: messages, schema: schema,
                                                                             temperature: temperature, omit: omit), timeout: timeout)
                guard let choices = AIHTTP.object(data)?["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any] else {
                    throw AIProviderError.invalidResponse("missing choices")
                }
                if let text = message["content"] as? String { return text }
                if let refusal = message["refusal"] as? String { throw AIProviderError.invalidResponse("model refused: \(refusal.clipped(120))") }
                throw AIProviderError.invalidResponse("empty message")
            } catch AIProviderError.http(400, let message) {
                let lower = message.lowercased()
                if lower.contains("temperature"), !omit.contains("temperature") {
                    omit.insert("temperature")
                } else if (lower.contains("response_format") || lower.contains("json_schema") || lower.contains("json schema")), !omit.contains("response_format") {
                    omit.insert("response_format")
                } else {
                    throw AIProviderError.http(400, message)
                }
                let learned = omit
                lock.withLock { rejected[model] = learned }
            }
        }
        throw AIProviderError.invalidResponse("request rejected")
    }

    // MARK: Embeddings

    public func embed(model: String, inputs: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured("embedding") }
        let data = try await send("embeddings", body: ["model": model, "input": inputs], timeout: timeout)
        guard let items = AIHTTP.object(data)?["data"] as? [[String: Any]], items.count == inputs.count else {
            throw AIProviderError.invalidResponse("embedding count mismatch")
        }
        let sorted = items.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return try sorted.map { item in
            guard let values = item["embedding"] as? [NSNumber] else { throw AIProviderError.invalidResponse("missing embedding") }
            return values.map(\.floatValue)
        }
    }

    // MARK: Transport

    private func authorize(_ req: inout URLRequest) {
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }

    private func send(_ path: String, body: Any?, timeout: TimeInterval) async throws -> Data {
        guard let baseURL, let scheme = baseURL.scheme, ["http", "https"].contains(scheme) else { throw AIProviderError.invalidEndpoint }
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = body == nil ? "GET" : "POST"
        authorize(&req)
        if let body {
            req.httpBody = try AIHTTP.json(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, http) = try await self.http.send(req)
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw AIProviderError.unauthorized(AIHTTP.errorMessage(data))
        case 404:
            let message = AIHTTP.errorMessage(data)
            if message.lowercased().contains("model") { throw AIProviderError.modelUnavailable(message) }
            throw AIProviderError.http(404, message)
        default: throw AIProviderError.http(http.statusCode, AIHTTP.errorMessage(data))
        }
    }
}
