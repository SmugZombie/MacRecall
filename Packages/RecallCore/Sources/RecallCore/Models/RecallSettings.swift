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
    public var ollamaEndpoint = "http://127.0.0.1:11434"
    public var remoteEndpointAcknowledged = false
    public var visionModel = ""
    public var summaryModel = ""
    public var embeddingModel = ""
    public var maxConcurrentRequests = 1
    public var requestTimeout: Double = 120
    public var aiProcessingEnabled = true

    // General
    public var notificationsEnabled = false
    public var showTimezone = false
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
        ollamaEndpoint = v(.ollamaEndpoint, d.ollamaEndpoint)
        remoteEndpointAcknowledged = v(.remoteEndpointAcknowledged, d.remoteEndpointAcknowledged)
        visionModel = v(.visionModel, d.visionModel)
        summaryModel = v(.summaryModel, d.summaryModel)
        embeddingModel = v(.embeddingModel, d.embeddingModel)
        maxConcurrentRequests = v(.maxConcurrentRequests, d.maxConcurrentRequests)
        requestTimeout = v(.requestTimeout, d.requestTimeout)
        aiProcessingEnabled = v(.aiProcessingEnabled, d.aiProcessingEnabled)
        notificationsEnabled = v(.notificationsEnabled, d.notificationsEnabled)
        showTimezone = v(.showTimezone, d.showTimezone)
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

extension RecallSettings {
    /// True when the endpoint is not on this Mac — screenshots and text would leave the machine.
    public var endpointIsRemote: Bool { !OllamaEndpoint.isLoopback(ollamaEndpoint) }
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
