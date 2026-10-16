import AppKit
import RecallCore

/// Checks GitHub for new releases and installs them in place when this copy is able to.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    /// Where releases are published.
    static let repository = "SmugZombie/MacRecall"
    static let checkInterval: TimeInterval = 24 * 3600

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, Double)
        case verifying(AppRelease)
        case installing(AppRelease)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "UpdateLastChecked") as? Date
    @Published var showUpdateWindow = false

    let environment = UpdateInstaller.Environment.current
    var eligibility: UpdateInstaller.Eligibility { UpdateInstaller.eligibility(environment) }
    var currentVersion: String { environment.version?.description ?? "unknown" }

    private var timer: Timer?
    private var work: Task<Void, Never>?

    var availableRelease: AppRelease? {
        switch phase {
        case .available(let r), .downloading(let r, _), .verifying(let r), .installing(let r): return r
        default: return nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    // MARK: Scheduling

    /// Checks shortly after launch (if a day has passed) and then hourly for whether a day has passed.
    func start() {
        Keychain.removeRetiredItems()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateController.shared.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            checkIfDue()
        }
    }

    private func checkIfDue() {
        guard AppState.shared.settings.automaticUpdateChecks, !isBusy else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    // MARK: Check

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        phase = .checking
        let client = GitHubReleaseClient(repository: Self.repository)
        work = Task {
            do {
                let release = try await client.latestRelease()
                lastChecked = Date()
                UserDefaults.standard.set(lastChecked, forKey: "UpdateLastChecked")
                let skipped = AppState.shared.settings.skippedUpdateVersion
                guard let current = environment.version, release.version > current else {
                    phase = .upToDate
                    return
                }
                // Background checks respect "Skip This Version"; asking explicitly always shows it.
                if !userInitiated && skipped == release.version.description {
                    phase = .upToDate
                    return
                }
                phase = .available(release)
                if !userInitiated { showUpdateWindow = true }
            } catch {
                // Background failures stay quiet; they are visible in Settings → General.
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Install

    func skip(_ release: AppRelease) {
        AppState.shared.settings.skippedUpdateVersion = release.version.description
        phase = .upToDate
        showUpdateWindow = false
    }

    func openReleasePage(_ release: AppRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }

    /// Download → checksum → unpack → bundle/version check → signature check → swap → relaunch.
    func install(_ release: AppRelease) {
        guard case .eligible = eligibility else { openReleasePage(release); return }
        guard let asset = release.asset else { phase = .failed(UpdateError.noAsset.localizedDescription); return }
        let env = environment
        phase = .downloading(release, 0)
        work = Task {
            do {
                let zip = try await UpdateInstaller().download(asset) { fraction in
                    Task { @MainActor in
                        if case .downloading(let r, _) = UpdateController.shared.phase {
                            UpdateController.shared.phase = .downloading(r, fraction)
                        }
                    }
                }
                phase = .verifying(release)
                let app = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    try UpdateInstaller.verifyChecksum(zip, expected: asset.sha256)
                    let app = try UpdateInstaller.extractApp(from: zip)
                    try UpdateInstaller.validateBundle(app, expectedVersion: release.version, environment: env)
                    try UpdateInstaller.verifySignature(of: app, environment: env)
                    return app
                }.value
                phase = .installing(release)
                try UpdateInstaller.install(app, over: env)
                try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
                AppState.shared.settings.skippedUpdateVersion = ""
                try UpdateInstaller.relaunch(env.bundleURL)
                NSApp.terminate(nil)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        if case .downloading(let r, _) = phase { phase = .available(r) }
    }
}
