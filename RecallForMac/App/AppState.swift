import AppKit
import Combine
import Foundation
import RecallCore
import ServiceManagement

enum RecordingState: Equatable {
    case recording
    case paused(until: Date?)
    case noPermission
    case suspended(String)

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .paused(let until):
            guard let until else { return "Paused" }
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        case .noPermission: return "Screen Recording permission needed"
        case .suspended(let why): return "Not capturing — \(why)"
        }
    }

    var symbol: String {
        switch self {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle"
        case .noPermission: return "exclamationmark.triangle"
        case .suspended: return "moon.circle"
        }
    }
}

/// Owns long-lived services and publishes app-wide state to SwiftUI.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store: RecallStore?
    let startupError: String?
    let ollama: OllamaService
    private(set) var coordinator: CaptureCoordinator?
    private(set) var queue: AIJobQueue?
    let monitor = SystemStateMonitor()

    @Published var settings: RecallSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var manuallyPaused = false
    @Published private(set) var queueStatus = QueueStatus()
    @Published private(set) var hasScreenPermission = ScreenshotService.hasScreenCapturePermission
    @Published private(set) var hasAccessibility = ActiveWindowResolver.accessibilityTrusted
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var lastSkipReason: SkipReason?
    /// Bumped whenever history changes so views can reload.
    @Published private(set) var revision = 0
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timers: [Timer] = []
    private var hotKey: GlobalHotKey?

    private init() {
        let settings = RecallSettings.load()
        self.settings = settings
        self.ollama = OllamaService(endpoint: settings.ollamaEndpoint, timeout: settings.requestTimeout)
        do {
            self.store = try RecallStore(paths: .default)
            self.startupError = nil
        } catch {
            self.store = nil
            self.startupError = "Could not open the history database: \(error.localizedDescription)"
        }
    }

    // MARK: Lifecycle

    func start() {
        guard let store else { return }
        if (try? store.db.integrityCheck()) == false {
            // Rebuilding the FTS indexes resolves the most common corruption (index/table drift).
            try? store.rebuildSearchIndexes()
        }

        let settingsBox = SettingsBox(settings)
        self.settingsBox = settingsBox
        let queue = AIJobQueue(store: store, ollama: ollama, settings: { settingsBox.value })
        self.queue = queue
        // AppState lives for the whole process, so callbacks reference the shared instance directly.
        let coordinator = CaptureCoordinator(store: store, settings: settings, ownBundleIdentifier: Bundle.main.bundleIdentifier) {
            await AppState.shared.captureContext()
        }
        self.coordinator = coordinator

        Task {
            await coordinator.setOnCapture { outcome in
                Task { @MainActor in AppState.shared.handle(outcome) }
            }
            await queue.setOnStatus { status in
                Task { @MainActor in
                    let state = AppState.shared
                    let finished = status.counts.pending < state.queueStatus.counts.pending
                    state.queueStatus = status
                    if finished { state.revision += 1 }
                }
            }
            await queue.start()
            if settings.recordingEnabled { await coordinator.start() }
        }

        monitor.idleTimeout = settings.idleTimeout
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.start()

        // Periodic maintenance: sessions every minute, permissions every 10s, retention hourly.
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSessions() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runRetention() }
        })
        updateSessions()
        runRetention()
        scheduleYesterdaySummary()

        hotKey = GlobalHotKey { [weak self] in self?.toggleRecording() }
    }

    func shutdown() {
        timers.forEach { $0.invalidate() }
        monitor.stop()
        let coordinator = coordinator, queue = queue
        Task {
            await coordinator?.stop()
            await queue?.stop()
        }
    }

    private var settingsBox: SettingsBox?

    private func settingsChanged(from old: RecallSettings) {
        settings.save()
        settingsBox?.value = settings
        monitor.idleTimeout = settings.idleTimeout
        let s = settings
        Task {
            await coordinator?.update(settings: s)
            await ollama.configure(endpoint: s.ollamaEndpoint, timeout: s.requestTimeout)
            if old.recordingEnabled != s.recordingEnabled {
                if s.recordingEnabled { await coordinator?.start() } else { await coordinator?.stop() }
            }
            if old.aiProcessingEnabled != s.aiProcessingEnabled { await queue?.setAIPaused(!s.aiProcessingEnabled) }
            if old.maxConcurrentRequests != s.maxConcurrentRequests { await queue?.start() }
            if old.ollamaEndpoint != s.ollamaEndpoint || old.visionModel != s.visionModel
                || old.summaryModel != s.summaryModel || old.embeddingModel != s.embeddingModel {
                await queue?.checkHealth()
                await queue?.wake()
            }
        }
    }

    // MARK: Capture context

    private func captureContext() -> CaptureContext {
        CaptureContext(
            recordingEnabled: settings.recordingEnabled && !manuallyPaused,
            pausedUntil: pausedUntil,
            screenLocked: monitor.screenLocked || monitor.screensAsleep,
            systemAsleep: monitor.asleep,
            userIdle: monitor.userIdle,
            onBattery: settings.pauseOnBattery && SystemStateMonitor.onBatteryPower,
            sessionActive: monitor.sessionActive,
            hasScreenCapturePermission: hasScreenPermission,
            secureInputActive: SystemStateMonitor.secureInputActive,
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    var recordingState: RecordingState {
        if !hasScreenPermission { return .noPermission }
        if !settings.recordingEnabled || manuallyPaused { return .paused(until: nil) }
        if let until = pausedUntil, until > Date() { return .paused(until: until) }
        if monitor.screenLocked { return .suspended("screen locked") }
        if monitor.userIdle { return .suspended("idle") }
        return .recording
    }

    private func handle(_ outcome: CaptureOutcome) {
        switch outcome {
        case .captured:
            lastCaptureAt = Date()
            lastSkipReason = nil
            revision += 1
            Task { await queue?.wake() }
        case .extended:
            lastCaptureAt = Date()
        case .skipped(let reason):
            if reason != .duplicate { lastSkipReason = reason }
        case .failed:
            break
        }
    }

    private func handle(_ event: SystemStateMonitor.Event) {
        guard let store else { return }
        let type: ActivityEventType?
        switch event {
        case .appActivated:
            Task { await coordinator?.applicationActivated() }
            type = nil
        case .screenLocked: type = .screenLocked
        case .screenUnlocked: type = .screenUnlocked
        case .willSleep: type = .sleep
        case .didWake: type = .wake
        case .idle: type = .idle
        case .resumed: type = .resumed
        case .screensSlept, .sessionResigned: type = .screenLocked
        case .screensWoke, .sessionBecameActive: type = .screenUnlocked
        }
        if let type {
            try? store.logEvent(type)
            if [.screenUnlocked, .wake, .resumed].contains(type) {
                Task { await coordinator?.resetContinuity() }
            }
            if [.idle, .screenLocked, .sleep].contains(type) { updateSessions() }
        }
        objectWillChange.send()
    }

    // MARK: Recording control

    func toggleRecording() {
        if recordingState == .recording || pausedUntil != nil { pause() } else { resume() }
    }

    func pause(for minutes: Int? = nil) {
        if let minutes {
            pausedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        } else {
            manuallyPaused = true
        }
        try? store?.logEvent(.recordingPaused)
    }

    func resume() {
        manuallyPaused = false
        pausedUntil = nil
        if !settings.recordingEnabled { settings.recordingEnabled = true }
        try? store?.logEvent(.recordingResumed)
        Task {
            await coordinator?.resetContinuity()
            await coordinator?.captureNow(trigger: .manual)
        }
    }

    func captureNow() {
        Task { await coordinator?.captureNow(trigger: .manual) }
    }

    // MARK: Permissions

    func refreshPermissions() {
        hasScreenPermission = ScreenshotService.hasScreenCapturePermission
        hasAccessibility = ActiveWindowResolver.accessibilityTrusted
        if let until = pausedUntil, until <= Date() { pausedUntil = nil }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestScreenPermission() {
        ScreenshotService.requestScreenCapturePermission()
        refreshPermissions()
    }

    func requestAccessibility() {
        ActiveWindowResolver.requestAccessibility()
        refreshPermissions()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login change failed: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Maintenance

    func updateSessions() {
        guard let store else { return }
        var config = SessionBuilder.Config()
        config.maxGap = settings.idleTimeout
        config.sampleCredit = settings.captureInterval
        do {
            if try ActivitySessionManager(store: store, config: config).update() > 0 { revision += 1 }
        } catch {
            NSLog("Session update failed: %@", error.localizedDescription)
        }
        Task { await queue?.wake() }
    }

    func runRetention() {
        guard let store, settings.automaticCleanup else { return }
        let days = settings.retentionDays
        Task.detached(priority: .background) {
            _ = try? RetentionManager(store: store).enforce(retentionDays: days)
        }
    }

    private func scheduleYesterdaySummary() {
        guard let store else { return }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let key = DailySummaryService.dayKey(for: yesterday)
        if (try? store.dailySummary(localDate: DailySummaryService.localDateString(key), timezone: TimeZone.current.identifier)) == nil {
            try? store.enqueueJob(.dailySummary, entityType: "day", entityID: key, priority: 2)
        }
    }

    func reprocessPending() {
        guard let store else { return }
        try? store.retryFailedJobs()
        _ = try? store.db.run("UPDATE captures SET ai_status = 'pending' WHERE ai_status IN ('failed', 'skipped')")
        if let rows = try? store.db.query("SELECT id FROM captures WHERE ai_status = 'pending' ORDER BY captured_at DESC LIMIT 5000") {
            for row in rows { try? store.enqueueJob(.visionAnalysis, entityType: "capture", entityID: row.int("id")!, priority: 1) }
        }
        if let rows = try? store.db.query("SELECT id FROM captures WHERE ocr_status IN ('pending','failed')") {
            for row in rows { try? store.enqueueJob(.ocr, entityType: "capture", entityID: row.int("id")!, priority: 3) }
        }
        Task { await queue?.wake() }
    }

    /// Requests analysis of one capture ahead of the backlog.
    func prioritize(captureID: Int64) {
        try? store?.enqueueJob(.visionAnalysis, entityType: "capture", entityID: captureID, priority: 100)
        Task { await queue?.wake() }
    }

    func historyChanged() { revision += 1 }

    func refreshQueue() {
        Task {
            if let status = await queue?.currentStatus() { queueStatus = status }
        }
    }

    /// Checks the configured server and explains the result in user-facing terms.
    func diagnoseOllama() async -> (ok: Bool, message: String) {
        let endpoint = settings.ollamaEndpoint
        let result: (ok: Bool, message: String)
        do {
            let models = try await ollama.listModels()
            result = models.isEmpty
                ? (true, "Connected to \(endpoint), but no models are installed. Install one with e.g. `ollama pull llama3.2`.")
                : (true, "Connected to \(endpoint) — \(models.count) model\(models.count == 1 ? "" : "s") installed. Choose them in Settings → AI.")
        } catch OllamaError.invalidEndpoint {
            result = (false, "“\(endpoint)” isn't a valid URL. Fix it in Settings → AI.")
        } catch OllamaError.unreachable {
            result = (false, "No Ollama server is responding at \(endpoint). Install Ollama from ollama.com and start it (or run `ollama serve`), then check again. If it runs elsewhere, set the endpoint in Settings → AI.")
        } catch {
            result = (false, "Ollama at \(endpoint) responded with an error: \(error.localizedDescription)")
        }
        // Keep the menu bar / queue status in sync with what we just learned.
        await queue?.checkHealth()
        refreshQueue()
        return result
    }

    func checkOllama() async -> Bool {
        await queue?.checkHealth()
        refreshQueue()
        return await ollama.ping()
    }
}

/// Thread-safe holder so background services read the latest settings without hopping to the main actor.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: RecallSettings
    init(_ value: RecallSettings) { _value = value }
    var value: RecallSettings {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
