import Foundation

/// Snapshot of everything that determines whether a capture may happen right now.
public struct CaptureContext: Sendable {
    public var recordingEnabled: Bool
    public var pausedUntil: Date?
    public var screenLocked: Bool
    public var systemAsleep: Bool
    public var userIdle: Bool
    public var onBattery: Bool
    public var sessionActive: Bool
    public var hasScreenCapturePermission: Bool
    public var secureInputActive: Bool
    public var frontmostBundleIdentifier: String?
    public var now: Date

    public init(recordingEnabled: Bool = true, pausedUntil: Date? = nil, screenLocked: Bool = false, systemAsleep: Bool = false,
                userIdle: Bool = false, onBattery: Bool = false, sessionActive: Bool = true,
                hasScreenCapturePermission: Bool = true, secureInputActive: Bool = false,
                frontmostBundleIdentifier: String?, now: Date = Date()) {
        self.recordingEnabled = recordingEnabled
        self.pausedUntil = pausedUntil
        self.screenLocked = screenLocked
        self.systemAsleep = systemAsleep
        self.userIdle = userIdle
        self.onBattery = onBattery
        self.sessionActive = sessionActive
        self.hasScreenCapturePermission = hasScreenCapturePermission
        self.secureInputActive = secureInputActive
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.now = now
    }
}

public enum CaptureDecision: Equatable, Sendable {
    case capture
    case skip(SkipReason)
}

public enum SkipReason: String, Sendable {
    case recordingDisabled = "recording_disabled"
    case paused
    case screenLocked = "screen_locked"
    case asleep
    case idle
    case onBattery = "on_battery"
    case sessionInactive = "session_inactive"
    case noPermission = "no_permission"
    case secureInput = "secure_input"
    case excludedApplication = "excluded_application"
    case ownApplication = "own_application"
    case noFrontmostApplication = "no_frontmost_application"
    case noFocusedWindow = "no_focused_window"
    case windowNotShareable = "window_not_shareable"
    case duplicate
    /// Redaction is on but text recognition failed, so the frame was discarded unstored.
    case redactionFailed = "redaction_failed"

    /// Reasons worth persisting as a `capture_skipped` event (others are routine and would flood the log).
    public var isNoteworthy: Bool {
        switch self {
        case .noFocusedWindow, .windowNotShareable, .secureInput, .excludedApplication, .noPermission, .redactionFailed: return true
        default: return false
        }
    }
}

public struct CapturePolicy: Sendable {
    public var excludedBundleIdentifiers: Set<String>
    public var ownBundleIdentifier: String?
    public var pauseOnBattery: Bool

    public init(excludedBundleIdentifiers: Set<String>, ownBundleIdentifier: String?, pauseOnBattery: Bool) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.ownBundleIdentifier = ownBundleIdentifier
        self.pauseOnBattery = pauseOnBattery
    }

    public init(settings: RecallSettings, ownBundleIdentifier: String?) {
        self.init(excludedBundleIdentifiers: Set(settings.excludedBundleIdentifiers),
                  ownBundleIdentifier: ownBundleIdentifier, pauseOnBattery: settings.pauseOnBattery)
    }

    /// Evaluated *before* any pixels are captured, so excluded content is never grabbed.
    public func decide(_ ctx: CaptureContext) -> CaptureDecision {
        if !ctx.recordingEnabled { return .skip(.recordingDisabled) }
        if let until = ctx.pausedUntil, until > ctx.now { return .skip(.paused) }
        if !ctx.sessionActive { return .skip(.sessionInactive) }
        if ctx.screenLocked { return .skip(.screenLocked) }
        if ctx.systemAsleep { return .skip(.asleep) }
        if !ctx.hasScreenCapturePermission { return .skip(.noPermission) }
        if pauseOnBattery && ctx.onBattery { return .skip(.onBattery) }
        if ctx.userIdle { return .skip(.idle) }
        guard let bundle = ctx.frontmostBundleIdentifier else { return .skip(.noFrontmostApplication) }
        if bundle == ownBundleIdentifier { return .skip(.ownApplication) }
        if excludedBundleIdentifiers.contains(bundle) { return .skip(.excludedApplication) }
        // A password field has focus somewhere (system-wide secure event input).
        if ctx.secureInputActive { return .skip(.secureInput) }
        return .capture
    }
}
