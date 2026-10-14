import Foundation
import os

public struct QueueStatus: Sendable, Equatable {
    public var counts = QueueCounts()
    public var ollamaReachable = false
    public var aiPaused = false
    public var lastError: String?
    public init() {}
}

/// Durable background queue. Jobs live in SQLite, so they survive restarts; this actor only
/// schedules workers. OCR and project association run without Ollama; AI jobs wait while
/// Ollama is offline, paused, or unconfigured, without consuming retry attempts.
public actor AIJobQueue {
    private let store: RecallStore
    private let processor: JobProcessor
    private let ollama: OllamaService
    private let settings: @Sendable () -> RecallSettings
    private let log = Logger(subsystem: "RecallForMac", category: "jobs")

    private var workers: [Task<Void, Never>] = []
    private var healthTask: Task<Void, Never>?
    private var status = QueueStatus()
    private var aiPaused = false
    private var wakeGeneration = 0

    public var onStatus: (@Sendable (QueueStatus) -> Void)?

    public init(store: RecallStore, ollama: OllamaService, settings: @escaping @Sendable () -> RecallSettings) {
        self.store = store
        self.ollama = ollama
        self.settings = settings
        self.processor = JobProcessor(store: store, ollama: ollama, settings: settings)
    }

    public func setOnStatus(_ handler: (@Sendable (QueueStatus) -> Void)?) { onStatus = handler }

    public func start() {
        stop()
        if let n = try? store.recoverInterruptedJobs(), n > 0 { log.info("Recovered \(n) interrupted jobs") }
        let s = settings()
        aiPaused = !s.aiProcessingEnabled
        // Local work (OCR, project rules): two workers. Ollama work: bounded by the user's concurrency limit.
        for _ in 0..<2 { workers.append(Task { [weak self] in await self?.workerLoop(ai: false) }) }
        for _ in 0..<s.maxConcurrentRequests { workers.append(Task { [weak self] in await self?.workerLoop(ai: true) }) }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkHealth()
                let reachable = await self?.status.ollamaReachable ?? false
                try? await Task.sleep(for: .seconds(reachable ? 60 : 20))
            }
        }
    }

    public func stop() {
        workers.forEach { $0.cancel() }
        workers.removeAll()
        healthTask?.cancel()
        healthTask = nil
        wake()
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
        let reachable = await ollama.ping()
        if reachable != status.ollamaReachable {
            log.info("Ollama reachable: \(reachable)")
            status.ollamaReachable = reachable
            if reachable { wake() }
        }
        publish()
    }

    public func currentStatus() -> QueueStatus {
        status.counts = (try? store.queueCounts()) ?? status.counts
        status.aiPaused = aiPaused
        return status
    }

    private func publish() {
        status.counts = (try? store.queueCounts()) ?? status.counts
        status.aiPaused = aiPaused
        onStatus?(status)
    }

    /// Job types an AI worker may claim right now, given configured models.
    private func allowedAITypes() -> Set<JobType> {
        guard !aiPaused, status.ollamaReachable else { return [] }
        let s = settings()
        var types: Set<JobType> = []
        if !s.visionModel.isEmpty || !s.summaryModel.isEmpty { types.insert(.visionAnalysis) }
        if !s.embeddingModel.isEmpty { types.insert(.embedding) }
        if !s.summaryModel.isEmpty { types.formUnion([.sessionSummary, .dailySummary]) }
        return types
    }

    private func workerLoop(ai: Bool) async {
        while !Task.isCancelled {
            let types: Set<JobType> = ai ? allowedAITypes() : [.ocr, .projectAssociation]
            let jobs = (try? store.claimJobs(types: types, limit: 1)) ?? []
            guard let job = jobs.first else {
                await idle(seconds: ai ? 15 : 5)
                continue
            }
            await run(job)
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

    private func run(_ job: JobRecord) async {
        publish()
        do {
            try await processor.process(job)
            try? store.completeJob(id: job.id)
        } catch let error as OllamaError where error.isOutage {
            // Server down: put the job back without spending an attempt and stop claiming AI work.
            status.ollamaReachable = false
            try? store.deferJob(id: job.id, until: Date().addingTimeInterval(30))
        } catch let error as OllamaError {
            status.lastError = error.localizedDescription
            _ = try? store.failJob(id: job.id, error: error.localizedDescription, retryable: error.isTransient)
        } catch {
            status.lastError = error.localizedDescription
            _ = try? store.failJob(id: job.id, error: error.localizedDescription, retryable: true)
        }
        publish()
    }
}
