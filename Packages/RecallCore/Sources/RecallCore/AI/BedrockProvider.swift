import Foundation

public enum BedrockAuth: Sendable {
    /// Amazon Bedrock API key, sent as a bearer token.
    case apiKey(String)
    /// IAM access keys, signed with SigV4.
    case accessKeys(AWSCredentials)
    /// A named profile from ~/.aws (static keys, or resolved through the AWS CLI).
    case profile(String)
}

/// Amazon Bedrock via the Converse API (chat), InvokeModel (embeddings) and the control plane (model discovery).
public final class BedrockProvider: AIProvider, @unchecked Sendable {
    public let kind: AIProviderKind = .bedrock
    public let region: String
    private let auth: BedrockAuth
    private let timeout: TimeInterval
    private let http: AIHTTP
    private let lock = NSLock()
    private var cachedCredentials: AWSCredentials?
    private var cachedModels: (Date, [AIModel])?
    /// Models that rejected forced tool use; they get the schema as a prompt instruction instead.
    private var noToolChoice: Set<String> = []

    /// Converse output is short structured JSON or a few sentences; never reserve the model maximum.
    static let maxTokens = 1500

    public init(region: String, auth: BedrockAuth, timeout: TimeInterval = 120, configuration: URLSessionConfiguration? = nil) {
        self.region = region.isEmpty ? "us-east-1" : region
        self.auth = auth
        self.timeout = timeout
        self.http = AIHTTP(configuration: configuration)
    }

    var runtimeHost: String { "bedrock-runtime.\(region).amazonaws.com" }
    var controlHost: String { "bedrock.\(region).amazonaws.com" }

    // MARK: Models

    public func listModels() async throws -> [AIModel] {
        if let (date, models) = lock.withLock({ cachedModels }), Date().timeIntervalSince(date) < 600 { return models }

        let foundation = try await send(host: controlHost, path: "/foundation-models", query: [], body: nil, timeout: 20)
        let summaries = (AIHTTP.object(foundation)?["modelSummaries"] as? [[String: Any]]) ?? []
        var capsByModel: [String: Set<ModelCapability>] = [:]
        var models: [AIModel] = []
        for s in summaries {
            guard let id = s["modelId"] as? String else { continue }
            if let lifecycle = s["modelLifecycle"] as? [String: Any], (lifecycle["status"] as? String) == "LEGACY" { continue }
            let caps = Self.capabilities(input: s["inputModalities"] as? [String] ?? [], output: s["outputModalities"] as? [String] ?? [])
            guard !caps.isEmpty else { continue }  // image/video generation models
            capsByModel[id] = caps
            let types = s["inferenceTypesSupported"] as? [String] ?? []
            if types.contains("ON_DEMAND") {
                let name = [s["providerName"] as? String, s["modelName"] as? String].compactMap { $0 }.joined(separator: " ")
                models.append(AIModel(name: id, displayName: name.isEmpty ? nil : name, capabilities: caps, detail: "on-demand"))
            }
        }

        // Many current models (e.g. Claude) can only be invoked through an inference profile.
        var nextToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "1000")]
            if let nextToken { query.append(URLQueryItem(name: "nextToken", value: nextToken)) }
            guard let data = try? await send(host: controlHost, path: "/inference-profiles", query: query, body: nil, timeout: 20),
                  let obj = AIHTTP.object(data) else { break }
            for p in (obj["inferenceProfileSummaries"] as? [[String: Any]]) ?? [] {
                guard let id = p["inferenceProfileId"] as? String, (p["status"] as? String ?? "ACTIVE") == "ACTIVE" else { continue }
                let underlying = ((p["models"] as? [[String: Any]])?.first?["modelArn"] as? String)?.split(separator: "/").last.map(String.init)
                let caps = underlying.flatMap { capsByModel[$0] } ?? []
                models.append(AIModel(name: id, displayName: p["inferenceProfileName"] as? String, capabilities: caps, detail: "inference profile"))
            }
            nextToken = obj["nextToken"] as? String
        } while nextToken != nil

        models.sort { $0.name < $1.name }
        lock.withLock { cachedModels = (Date(), models) }
        return models
    }

    static func capabilities(input: [String], output: [String]) -> Set<ModelCapability> {
        if output.contains("EMBEDDING") { return [.embedding] }
        guard output.contains("TEXT") else { return [] }
        return input.contains("IMAGE") ? [.completion, .vision] : [.completion]
    }

    public func ping() async -> Bool {
        do {
            _ = try await send(host: controlHost, path: "/foundation-models", query: [URLQueryItem(name: "byOutputModality", value: "EMBEDDING")],
                               body: nil, timeout: 8)
            return true
        } catch AIProviderError.http(403, _) {
            // Credentials are valid but lack the (optional) model-listing permission; invocation may still work.
            return true
        } catch {
            return false
        }
    }

    public func validate(model: String, role: String) async throws {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured(role) }
    }

    // MARK: Converse

    static let toolName = "record_result"

    func converseBody(messages: [ChatMessage], schema: [String: Any]?, temperature: Double, forceTool: Bool) -> [String: Any] {
        var system: [[String: Any]] = messages.filter { $0.role == "system" }.map { ["text": $0.content] }
        if let schema, !forceTool { system.append(["text": SchemaPrompt.instruction(schema)]) }
        let turns = messages.filter { $0.role != "system" }.map { m -> [String: Any] in
            var content: [[String: Any]] = m.images.map { ["image": ["format": "jpeg", "source": ["bytes": $0.base64EncodedString()]]] }
            content.append(["text": m.content])
            return ["role": m.role == "assistant" ? "assistant" : "user", "content": content]
        }
        var body: [String: Any] = [
            "messages": turns,
            "inferenceConfig": ["maxTokens": Self.maxTokens, "temperature": temperature],
        ]
        if !system.isEmpty { body["system"] = system }
        if let schema, forceTool {
            body["toolConfig"] = [
                "tools": [["toolSpec": ["name": Self.toolName, "description": "Record the result as structured data.",
                                        "inputSchema": ["json": schema]]]],
                "toolChoice": ["tool": ["name": Self.toolName]],
            ]
        }
        return body
    }

    /// Returns the forced tool's input as JSON, or the text content.
    static func parseConverse(_ data: Data) throws -> String {
        guard let output = AIHTTP.object(data)?["output"] as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse("missing output message")
        }
        if let toolUse = content.compactMap({ $0["toolUse"] as? [String: Any] }).first, let input = toolUse["input"] {
            let json = try JSONSerialization.data(withJSONObject: input)
            return String(data: json, encoding: .utf8) ?? "{}"
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIProviderError.invalidResponse("empty message") }
        return text
    }

    public func chat(model: String, messages: [ChatMessage], schema: [String: Any]?, temperature: Double) async throws -> String {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured("chat") }
        // Structured output: force a tool whose input schema is ours. Models without tool-choice support
        // (it varies by model family) fall back to a schema instruction in the system prompt.
        var forceTool = schema != nil && !lock.withLock { noToolChoice.contains(model) }
        while true {
            do {
                let data = try await send(host: runtimeHost, path: "/model/\(Self.pathSegment(model))/converse", query: [],
                                          body: converseBody(messages: messages, schema: schema, temperature: temperature, forceTool: forceTool),
                                          timeout: timeout)
                return try Self.parseConverse(data)
            } catch AIProviderError.http(400, let message) where forceTool && message.lowercased().contains("tool") {
                lock.withLock { _ = noToolChoice.insert(model) }
                forceTool = false
            }
        }
    }

    // MARK: Embeddings (InvokeModel; request format differs per model family)

    public func embed(model: String, inputs: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured("embedding") }
        let id = model.lowercased()
        let path = "/model/\(Self.pathSegment(model))/invoke"
        if id.contains("titan-embed") {
            // Titan embeds one text per request.
            var vectors: [[Float]] = []
            for input in inputs {
                var body: [String: Any] = ["inputText": input.clipped(20_000)]
                if id.contains("v2") { body["dimensions"] = 1024; body["normalize"] = true }
                let data = try await send(host: runtimeHost, path: path, query: [], body: body, timeout: timeout)
                guard let values = AIHTTP.object(data)?["embedding"] as? [NSNumber] else { throw AIProviderError.invalidResponse("missing embedding") }
                vectors.append(values.map(\.floatValue))
            }
            return vectors
        }
        if id.contains("cohere.embed") {
            var vectors: [[Float]] = []
            for start in stride(from: 0, to: inputs.count, by: 96) {
                let batch = inputs[start..<min(inputs.count, start + 96)].map { $0.clipped(6000) }
                let body: [String: Any] = ["texts": batch, "input_type": purpose == .query ? "search_query" : "search_document",
                                           "truncate": "END", "embedding_types": ["float"]]
                let data = try await send(host: runtimeHost, path: path, query: [], body: body, timeout: timeout)
                vectors += try Self.parseCohere(data, expected: batch.count)
            }
            return vectors
        }
        throw AIProviderError.unsupported("Embedding model “\(model)” isn't supported yet. Use Amazon Titan Text Embeddings or Cohere Embed.")
    }

    static func parseCohere(_ data: Data, expected: Int) throws -> [[Float]] {
        let obj = AIHTTP.object(data)
        // v3 returns `embeddings: [[Float]]`; with embedding_types it's `embeddings: {float: [[Float]]}`.
        let raw = (obj?["embeddings"] as? [[NSNumber]]) ?? ((obj?["embeddings"] as? [String: Any])?["float"] as? [[NSNumber]])
        guard let raw, raw.count == expected else { throw AIProviderError.invalidResponse("embedding count mismatch") }
        return raw.map { $0.map(\.floatValue) }
    }

    // MARK: Transport

    /// Model IDs contain `:` (and ARNs `/`), which must be percent-encoded in the path.
    static func pathSegment(_ id: String) -> String { SigV4.encode(id) }

    private func credentials() async throws -> AWSCredentials {
        if let cached = lock.withLock({ cachedCredentials }), cached.isFresh() { return cached }
        let creds: AWSCredentials
        switch auth {
        case .accessKeys(let c):
            guard !c.accessKeyID.isEmpty, !c.secretAccessKey.isEmpty else { throw AIProviderError.missingCredentials("AWS access key ID and secret") }
            creds = c
        case .profile(let name):
            creds = try await AWSProfileCredentials.load(profile: name)
        case .apiKey:
            throw AIProviderError.missingCredentials("API key mode has no SigV4 credentials")
        }
        lock.withLock { cachedCredentials = creds }
        return creds
    }

    private func send(host: String, path: String, query: [URLQueryItem], body: [String: Any]?, timeout: TimeInterval) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AIProviderError.invalidEndpoint }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = body == nil ? "GET" : "POST"
        let payload = try body.map(AIHTTP.json) ?? Data()
        if body != nil {
            req.httpBody = payload
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth {
        case .apiKey(let key):
            guard !key.isEmpty else { throw AIProviderError.missingCredentials("Bedrock API key") }
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .accessKeys, .profile:
            SigV4.sign(&req, body: payload, credentials: try await credentials(), region: region, service: "bedrock")
        }
        let (data, response) = try await http.send(req)
        if (200..<300).contains(response.statusCode) { return data }
        throw Self.error(status: response.statusCode, data: data, errorType: response.value(forHTTPHeaderField: "x-amzn-ErrorType"))
    }

    static func error(status: Int, data: Data, errorType header: String?) -> AIProviderError {
        let obj = AIHTTP.object(data)
        let type = (header ?? obj?["__type"] as? String ?? "").split(separator: ":").first.map(String.init)?
            .split(separator: "#").last.map(String.init) ?? ""
        let message = AIHTTP.errorMessage(data)
        switch type {
        case "UnrecognizedClientException", "InvalidSignatureException", "ExpiredTokenException", "IncompleteSignature",
             "MissingAuthenticationTokenException", "InvalidClientTokenId", "SignatureDoesNotMatch":
            return .unauthorized(message.isEmpty ? type : message)
        case "ThrottlingException", "ServiceQuotaExceededException": return .http(429, message)
        case "ResourceNotFoundException": return .modelUnavailable(message)
        case "ModelNotReadyException", "ServiceUnavailableException", "ModelTimeoutException", "InternalServerException":
            return .http(503, message)
        default:
            if status == 401 { return .unauthorized(message) }
            return .http(status, message.isEmpty ? type : message)
        }
    }
}
