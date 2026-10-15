import Foundation
import os

public struct QueueStatus: Sendable, Equatable {
    public var counts = QueueCounts()
    /// Queued jobs that can't run until a model is chosen for them (e.g. embeddings with no embedding model).
    public var awaitingConfiguration: [JobType: Int] = [:]
    /// Pending jobs that will actually be processed: the real backlog.
    public var actionablePending: Int { max(0, counts.pending - awaitingConfiguration.values.reduce(0, +)) }
    public var providerReachable = false
    public var aiPaused = false
    public var lastError: String?
    public init() {}
}

/// Durable background queue. Jobs live in SQLite, so they survive restarts; this actor only
/// schedules workers. OCR and project association run without a provider; AI jobs wait while
/// the AI provider is offline, paused, unapproved or unconfigured, without consuming retry attempts.
public actor AIJobQueue {
    private let store: RecallStore
    private let processor: JobProcessor
    private let ai: any AIProvider
    private let settings: @Sendable () -> RecallSettings
    private let log = Logger(subsystem: "RecallForMac", category: "jobs")

    private var workers: [Task<Void, Never>] = []
    /// Workers exit after their current job once their generation is superseded, so reconfiguring
    /// never cancels in-flight requests.
    private var workerGeneration = 0
    /// Jobs this process is working on right now; any other `running` row is orphaned.
    private var inFlight: Set<Int64> = []
    private var healthTask: Task<Void, Never>?
    private var status = QueueStatus()
    private var aiPaused = false
    private var wakeGeneration = 0
    /// Interactive requests (e.g. Ask) in flight. Background AI work isn't claimed meanwhile, so a
    /// single-slot local server like LM Studio answers the user next instead of after the backlog.
    private var interactiveHolds = 0

    public var onStatus: (@Sendable (QueueStatus) -> Void)?

    public init(store: RecallStore, ai: any AIProvider, settings: @escaping @Sendable () -> RecallSettings) {
        self.store = store
        self.ai = ai
        self.settings = settings
        self.processor = JobProcessor(store: store, ai: ai, settings: settings)
    }

    public func setOnStatus(_ handler: (@Sendable (QueueStatus) -> Void)?) { onStatus = handler }

    /// Starts processing. Call once at launch: it also recovers jobs a previous process left running.
    public func start() {
        guard healthTask == nil else { return }
        if let n = try? store.recoverInterruptedJobs(), n > 0 { log.info("Recovered \(n) interrupted jobs") }
        aiPaused = !settings().aiProcessingEnabled
        spawnWorkers(aiConcurrency: settings().maxConcurrentRequests)
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkHealth()
                await self?.requeueOrphans()
                let reachable = await self?.status.providerReachable ?? false
                try? await Task.sleep(for: .seconds(reachable ? 60 : 20))
            }
        }
    }

    /// Changes the number of AI workers. Current workers finish their job and retire; nothing is cancelled.
    public func setConcurrency(_ aiConcurrency: Int) {
        guard healthTask != nil else { return }
        spawnWorkers(aiConcurrency: aiConcurrency)
    }

    private func spawnWorkers(aiConcurrency: Int) {
        workerGeneration += 1
        let generation = workerGeneration
        workers.removeAll()
        // Local work (OCR, project rules): two workers. AI provider work: bounded by the user's concurrency limit.
        for _ in 0..<2 { workers.append(Task { [weak self] in await self?.workerLoop(ai: false, generation: generation) }) }
        for _ in 0..<max(1, aiConcurrency) { workers.append(Task { [weak self] in await self?.workerLoop(ai: true, generation: generation) }) }
        wake()
    }

    /// Shutdown only. In-flight jobs are interrupted and returned to the queue.
    public func stop() {
        workerGeneration += 1
        workers.forEach { $0.cancel() }
        workers.removeAll()
        healthTask?.cancel()
        healthTask = nil
        wake()
    }

    private func requeueOrphans() {
        if let n = try? store.requeueOrphanedJobs(excluding: inFlight), n > 0 {
            log.info("Requeued \(n) orphaned jobs")
            publish()
        }
    }

    public func beginInteractive() { interactiveHolds += 1 }

    public func endInteractive() {
        interactiveHolds = max(0, interactiveHolds - 1)
        if interactiveHolds == 0 { wake() }
    }

    public func setAIPaused(_ paused: Bool) {
        aiPaused = paused
        status.aiPaused = paused
        publish()
        wake()
    }

    /// Wakes idle workers (new jobs were enqueued).
    public func wake() {
        wakeGeneration &+= 1
    }

    public func checkHealth() async {
        let reachable = await ai.ping()
        if reachable != status.providerReachable {
            log.info("AI provider reachable: \(reachable)")
            status.providerReachable = reachable
            if reachable { wake() }
        }
        publish()
    }

    public func currentStatus() -> QueueStatus {
        refreshCounts()
        return status
    }

    private func publish() {
        refreshCounts()
        onStatus?(status)
    }

    private func refreshCounts() {
        status.counts = (try? store.queueCounts()) ?? status.counts
        status.aiPaused = aiPaused
        let unconfigured = settings().unconfiguredJobTypes
        status.awaitingConfiguration = status.counts.byType.filter { unconfigured.contains($0.key) && $0.value > 0 }
    }

    /// Job types an AI worker may claim right now, given configured models.
    private func allowedAITypes() -> Set<JobType> {
        let s = settings()
        // Nothing goes to a remote provider until the user has approved that destination.
        guard !aiPaused, interactiveHolds == 0, status.providerReachable, s.aiTransmissionAllowed else { return [] }
        var types: Set<JobType> = []
        if !s.visionModel.isEmpty || !s.summaryModel.isEmpty { types.insert(.visionAnalysis) }
        if !s.embeddingModel.isEmpty { types.insert(.embedding) }
        if !s.summaryModel.isEmpty { types.formUnion([.sessionSummary, .dailySummary]) }
        return types
    }

    private func workerLoop(ai: Bool, generation: Int) async {
        while !Task.isCancelled && generation == workerGeneration {
            let types: Set<JobType> = ai ? allowedAITypes() : [.ocr, .projectAssociation]
            let jobs = (try? store.claimJobs(types: types, limit: 1)) ?? []
            guard let job = jobs.first else {
                await idle(seconds: ai ? 15 : 5)
                continue
            }
            // Registered before any suspension point so the orphan sweep never requeues a live job.
            inFlight.insert(job.id)
            await run(job)
            inFlight.remove(job.id)
        }
    }

    private func idle(seconds: Double) async {
        // Sleep until woken or the timeout elapses (jobs with backoff become ready on their own).
        let generation = wakeGeneration
        for _ in 0..<Int(seconds * 4) {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled || wakeGeneration != generation { return }
        }
    }

    enum Disposition: Equatable {
        /// Work was interrupted (shutdown, cancellation): back to the queue, no attempt spent.
        case requeue
        /// The provider is down or rejecting credentials: back to the queue, stop claiming AI work.
        case outage
        case fail(retryable: Bool)
    }

    static func disposition(for error: Error, cancelled: Bool) -> Disposition {
        if cancelled || error is CancellationError { return .requeue }
        if let error = error as? AIProviderError {
            return error.isOutage ? .outage : .fail(retryable: error.isTransient)
        }
        return .fail(retryable: true)
    }

    private func run(_ job: JobRecord) async {
        publish()
        do {
            try await processor.process(job)
            await record("complete job \(job.id)") { try self.store.completeJob(id: job.id) }
        } catch {
            switch Self.disposition(for: error, cancelled: Task.isCancelled) {
            case .requeue:
                await record("requeue job \(job.id)") { try self.store.deferJob(id: job.id, until: Date()) }
            case .outage:
                status.providerReachable = false
                status.lastError = error.localizedDescription
                await record("defer job \(job.id)") { try self.store.deferJob(id: job.id, until: Date().addingTimeInterval(30)) }
            case .fail(let retryable):
                status.lastError = error.localizedDescription
                await record("fail job \(job.id)") {
                    _ = try self.store.failJob(id: job.id, error: error.localizedDescription, retryable: retryable)
                }
            }
        }
        publish()
    }

    /// Writes job bookkeeping, retrying briefly (e.g. SQLITE_BUSY). If it still fails, the row stays
    /// `running` and the orphan sweep returns it to the queue once this worker lets go of it.
    private func record(_ what: String, _ write: () throws -> Void) async {
        for attempt in 1...3 {
            do {
                try write()
                return
            } catch {
                if attempt == 3 {
                    log.error("Couldn't \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(200 * attempt))
            }
        }
    }
}
