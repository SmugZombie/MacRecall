import Foundation

/// All user preferences. Persisted as one JSON blob in UserDefaults so new fields get defaults
/// automatically and the whole configuration can be validated in one place.
public struct RecallSettings: Codable, Sendable, Equatable {
    // Capture
    public var recordingEnabled = true
    public var captureInterval: Double = 30
    public var captureOnWindowChange = true
    public var maxImageWidth = 2560
    public var maxImageHeight = 1600
    public var imageFormat: ImageFormat = .heic
    public var compressionQuality = 0.6
    public var dedupSensitivity = 0.5
    public var idleTimeout: Double = 300
    public var pauseOnBattery = false
    public var captureCursor = false

    // Privacy
    public var excludedBundleIdentifiers: [String] = RecallSettings.defaultExclusions
    public var retentionDays = 30
    public var automaticCleanup = true
    public var redactionEnabled = true
    public var sensitiveRules = SensitiveContentRules()

    // AI
    public var aiProvider: AIProviderKind = .ollama
    /// Model choices per provider, keyed by `AIProviderKind.rawValue`, so switching providers keeps each set.
    public var providerModels: [String: ModelSelection] = [:]
    public var ollamaEndpoint = "http://127.0.0.1:11434"
    public var lmStudioEndpoint = OpenAICompatibleProvider.defaultLMStudioEndpoint
    public var openAIEndpoint = OpenAICompatibleProvider.defaultOpenAIEndpoint
    public var bedrockRegion = "us-east-1"
    public var bedrockAuthMode: BedrockAuthMode = .apiKey
    public var bedrockProfile = "default"
    /// Remote AI destinations the user has explicitly approved (see `remoteTargetKey`).
    public var acknowledgedRemoteTargets: [String] = []
    public var maxConcurrentRequests = 1
    public var requestTimeout: Double = 120
    public var aiProcessingEnabled = true

    // Updates
    public var automaticUpdateChecks = true
    /// A version the user chose to skip; newer versions are still offered.
    public var skippedUpdateVersion = ""

    // AI agents
    /// Lets MCP clients (`RecallForMac --mcp`) read history. Off until the user turns it on.
    public var mcpEnabled = false
    /// Also lets them view screenshots (`get_screenshot`). Separate because images show more than redacted text.
    public var mcpScreenshotsEnabled = false
    /// Also lets them read files attached to notes (`get_note_attachment`). Separate because attachments can be anything.
    public var mcpAttachmentsEnabled = false

    // General
    public var notificationsEnabled = false
    public var onboardingCompleted = false

    public init() {}

    public static let defaultExclusions = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
    ]

    /// Clamps values to supported ranges.
    public func validated() -> RecallSettings {
        var s = self
        s.captureInterval = min(300, max(10, captureInterval))
        s.maxImageWidth = min(7680, max(640, maxImageWidth))
        s.maxImageHeight = min(4320, max(480, maxImageHeight))
        s.compressionQuality = min(1, max(0.1, compressionQuality))
        s.dedupSensitivity = min(1, max(0, dedupSensitivity))
        s.idleTimeout = min(3600, max(60, idleTimeout))
        s.retentionDays = min(3650, max(1, retentionDays))
        s.maxConcurrentRequests = min(8, max(1, maxConcurrentRequests))
        s.requestTimeout = min(900, max(10, requestTimeout))
        return s
    }

    // Tolerant decoding: missing keys fall back to defaults instead of failing the whole blob.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecallSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        recordingEnabled = v(.recordingEnabled, d.recordingEnabled)
        captureInterval = v(.captureInterval, d.captureInterval)
        captureOnWindowChange = v(.captureOnWindowChange, d.captureOnWindowChange)
        maxImageWidth = v(.maxImageWidth, d.maxImageWidth)
        maxImageHeight = v(.maxImageHeight, d.maxImageHeight)
        imageFormat = v(.imageFormat, d.imageFormat)
        compressionQuality = v(.compressionQuality, d.compressionQuality)
        dedupSensitivity = v(.dedupSensitivity, d.dedupSensitivity)
        idleTimeout = v(.idleTimeout, d.idleTimeout)
        pauseOnBattery = v(.pauseOnBattery, d.pauseOnBattery)
        captureCursor = v(.captureCursor, d.captureCursor)
        excludedBundleIdentifiers = v(.excludedBundleIdentifiers, d.excludedBundleIdentifiers)
        retentionDays = v(.retentionDays, d.retentionDays)
        automaticCleanup = v(.automaticCleanup, d.automaticCleanup)
        redactionEnabled = v(.redactionEnabled, d.redactionEnabled)
        sensitiveRules = v(.sensitiveRules, d.sensitiveRules)
        aiProvider = v(.aiProvider, d.aiProvider)
        providerModels = v(.providerModels, d.providerModels)
        ollamaEndpoint = v(.ollamaEndpoint, d.ollamaEndpoint)
        lmStudioEndpoint = v(.lmStudioEndpoint, d.lmStudioEndpoint)
        openAIEndpoint = v(.openAIEndpoint, d.openAIEndpoint)
        bedrockRegion = v(.bedrockRegion, d.bedrockRegion)
        bedrockAuthMode = v(.bedrockAuthMode, d.bedrockAuthMode)
        bedrockProfile = v(.bedrockProfile, d.bedrockProfile)
        acknowledgedRemoteTargets = v(.acknowledgedRemoteTargets, d.acknowledgedRemoteTargets)
        // Settings from before multi-provider support stored Ollama models and a single remote flag at the top level.
        struct Legacy: Decodable {
            var visionModel: String?
            var summaryModel: String?
            var embeddingModel: String?
            var remoteEndpointAcknowledged: Bool?
        }
        if let legacy = try? Legacy(from: decoder) {
            if providerModels[AIProviderKind.ollama.rawValue] == nil, legacy.visionModel != nil || legacy.summaryModel != nil || legacy.embeddingModel != nil {
                providerModels[AIProviderKind.ollama.rawValue] = ModelSelection(
                    vision: legacy.visionModel ?? "", summary: legacy.summaryModel ?? "", embedding: legacy.embeddingModel ?? "")
            }
            if legacy.remoteEndpointAcknowledged == true, aiProvider == .ollama, !acknowledgedRemoteTargets.contains(remoteTargetKey) {
                acknowledgedRemoteTargets.append(remoteTargetKey)
            }
        }
        maxConcurrentRequests = v(.maxConcurrentRequests, d.maxConcurrentRequests)
        requestTimeout = v(.requestTimeout, d.requestTimeout)
        aiProcessingEnabled = v(.aiProcessingEnabled, d.aiProcessingEnabled)
        automaticUpdateChecks = v(.automaticUpdateChecks, d.automaticUpdateChecks)
        skippedUpdateVersion = v(.skippedUpdateVersion, d.skippedUpdateVersion)
        mcpEnabled = v(.mcpEnabled, d.mcpEnabled)
        mcpScreenshotsEnabled = v(.mcpScreenshotsEnabled, d.mcpScreenshotsEnabled)
        mcpAttachmentsEnabled = v(.mcpAttachmentsEnabled, d.mcpAttachmentsEnabled)
        notificationsEnabled = v(.notificationsEnabled, d.notificationsEnabled)
        onboardingCompleted = v(.onboardingCompleted, d.onboardingCompleted)
    }

    private static let defaultsKey = "RecallSettings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> RecallSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(RecallSettings.self, from: data) else { return RecallSettings() }
        return settings.validated()
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(validated()) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

public struct ModelSelection: Codable, Sendable, Equatable {
    public var vision = ""
    public var summary = ""
    public var embedding = ""

    public init(vision: String = "", summary: String = "", embedding: String = "") {
        self.vision = vision
        self.summary = summary
        self.embedding = embedding
    }

    /// Apple Intelligence has exactly one text model and one embedding model, so they're chosen up front.
    /// It reads no images, so there's no vision model.
    public static func defaults(for provider: AIProviderKind) -> ModelSelection {
        provider == .appleIntelligence
            ? ModelSelection(summary: AppleIntelligenceProvider.languageModel, embedding: AppleIntelligenceProvider.embeddingModel)
            : ModelSelection()
    }
}

public enum BedrockAuthMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case apiKey, accessKeys, profile
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .apiKey: return "Bedrock API key"
        case .accessKeys: return "Access keys"
        case .profile: return "AWS profile"
        }
    }
}

extension RecallSettings {
    private var selection: ModelSelection {
        get { providerModels[aiProvider.rawValue] ?? ModelSelection.defaults(for: aiProvider) }
        set { providerModels[aiProvider.rawValue] = newValue }
    }

    /// Models for the active provider.
    public var visionModel: String {
        get { selection.vision }
        set { selection.vision = newValue }
    }
    public var summaryModel: String {
        get { selection.summary }
        set { selection.summary = newValue }
    }
    public var embeddingModel: String {
        get { selection.embedding }
        set { selection.embedding = newValue }
    }

    /// Key under which embeddings are stored. Namespaced by provider so vectors from different
    /// services never mix; Ollama keeps bare names for compatibility with existing indexes.
    public var embeddingIndexKey: String {
        guard !embeddingModel.isEmpty else { return "" }
        return aiProvider == .ollama ? embeddingModel : "\(aiProvider.rawValue)/\(embeddingModel)"
    }

    /// Where AI requests go, in user-facing terms.
    public var aiDestination: String {
        switch aiProvider {
        case .ollama: return ollamaEndpoint
        case .lmStudio: return lmStudioEndpoint
        case .openAI: return openAIEndpoint
        case .bedrock: return "Amazon Bedrock (\(bedrockRegion))"
        case .appleIntelligence: return "Apple Intelligence on this Mac"
        }
    }

    /// AI job types that can't run because no model is selected for them. Such jobs stay queued
    /// (so choosing a model later backfills them) but aren't a processing backlog.
    public var unconfiguredJobTypes: Set<JobType> {
        var types: Set<JobType> = []
        if embeddingModel.isEmpty { types.insert(.embedding) }
        if visionModel.isEmpty && summaryModel.isEmpty { types.insert(.visionAnalysis) }
        if summaryModel.isEmpty { types.formUnion([.sessionSummary, .dailySummary]) }
        return types
    }

    /// True when screenshots and text would leave this Mac.
    public var providerIsRemote: Bool {
        switch aiProvider {
        case .ollama: return !OllamaEndpoint.isLoopback(ollamaEndpoint)
        case .lmStudio: return !OllamaEndpoint.isLoopback(lmStudioEndpoint)
        case .openAI, .bedrock: return true
        case .appleIntelligence: return false
        }
    }

    public var remoteTargetKey: String { "\(aiProvider.rawValue)|\(aiDestination)" }

    /// AI work may only be sent to a remote destination after the user explicitly approved it.
    public var aiTransmissionAllowed: Bool { !providerIsRemote || acknowledgedRemoteTargets.contains(remoteTargetKey) }

    public mutating func acknowledgeRemoteTarget() {
        if !acknowledgedRemoteTargets.contains(remoteTargetKey) { acknowledgedRemoteTargets.append(remoteTargetKey) }
    }

    /// Settings that require rebuilding the provider client when changed.
    public var providerConfiguration: [String] {
        [aiProvider.rawValue, ollamaEndpoint, lmStudioEndpoint, openAIEndpoint, bedrockRegion, bedrockAuthMode.rawValue,
         bedrockProfile, String(requestTimeout)]
    }
}

public enum OllamaEndpoint {
    public static func isLoopback(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        // A real 127.0.0.0/8 address — not a hostname that merely starts with "127.".
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
