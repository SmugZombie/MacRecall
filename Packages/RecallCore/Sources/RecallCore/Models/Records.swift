import Foundation

public enum ProcessingStatus: String, Sendable, Codable, CaseIterable {
    case pending, running, done, failed, skipped
}

public struct ApplicationRecord: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var bundleIdentifier: String
    public var name: String
}

public struct CaptureRecord: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var applicationID: Int64
    public var applicationName: String
    public var bundleIdentifier: String
    public var windowID: Int64?
    public var windowTitle: String
    public var capturedAt: Date
    /// Last time this exact content was observed (duplicates extend this).
    public var lastSeenAt: Date
    public var timezone: String
    public var imagePath: String
    public var thumbnailPath: String
    public var imageHash: String
    public var width: Int
    public var height: Int
    public var ocrText: String
    public var ocrConfidence: Double?
    public var ocrStatus: ProcessingStatus
    public var aiStatus: ProcessingStatus
    public var aiDescription: String
    public var aiJSON: String?
    public var projectID: Int64?
    public var sessionID: Int64?
    public var redacted: Bool
}

public struct CaptureMark: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var capturedAt: Date
    public var applicationName: String
}

public struct NewCapture: Sendable {
    public var bundleIdentifier: String
    public var applicationName: String
    public var pid: Int32
    public var systemWindowID: UInt32
    public var windowTitle: String
    public var capturedAt: Date
    public var timezone: String
    public var imagePath: String
    public var thumbnailPath: String
    public var imageHash: String
    public var width: Int
    public var height: Int
    public var ocrText: String?
    public var ocrConfidence: Double?
    public var redacted: Bool
    public var metadataJSON: String

    public init(bundleIdentifier: String, applicationName: String, pid: Int32, systemWindowID: UInt32,
                windowTitle: String, capturedAt: Date, timezone: String = TimeZone.current.identifier,
                imagePath: String, thumbnailPath: String, imageHash: String, width: Int, height: Int,
                ocrText: String? = nil, ocrConfidence: Double? = nil, redacted: Bool = false,
                metadataJSON: String = "{}") {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.pid = pid
        self.systemWindowID = systemWindowID
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
        self.timezone = timezone
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
        self.imageHash = imageHash
        self.width = width
        self.height = height
        self.ocrText = ocrText
        self.ocrConfidence = ocrConfidence
        self.redacted = redacted
        self.metadataJSON = metadataJSON
    }
}

public enum ActivityEventType: String, Sendable, Codable {
    case appActivated = "app_activated"
    case windowChanged = "window_changed"
    case contentChanged = "content_changed"
    case idle
    case resumed
    case screenLocked = "screen_locked"
    case screenUnlocked = "screen_unlocked"
    case sleep
    case wake
    case recordingPaused = "recording_paused"
    case recordingResumed = "recording_resumed"
    case captureSkipped = "capture_skipped"
    case captureFailed = "capture_failed"
}

public struct ActivityEvent: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var timestamp: Date
    public var type: ActivityEventType
    public var applicationName: String?
    public var windowTitle: String?
    public var metadata: [String: String]
}

public struct SessionRecord: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var startedAt: Date
    public var endedAt: Date
    public var title: String
    public var titleSource: String
    public var summary: String
    /// "none", "ai" or "user". AI never overwrites a user-written summary.
    public var summarySource: String
    public var projectID: Int64?
    public var projectName: String?
    public var projectSource: String
    public var classificationConfidence: Double?
    public var activeSeconds: Double
    /// The user curated this session's grouping (merged or split it); automatic regrouping leaves it alone.
    public var userLocked: Bool
    public var captureCount: Int
    public var applicationNames: [String]
    public var bundleIdentifiers: [String]
    public var thumbnailPath: String?
}

public struct ProjectRules: Codable, Sendable, Hashable {
    public var keywords: [String] = []
    public var aliases: [String] = []
    public var repositoryPaths: [String] = []
    public var domains: [String] = []
    public var bundleIdentifiers: [String] = []

    public init(keywords: [String] = [], aliases: [String] = [], repositoryPaths: [String] = [],
                domains: [String] = [], bundleIdentifiers: [String] = []) {
        self.keywords = keywords
        self.aliases = aliases
        self.repositoryPaths = repositoryPaths
        self.domains = domains
        self.bundleIdentifiers = bundleIdentifiers
    }
}

public struct ProjectRecord: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var name: String
    public var description: String
    public var rules: ProjectRules
    public var createdAt: Date
}

public enum JobType: String, Sendable, Codable, CaseIterable {
    case ocr
    case visionAnalysis = "vision_analysis"
    case embedding
    case sessionSummary = "session_summary"
    case dailySummary = "daily_summary"
    case projectAssociation = "project_association"

    /// Whether the job needs Ollama. Non-AI jobs keep running when AI is paused or offline.
    public var requiresAI: Bool {
        switch self {
        case .ocr, .projectAssociation: return false
        default: return true
        }
    }
}

public struct JobRecord: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var type: JobType
    public var entityType: String
    public var entityID: Int64
    public var status: ProcessingStatus
    public var priority: Int
    public var attempts: Int
    public var lastError: String?
    public var createdAt: Date
    public var nextAttemptAt: Date
    public var completedAt: Date?
    /// When the latest attempt started.
    public var startedAt: Date?
    /// Processing time of all finished attempts (excludes time spent waiting in the queue).
    public var processingSeconds: Double

    /// Total processing time; for a running job, includes the attempt in progress.
    public func totalProcessingTime(now: Date = Date()) -> TimeInterval? {
        switch status {
        case .running:
            guard let startedAt else { return nil }
            return processingSeconds + max(0, now.timeIntervalSince(startedAt))
        case .done, .failed:
            return startedAt == nil && processingSeconds == 0 ? nil : processingSeconds
        default:
            return processingSeconds > 0 ? processingSeconds : nil
        }
    }

    /// Time between being queued and the latest attempt starting.
    public var queueWait: TimeInterval? {
        startedAt.map { max(0, $0.timeIntervalSince(createdAt)) }
    }
}

public struct DailySummaryRecord: Sendable, Hashable {
    public var localDate: String
    public var timezone: String
    public var summary: String
    public var generatedAt: Date
}

public struct StorageStats: Sendable {
    public var captureCount: Int
    public var databaseBytes: Int64
    public var imageBytes: Int64
    public var oldestCapture: Date?
    public var totalBytes: Int64 { databaseBytes + imageBytes }
}
