import AppKit
import Foundation
import os

public enum CaptureTrigger: String, Sendable {
    case timer, appActivated, windowChanged, manual, screenClipping, copiedImage
}

/// The app and window a stored image is attributed to.
struct CaptureSource {
    var bundleIdentifier: String
    var applicationName: String
    var pid: pid_t
    var windowID: CGWindowID
    var title: String
    var frame: CGRect
    var matchMethod: String

    init(_ window: ResolvedWindow) {
        self.init(bundleIdentifier: window.bundleIdentifier, applicationName: window.applicationName, pid: window.pid,
                  windowID: window.windowID, title: window.title, frame: window.frame, matchMethod: window.matchMethod)
    }

    init(bundleIdentifier: String, applicationName: String, pid: pid_t, windowID: CGWindowID, title: String,
         frame: CGRect, matchMethod: String) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.pid = pid
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.matchMethod = matchMethod
    }
}

public enum CaptureOutcome: Sendable, Equatable {
    case captured(Int64)
    case extended(Int64)
    case skipped(SkipReason)
    case failed(String)
}

/// Owns the capture loop: policy check → window resolution → screenshot → dedupe → persist → enqueue.
///
/// Capture never waits on OCR or AI. When redaction is enabled, OCR runs inline *before* the image
/// is written, because redaction must happen before anything is stored.
public actor CaptureCoordinator {
    public typealias ContextProvider = @Sendable () async -> CaptureContext

    private let store: RecallStore
    private let resolver = ActiveWindowResolver()
    private let screenshots = ScreenshotService()
    private let ocr = VisionOCRService()
    private let contextProvider: ContextProvider
    private let ownBundleIdentifier: String?
    private var settings: RecallSettings
    private let log = Logger(subsystem: "RecallForMac", category: "capture")

    private var loopTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var inFlight = false

    // Last observed state, for event classification and dedupe.
    private var lastPID: pid_t?
    private var lastWindowKey: String?
    private var lastFingerprint: ImageFingerprint?
    private var lastCaptureID: Int64?
    private var lastCaptureAt: Date?
    /// Last image taken from the clipboard, so copying the same picture again doesn't store it twice.
    private var lastClipboardFingerprint: ImageFingerprint?

    public var onCapture: (@Sendable (CaptureOutcome) -> Void)?

    public init(store: RecallStore, settings: RecallSettings, ownBundleIdentifier: String?, contextProvider: @escaping ContextProvider) {
        self.store = store
        self.settings = settings
        self.ownBundleIdentifier = ownBundleIdentifier
        self.contextProvider = contextProvider
    }

    public func setOnCapture(_ handler: (@Sendable (CaptureOutcome) -> Void)?) { onCapture = handler }

    public func update(settings: RecallSettings) {
        let intervalChanged = settings.captureInterval != self.settings.captureInterval
        let watchChanged = settings.captureOnWindowChange != self.settings.captureOnWindowChange
        self.settings = settings
        if loopTask != nil && (intervalChanged || watchChanged) { start() }
    }

    public func start() {
        stop()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.captureNow(trigger: .timer)
                let interval = await self.settings.captureInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        if settings.captureOnWindowChange {
            watchTask = Task { [weak self] in
                var lastKey: String?
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    let key = await Self.focusKey()
                    if let key, let previous = lastKey, key != previous {
                        // Let the new window settle (animations, content load) before capturing.
                        try? await Task.sleep(for: .milliseconds(800))
                        _ = await self.captureNow(trigger: .windowChanged)
                    }
                    lastKey = key
                }
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        watchTask?.cancel()
        loopTask = nil
        watchTask = nil
    }

    /// Notifies the coordinator of an activation so the next capture is attributed correctly.
    public func applicationActivated() async {
        guard settings.captureOnWindowChange else { return }
        try? await Task.sleep(for: .milliseconds(800))
        _ = await captureNow(trigger: .appActivated)
    }

    /// Cheap identity of the focused window (pid + AX title), polled to detect window switches.
    @MainActor
    static func focusKey() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard ActiveWindowResolver.accessibilityTrusted else { return "\(pid)" }
        let title = ActiveWindowResolver.focusedWindowInfo(pid: pid)?.title ?? ""
        return "\(pid)|\(title)"
    }

    @discardableResult
    public func captureNow(trigger: CaptureTrigger) async -> CaptureOutcome {
        // Coalesce overlapping triggers (timer + window change firing together).
        guard !inFlight else { return .skipped(.duplicate) }
        if trigger != .manual, let last = lastCaptureAt, Date().timeIntervalSince(last) < 2 { return .skipped(.duplicate) }
        inFlight = true
        defer { inFlight = false }

        let outcome = await performCapture(trigger: trigger)
        onCapture?(outcome)
        return outcome
    }

    private func performCapture(trigger: CaptureTrigger) async -> CaptureOutcome {
        let context = await contextProvider()
        let policy = CapturePolicy(settings: settings, ownBundleIdentifier: ownBundleIdentifier)
        if case .skip(let reason) = policy.decide(context) {
            recordSkip(reason, detail: trigger.rawValue, bundle: context.frontmostBundleIdentifier)
            return .skipped(reason)
        }
        guard let app = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else {
            return .skipped(.noFrontmostApplication)
        }
        // Re-check: the frontmost app can change between building the context and now.
        if let bundle = app.bundleIdentifier, bundle == ownBundleIdentifier || settings.excludedBundleIdentifiers.contains(bundle) {
            return .skipped(bundle == ownBundleIdentifier ? .ownApplication : .excludedApplication)
        }

        let window: ResolvedWindow
        switch await resolver.resolve(app: app) {
        case .skipped(let reason, let detail):
            recordSkip(reason, detail: detail, bundle: app.bundleIdentifier)
            return .skipped(reason)
        case .resolved(let w):
            window = w
        }

        let image: CGImage
        do {
            image = try await screenshots.capture(window: window.scWindow, maxWidth: settings.maxImageWidth,
                                                  maxHeight: settings.maxImageHeight, showsCursor: settings.captureCursor)
        } catch {
            log.error("Window capture failed: \(error.localizedDescription, privacy: .public)")
            try? store.logEvent(.captureFailed, metadata: ["reason": error.localizedDescription, "bundle": window.bundleIdentifier])
            return .failed(error.localizedDescription)
        }

        let now = Date()
        let windowKey = "\(window.pid)|\(window.windowID)|\(window.title)"
        let fingerprint = ImageFingerprint(image: image)

        // Classify the change for the activity log.
        if lastPID != window.pid {
            try? logChange(.appActivated, window: window, at: now)
        } else if lastWindowKey != windowKey {
            try? logChange(.windowChanged, window: window, at: now)
        }

        // Duplicate frame of the same window: extend duration instead of storing again.
        if windowKey == lastWindowKey, let fp = fingerprint, let last = lastFingerprint, let lastID = lastCaptureID,
           fp.isDuplicate(of: last, sensitivity: settings.dedupSensitivity) {
            try? store.extendCapture(id: lastID, lastSeen: now)
            lastCaptureAt = now
            return .extended(lastID)
        }
        if windowKey == lastWindowKey { try? logChange(.contentChanged, window: window, at: now) }

        do {
            let record = try await persist(image: image, source: CaptureSource(window), fingerprint: fingerprint, at: now, trigger: trigger)
            lastPID = window.pid
            lastWindowKey = windowKey
            lastFingerprint = fingerprint
            lastCaptureID = record.id
            lastCaptureAt = now
            return .captured(record.id)
        } catch let error as RedactionGate.Unavailable {
            log.error("Discarded frame: \(error.localizedDescription, privacy: .public)")
            recordSkip(.redactionFailed, detail: "ocr failed", bundle: window.bundleIdentifier)
            return .skipped(.redactionFailed)
        } catch {
            log.error("Persisting capture failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Stores an image taken from the clipboard (see `ClipboardWatcher`), attributed to the frontmost app.
    ///
    /// The same rules as screen capture apply: nothing is stored while recording is paused or the screen is
    /// locked, or when the frontmost app is excluded. Dedupe state for window captures is left alone.
    @discardableResult
    public func captureClipboardImage(_ image: CGImage, kind: ClipboardImageKind) async -> CaptureOutcome {
        let outcome = await performClipboardCapture(image, kind: kind)
        onCapture?(outcome)
        return outcome
    }

    private func performClipboardCapture(_ image: CGImage, kind: ClipboardImageKind) async -> CaptureOutcome {
        let trigger: CaptureTrigger = kind == .screenClipping ? .screenClipping : .copiedImage
        let context = await contextProvider()
        let policy = CapturePolicy(settings: settings, ownBundleIdentifier: ownBundleIdentifier)
        if case .skip(let reason) = policy.decide(context) {
            recordSkip(reason, detail: trigger.rawValue, bundle: context.frontmostBundleIdentifier)
            return .skipped(reason)
        }
        guard let source = await MainActor.run(body: { Self.frontmostSource() }) else { return .skipped(.noFrontmostApplication) }
        if source.bundleIdentifier == ownBundleIdentifier { return .skipped(.ownApplication) }
        if settings.excludedBundleIdentifiers.contains(source.bundleIdentifier) {
            recordSkip(.excludedApplication, detail: trigger.rawValue, bundle: source.bundleIdentifier)
            return .skipped(.excludedApplication)
        }

        let scaled = ImageProcessing.resize(image, maxWidth: settings.maxImageWidth, maxHeight: settings.maxImageHeight)
        let fingerprint = ImageFingerprint(image: scaled)
        if let fp = fingerprint, let last = lastClipboardFingerprint, fp.isDuplicate(of: last, sensitivity: settings.dedupSensitivity) {
            return .skipped(.duplicate)
        }
        do {
            let record = try await persist(image: scaled, source: source, fingerprint: fingerprint, at: Date(), trigger: trigger)
            lastClipboardFingerprint = fingerprint
            return .captured(record.id)
        } catch let error as RedactionGate.Unavailable {
            log.error("Discarded clipboard image: \(error.localizedDescription, privacy: .public)")
            recordSkip(.redactionFailed, detail: "ocr failed", bundle: source.bundleIdentifier)
            return .skipped(.redactionFailed)
        } catch {
            log.error("Persisting clipboard image failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// The frontmost app and its focused window, without capturing anything.
    @MainActor
    static func frontmostSource() -> CaptureSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? "pid.\(pid)"
        let focused = ActiveWindowResolver.accessibilityTrusted ? ActiveWindowResolver.focusedWindowInfo(pid: pid) : nil
        return CaptureSource(bundleIdentifier: bundle, applicationName: app.localizedName ?? bundle, pid: pid,
                             windowID: ActiveWindowResolver.windowZOrder(pid: pid).first ?? 0, title: focused?.title ?? "",
                             frame: focused?.frame ?? .zero, matchMethod: "clipboard")
    }

    private func persist(image: CGImage, source window: CaptureSource, fingerprint: ImageFingerprint?, at date: Date,
                         trigger: CaptureTrigger) async throws -> CaptureRecord {
        var finalImage = image
        var ocrText: String?
        var ocrConfidence: Double?
        var redacted = false

        if settings.redactionEnabled {
            // Redaction must precede storage, so OCR runs inline here. If it fails this throws,
            // and the frame is discarded rather than stored unredacted.
            let ocr = self.ocr
            let prepared = try await RedactionGate.prepare(image, rules: settings.sensitiveRules) { try await ocr.recognize($0) }
            finalImage = prepared.image
            ocrText = prepared.ocrText
            ocrConfidence = prepared.ocrConfidence
            redacted = prepared.redacted
        }

        let (imageRel, thumbRel) = Self.relativePaths(for: date, format: settings.imageFormat)
        let imageData = try ImageProcessing.encode(finalImage, format: settings.imageFormat, quality: settings.compressionQuality)
        let thumb = ImageProcessing.resize(finalImage, maxWidth: 480, maxHeight: 300)
        let thumbData = try ImageProcessing.encode(thumb, format: .jpeg, quality: 0.7)
        try store.vault.write(imageData, to: imageRel)
        try store.vault.write(thumbData, to: thumbRel)

        let metadata: [String: String] = [
            "match": window.matchMethod,
            "trigger": trigger.rawValue,
            "frame": "\(Int(window.frame.minX)),\(Int(window.frame.minY)),\(Int(window.frame.width)),\(Int(window.frame.height))",
        ]
        let new = NewCapture(
            bundleIdentifier: window.bundleIdentifier, applicationName: window.applicationName, pid: window.pid,
            systemWindowID: window.windowID, windowTitle: window.title, capturedAt: date,
            imagePath: imageRel, thumbnailPath: thumbRel, imageHash: fingerprint?.hexHash ?? "",
            width: finalImage.width, height: finalImage.height, ocrText: ocrText, ocrConfidence: ocrConfidence,
            redacted: redacted, metadataJSON: (try? String(data: JSONEncoder().encode(metadata), encoding: .utf8)) ?? "{}")
        let record: CaptureRecord
        do {
            record = try store.insertCapture(new)
        } catch {
            // Don't leave orphaned files if the row could not be written.
            try? FileManager.default.removeItem(at: store.paths.absolute(imageRel))
            try? FileManager.default.removeItem(at: store.paths.absolute(thumbRel))
            throw error
        }
        if ocrText == nil {
            try? store.enqueueJob(.ocr, entityType: "capture", entityID: record.id, priority: 20)
        } else {
            try? store.enqueueJob(.projectAssociation, entityType: "capture", entityID: record.id, priority: 15)
            try? store.enqueueJob(.embedding, entityType: "capture", entityID: record.id, priority: 5)
        }
        try? store.enqueueJob(.visionAnalysis, entityType: "capture", entityID: record.id, priority: 10)
        return record
    }

    static func relativePaths(for date: Date, format: ImageFormat) -> (String, String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let dir = String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)
        let name = "\(Int(date.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        return ("screenshots/\(dir)/\(name).\(format.fileExtension)", "thumbnails/\(dir)/\(name).jpg")
    }

    private func logChange(_ type: ActivityEventType, window: ResolvedWindow, at date: Date) throws {
        let appID = try store.upsertApplication(bundleIdentifier: window.bundleIdentifier, name: window.applicationName, at: date)
        let windowID = try store.upsertWindow(applicationID: appID, systemWindowID: window.windowID, title: window.title, at: date)
        try store.logEvent(type, at: date, applicationID: appID, windowID: windowID)
    }

    private var lastSkip: (SkipReason, Date)?

    private func recordSkip(_ reason: SkipReason, detail: String, bundle: String?) {
        guard reason.isNoteworthy else { return }
        // Throttle identical skip events to one every five minutes.
        if let (r, t) = lastSkip, r == reason, Date().timeIntervalSince(t) < 300 { return }
        lastSkip = (reason, Date())
        // Detail strings are generic descriptions, never window contents.
        try? store.logEvent(.captureSkipped, metadata: ["reason": reason.rawValue, "detail": detail, "bundle": bundle ?? ""])
    }

    /// Forget dedupe state (after resume, unlock, wake) so the next frame is always stored.
    public func resetContinuity() {
        lastFingerprint = nil
        lastWindowKey = nil
        lastPID = nil
    }
}
