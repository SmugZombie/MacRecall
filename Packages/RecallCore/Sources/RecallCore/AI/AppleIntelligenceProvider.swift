import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence's on-device model (Foundation Models framework, macOS 26) for text, and Apple's
/// NaturalLanguage contextual embeddings for semantic search. Nothing leaves the Mac.
///
/// Limits compared with other providers: no image input (screenshots are analyzed from their recognized
/// text), a context window of about 4,096 tokens (long prompts are trimmed in the middle), safety guardrails
/// that can decline some content, and weaker embeddings than dedicated embedding models.
public final class AppleIntelligenceProvider: AIProvider, @unchecked Sendable {
    public let kind: AIProviderKind = .appleIntelligence

    public static let languageModel = "apple-on-device"
    public static let embeddingModel = "apple-nl-latin"

    /// Prompt sizes to try, in characters. The model's context is about 4,096 tokens shared by instructions,
    /// prompt, schema and answer; three characters per token is a cautious average for screen text.
    static let promptBudgets = [8000, 4500, 2500]
    static let instructionsBudget = 2400

    private let lock = NSLock()
    private var embedding: NLContextualEmbedding?

    public init() {}

    // MARK: Availability

    /// Why Apple Intelligence can't be used right now, in user-facing terms; nil when it's ready.
    public static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "Apple Intelligence for apps needs macOS 26 Tahoe or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac can't run Apple Intelligence. It needs a Mac with Apple silicon."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is still downloading. Recall starts using it once it's ready."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
        #else
        return "This copy of Recall was built without Apple Intelligence support."
        #endif
    }

    public func listModels() async throws -> [AIModel] {
        var models = [AIModel(name: Self.embeddingModel, displayName: "Apple NaturalLanguage embeddings",
                              capabilities: [.embedding], detail: "on-device")]
        if Self.unavailabilityReason == nil {
            models.insert(AIModel(name: Self.languageModel, displayName: "Apple on-device model",
                                  capabilities: [.completion], detail: "on-device, text only"), at: 0)
        }
        return models
    }

    public func ping() async -> Bool { Self.unavailabilityReason == nil }

    public func validate(model: String, role: String) async throws {
        guard !model.isEmpty else { throw AIProviderError.modelNotConfigured(role) }
        if role == "vision" {
            throw AIProviderError.unsupported("Apple Intelligence can't read images. Clear the vision model; screenshots are then analyzed from their recognized text.")
        }
        guard model == Self.languageModel else { throw AIProviderError.modelUnavailable(model) }
        if let reason = Self.unavailabilityReason { throw AIProviderError.unreachable(reason) }
    }

    // MARK: Chat

    public func chat(model: String, messages: [ChatMessage], schema: [String: Any]?, temperature: Double) async throws -> String {
        guard model == Self.languageModel else { throw AIProviderError.modelUnavailable(model) }
        guard messages.allSatisfy({ $0.images.isEmpty }) else {
            throw AIProviderError.unsupported("Apple Intelligence can't read images. Clear the vision model; screenshots are then analyzed from their recognized text.")
        }
        if let reason = Self.unavailabilityReason { throw AIProviderError.unreachable(reason) }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw AIProviderError.unreachable("Apple Intelligence for apps needs macOS 26 Tahoe or later.") }
        let instructions = Self.trimMiddle(messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n"),
                                           to: Self.instructionsBudget)
        let prompt = messages.filter { $0.role != "system" }.map(\.content).joined(separator: "\n\n")
        let generationSchema = try schema.map(Self.generationSchema)
        for (index, budget) in Self.promptBudgets.enumerated() {
            let session = LanguageModelSession(
                model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
                instructions: instructions.isEmpty ? nil : instructions)
            let options = GenerationOptions(temperature: temperature, maximumResponseTokens: 700)
            let text = Self.trimMiddle(prompt, to: budget)
            do {
                if let generationSchema {
                    return try await session.respond(to: text, schema: generationSchema, options: options).content.jsonString
                }
                return try await session.respond(to: text, options: options).content
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, index < Self.promptBudgets.count - 1 { continue }
                throw Self.map(error)
            }
        }
        throw AIProviderError.invalidResponse("The request exceeded Apple Intelligence's context window.")
        #else
        throw AIProviderError.unreachable("This copy of Recall was built without Apple Intelligence support.")
        #endif
    }

    /// Keeps the start and the end (where prompts put the question or the final instruction) and drops the middle.
    static func trimMiddle(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        let marker = "\n…[shortened to fit the model]…\n"
        let head = Int(Double(budget - marker.count) * 0.6)
        let tail = budget - marker.count - head
        return String(text.prefix(head)) + marker + String(text.suffix(tail))
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func map(_ error: LanguageModelSession.GenerationError) -> AIProviderError {
        switch error {
        case .exceededContextWindowSize:
            return .invalidResponse("The request exceeded Apple Intelligence's context window.")
        case .guardrailViolation, .refusal:
            return .unsupported("Apple Intelligence declined to process this content because of its safety guardrails.")
        case .unsupportedLanguageOrLocale:
            return .unsupported("Apple Intelligence doesn't support the language of this content.")
        case .assetsUnavailable:
            return .unreachable("The Apple Intelligence model isn't ready yet.")
        case .rateLimited, .concurrentRequests:
            return .http(429, "Apple Intelligence is busy; trying again later.")
        case .decodingFailure:
            return .invalidResponse("Apple Intelligence returned output that doesn't match the requested format.")
        default:
            return .invalidResponse(error.localizedDescription)
        }
    }

    /// Converts the JSON schemas Recall uses (objects of strings, numbers, booleans, arrays and nullable
    /// fields) into a schema the on-device model can be constrained to.
    @available(macOS 26.0, *)
    static func generationSchema(_ json: [String: Any]) throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(json, name: "Response"), dependencies: [])
    }

    @available(macOS 26.0, *)
    static func dynamicSchema(_ json: [String: Any], name: String) throws -> DynamicGenerationSchema {
        let types = (json["type"] as? [String]) ?? (json["type"] as? String).map { [$0] } ?? ["string"]
        let type = types.first { $0 != "null" } ?? "string"
        switch type {
        case "object":
            let properties = json["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(json["required"] as? [String] ?? [])
            return DynamicGenerationSchema(name: name, description: json["description"] as? String, properties: try properties.keys.sorted().map { key in
                let property = properties[key]!
                let nullable = (property["type"] as? [String])?.contains("null") == true
                return DynamicGenerationSchema.Property(name: key, description: property["description"] as? String,
                                                        schema: try dynamicSchema(property, name: "\(name)_\(key)"),
                                                        isOptional: nullable || !required.contains(key))
            })
        case "array":
            return DynamicGenerationSchema(arrayOf: try dynamicSchema(json["items"] as? [String: Any] ?? [:], name: "\(name)_item"))
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default:
            if let choices = json["enum"] as? [String] { return DynamicGenerationSchema(name: name, anyOf: choices) }
            return DynamicGenerationSchema(type: String.self)
        }
    }
    #endif

    // MARK: Embeddings

    public func embed(model: String, inputs: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        guard model == Self.embeddingModel else { throw AIProviderError.modelUnavailable(model) }
        let embedding = try await loadedEmbedding()
        return try lock.withLock { try inputs.map { try Self.meanVector(embedding, $0) } }
    }

    /// The contextual embedding model for Latin-script languages, downloading its assets the first time.
    private func loadedEmbedding() async throws -> NLContextualEmbedding {
        if let embedding = lock.withLock({ embedding }) { return embedding }
        guard let model = NLContextualEmbedding(script: .latin) else {
            throw AIProviderError.unreachable("Apple's NaturalLanguage embeddings aren't available on this Mac.")
        }
        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else {
                throw AIProviderError.unreachable("Apple's NaturalLanguage embedding model is still downloading.")
            }
        }
        try model.load()
        lock.withLock { embedding = model }
        return model
    }

    /// One vector per text: the mean of its token vectors (the model reads at most its maximum sequence length).
    static func meanVector(_ embedding: NLContextualEmbedding, _ text: String) throws -> [Float] {
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var count = 0
        let input = text.isEmpty ? " " : text
        let result = try embedding.embeddingResult(for: input, language: nil)
        result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { throw AIProviderError.invalidResponse("no tokens to embed") }
        return sum.map { Float($0 / Double(count)) }
    }
}
