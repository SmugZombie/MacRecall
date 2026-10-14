import Foundation

extension RecallSettings {
    /// Builds the provider for the current settings, reading secrets from the Keychain.
    public func makeProvider(secrets: (Keychain.Account) -> String? = Keychain.get) -> any AIProvider {
        switch aiProvider {
        case .ollama:
            return OllamaProvider(endpoint: ollamaEndpoint, timeout: requestTimeout)
        case .lmStudio:
            return OpenAICompatibleProvider(kind: .lmStudio, endpoint: lmStudioEndpoint, apiKey: secrets(.lmStudioAPIKey), timeout: requestTimeout)
        case .openAI:
            return OpenAICompatibleProvider(kind: .openAI, endpoint: openAIEndpoint, apiKey: secrets(.openAIAPIKey), timeout: requestTimeout)
        case .bedrock:
            let auth: BedrockAuth
            switch bedrockAuthMode {
            case .apiKey: auth = .apiKey(secrets(.bedrockAPIKey) ?? "")
            case .accessKeys:
                auth = .accessKeys(AWSCredentials(accessKeyID: secrets(.awsAccessKeyID) ?? "",
                                                  secretAccessKey: secrets(.awsSecretAccessKey) ?? "",
                                                  sessionToken: secrets(.awsSessionToken)))
            case .profile: auth = .profile(bedrockProfile)
            }
            return BedrockProvider(region: bedrockRegion, auth: auth, timeout: requestTimeout)
        }
    }
}

/// A stable provider handle whose implementation can be swapped when settings change,
/// so long-lived services (job queue, search) never hold a stale client.
public final class SwitchableProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any AIProvider

    public init(_ provider: any AIProvider) { current = provider }

    public func replace(with provider: any AIProvider) { lock.withLock { current = provider } }

    private var inner: any AIProvider { lock.withLock { current } }

    public var kind: AIProviderKind { inner.kind }
    public func listModels() async throws -> [AIModel] { try await inner.listModels() }
    public func ping() async -> Bool { await inner.ping() }
    public func validate(model: String, role: String) async throws { try await inner.validate(model: model, role: role) }
    public func chat(model: String, messages: [ChatMessage], schema: [String: Any]?, temperature: Double) async throws -> String {
        try await inner.chat(model: model, messages: messages, schema: schema, temperature: temperature)
    }
    public func embed(model: String, inputs: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        try await inner.embed(model: model, inputs: inputs, purpose: purpose)
    }
}
