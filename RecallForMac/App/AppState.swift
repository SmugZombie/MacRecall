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
    /// The configured AI provider; its implementation is swapped in place when settings change.
    let ai: SwitchableProvider
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
    /// Permission is granted but this process can't use it until it restarts.
    @Published private(set) var needsRelaunch = false
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var lastSkipReason: SkipReason?
    /// Bumped whenever history changes so views can reload.
    @Published private(set) var revision = 0
    /// Why screenshots couldn't be encrypted, if they couldn't.
    @Published private(set) var imageEncryptionProblem: String?
    /// The first pass over screenshots saved before encryption is still running.
    @Published private(set) var encryptingImages = false
    private var imageEncryptionRunning = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timers: [Timer] = []
    private var hotKey: GlobalHotKey?

    private init() {
        let settings = RecallSettings.load()
        self.settings = settings
        self.ai = SwitchableProvider(settings.makeProvider())
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
        let queue = AIJobQueue(store: store, ai: ai, settings: { settingsBox.value })
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
            MainActor.assumeIsolated {
                self?.runRetention()
                self?.encryptStoredImages()
            }
        })
        updateSessions()
        runRetention()
        encryptStoredImages()
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
        if old.providerConfiguration != s.providerConfiguration { ai.replace(with: s.makeProvider()) }
        Task {
            await coordinator?.update(settings: s)
            if old.recordingEnabled != s.recordingEnabled {
                if s.recordingEnabled { await coordinator?.start() } else { await coordinator?.stop() }
            }
            if old.aiProcessingEnabled != s.aiProcessingEnabled { await queue?.setAIPaused(!s.aiProcessingEnabled) }
            if old.maxConcurrentRequests != s.maxConcurrentRequests { await queue?.setConcurrency(s.maxConcurrentRequests) }
            if old.providerConfiguration != s.providerConfiguration || old.providerModels != s.providerModels
                || old.acknowledgedRemoteTargets != s.acknowledgedRemoteTargets {
                await queue?.checkHealth()
                await queue?.wake()
            }
        }
    }

    // MARK: Capture context

    private func captureContext() -> CaptureContext {
        // Live session state backs up the notification-driven flags, which can miss a transition.
        let live = SystemStateMonitor.liveState()
        return CaptureContext(
            recordingEnabled: settings.recordingEnabled && !manuallyPaused,
            pausedUntil: pausedUntil,
            screenLocked: monitor.screenLocked || monitor.screensAsleep || live.locked || live.displaysAsleep,
            systemAsleep: monitor.asleep,
            userIdle: monitor.userIdle,
            onBattery: settings.pauseOnBattery && SystemStateMonitor.onBatteryPower,
            sessionActive: monitor.sessionActive && live.onConsole,
            hasScreenCapturePermission: hasScreenPermission,
            secureInputActive: SystemStateMonitor.secureInputActive,
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    var recordingState: RecordingState {
        if !hasScreenPermission || needsRelaunch { return .noPermission }
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
        if hasScreenPermission && !needsRelaunch {
            Task { needsRelaunch = await ScreenshotService.needsRelaunchForScreenCapture() }
        }
        if let until = pausedUntil, until <= Date() { pausedUntil = nil }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestScreenPermission() {
        ScreenshotService.requestScreenCapturePermission()
        refreshPermissions()
    }

    /// Starts a fresh instance and quits this one (permission grants apply to new processes).
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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

    /// Encrypts unencrypted screenshots in small batches: those from before encryption, then hourly any
    /// written by an older version. Also retries hourly if the key was unavailable.
    func encryptStoredImages() {
        guard let store, !imageEncryptionRunning else { return }
        imageEncryptionRunning = true
        encryptingImages = (try? store.imagesEncrypted()) != true
        Task.detached(priority: .background) {
            var problem: String?
            do {
                while try !store.encryptStoredImages(limit: 100) {}
            } catch {
                problem = error.localizedDescription
            }
            await MainActor.run {
                AppState.shared.imageEncryptionRunning = false
                AppState.shared.encryptingImages = false
                AppState.shared.imageEncryptionProblem = problem
            }
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

    /// Runs a user-initiated AI request ahead of background analysis.
    func interactive<T>(_ operation: () async throws -> T) async rethrows -> T {
        await queue?.beginInteractive()
        do {
            let value = try await operation()
            await queue?.endInteractive()
            return value
        } catch {
            await queue?.endInteractive()
            throw error
        }
    }

    /// Re-embeds all history with the current embedding model (most recent first).
    func rebuildEmbeddings() {
        guard let store else { return }
        if let rows = try? store.db.query("SELECT id FROM captures ORDER BY captured_at DESC") {
            for row in rows { try? store.enqueueJob(.embedding, entityType: "capture", entityID: row.int("id")!, priority: 1) }
        }
        if let rows = try? store.db.query("SELECT id FROM sessions ORDER BY started_at DESC") {
            for row in rows { try? store.enqueueJob(.embedding, entityType: "session", entityID: row.int("id")!, priority: 1) }
        }
        Task { await queue?.wake() }
        refreshQueue()
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

    /// Rebuilds the provider after credentials in the Keychain changed.
    func credentialsChanged() {
        ai.replace(with: settings.makeProvider())
        Task {
            await queue?.checkHealth()
            await queue?.wake()
            refreshQueue()
        }
    }

    /// Checks the configured AI provider and explains the result in user-facing terms.
    func diagnoseAI() async -> (ok: Bool, message: String) {
        let s = settings
        let name = s.aiProvider.displayName
        let destination = s.aiDestination
        let result: (ok: Bool, message: String)
        do {
            let models = try await ai.listModels()
            if models.isEmpty {
                let hint: String
                switch s.aiProvider {
                case .ollama: hint = " Install one with e.g. `ollama pull llama3.2`."
                case .lmStudio: hint = " Download and load a model in LM Studio."
                case .bedrock: hint = " Request model access in the Bedrock console for \(s.bedrockRegion)."
                case .openAI: hint = ""
                }
                result = (true, "Connected to \(name) at \(destination), but no models are available.\(hint)")
            } else {
                result = (true, "Connected to \(name) — \(models.count) model\(models.count == 1 ? "" : "s") available. Choose them in Settings → AI.")
            }
        } catch AIProviderError.invalidEndpoint {
            result = (false, "“\(destination)” isn't a valid URL. Fix it in Settings → AI.")
        } catch AIProviderError.unreachable {
            switch s.aiProvider {
            case .ollama:
                result = (false, "No Ollama server is responding at \(destination). Install Ollama from ollama.com and start it (or run `ollama serve`), then check again — or choose another provider in Settings → AI.")
            case .lmStudio:
                result = (false, "LM Studio isn't responding at \(destination). In LM Studio, open the Developer tab and start the local server, then check again.")
            case .openAI, .bedrock:
                result = (false, "Couldn't reach \(name) at \(destination). Check your internet connection.")
            }
        } catch AIProviderError.missingCredentials(let what) {
            result = (false, "\(name) needs credentials: \(what). Add them in Settings → AI.")
        } catch AIProviderError.unauthorized(let message) {
            result = (false, "\(name) rejected the credentials: \(message)")
        } catch AIProviderError.http(403, let message) where s.aiProvider == .bedrock {
            // Listing models needs bedrock:ListFoundationModels; invocation may still be permitted.
            result = (true, "Connected to Bedrock, but these credentials can't list models (\(message)). Enter model IDs manually in Settings → AI.")
        } catch {
            result = (false, "\(name) responded with an error: \(error.localizedDescription)")
        }
        // Keep the menu bar / queue status in sync with what we just learned.
        await queue?.checkHealth()
        refreshQueue()
        if result.ok && !s.aiTransmissionAllowed {
            return (true, result.message + " Approve sending data to \(destination) in Settings → AI before Recall uses it.")
        }
        return result
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
