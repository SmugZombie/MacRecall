import Foundation

/// Executes individual jobs. Stateless apart from its dependencies; the queue handles scheduling.
public struct JobProcessor: Sendable {
    public let store: RecallStore
    public let ai: any AIProvider
    public let settings: @Sendable () -> RecallSettings

    public init(store: RecallStore, ai: any AIProvider, settings: @escaping @Sendable () -> RecallSettings) {
        self.store = store
        self.ai = ai
        self.settings = settings
    }

    public func process(_ job: JobRecord) async throws {
        switch (job.type, job.entityType) {
        case (.ocr, "capture"): try await runOCR(captureID: job.entityID)
        case (.visionAnalysis, "capture"): try await analyze(captureID: job.entityID)
        case (.embedding, "capture"): try await embedCapture(job.entityID)
        case (.embedding, "session"): try await embedSession(job.entityID)
        case (.projectAssociation, "capture"): try associateCapture(job.entityID)
        case (.projectAssociation, "session"): try associateSession(job.entityID)
        case (.sessionSummary, "session"): try await summarizeSession(job.entityID)
        case (.dailySummary, "day"):
            let service = DailySummaryService(store: store, ai: ai, settings: settings)
            _ = try await service.generate(dayKey: job.entityID)
        default:
            throw AIProviderError.invalidResponse("unsupported job \(job.type.rawValue)/\(job.entityType)")
        }
    }

    // MARK: OCR

    func runOCR(captureID: Int64) async throws {
        guard let capture = try store.capture(id: captureID) else { return }
        guard let image = ImageProcessing.load(store.paths.absolute(capture.imagePath)) else {
            try store.setOCRStatus(captureID: captureID, .failed)
            return
        }
        try store.setOCRStatus(captureID: captureID, .running)
        do {
            let result = try await VisionOCRService().recognize(image)
            let s = settings()
            let text = s.redactionEnabled ? s.sensitiveRules.redact(result.text) : result.text
            try store.updateOCR(captureID: captureID, text: text, confidence: result.meanConfidence, status: .done)
        } catch {
            try store.setOCRStatus(captureID: captureID, .failed)
            throw error
        }
        try store.enqueueJob(.projectAssociation, entityType: "capture", entityID: captureID, priority: 15)
        try store.enqueueJob(.embedding, entityType: "capture", entityID: captureID, priority: 5)
    }

    // MARK: Vision analysis

    func analyze(captureID: Int64) async throws {
        guard let capture = try store.capture(id: captureID) else { return }
        let s = settings()
        // With no vision model, fall back to a text-only analysis of the OCR output.
        let useVision = !s.visionModel.isEmpty
        let model = useVision ? s.visionModel : s.summaryModel
        guard !model.isEmpty else {
            try store.setAIStatus(captureID: captureID, .skipped)
            return
        }
        try await ai.validate(model: model, role: useVision ? "vision" : "summary")
        try store.setAIStatus(captureID: captureID, .running)

        let previous = try store.captures(from: capture.capturedAt.addingTimeInterval(-15 * 60), to: capture.capturedAt, limit: 3)
            .compactMap { c -> String? in
                guard !c.aiDescription.isEmpty else { return nil }
                return "\(c.applicationName): \(c.aiDescription.clipped(160))"
            }
        let ocr = (s.redactionEnabled ? s.sensitiveRules.redact(capture.ocrText) : capture.ocrText).clipped(3000)
        let user = Prompts.visionUser(app: capture.applicationName, title: capture.windowTitle,
                                      timestamp: Self.localTimestamp(capture.capturedAt, tz: capture.timezone),
                                      ocr: ocr, previous: previous)
        var images: [Data]?
        if useVision {
            images = [try ImageProcessing.jpegForModel(store.paths.absolute(capture.imagePath))]
        }
        do {
            let raw = try await ai.chat(model: model, messages: [
                ChatMessage(role: "system", content: Prompts.visionSystem()),
                ChatMessage(role: "user", content: user, images: images),
            ], schema: ActivityAnalysis.schema)
            let analysis = try ActivityAnalysis.parse(raw)
            let json = String(data: try JSONEncoder().encode(analysis), encoding: .utf8)
            try store.updateAI(captureID: captureID, description: analysis.searchableText, json: json, status: .done)
        } catch let error as AIProviderError where !error.isOutage {
            try store.setAIStatus(captureID: captureID, error.isTransient ? .pending : .failed)
            throw error
        } catch {
            try store.setAIStatus(captureID: captureID, .pending)
            throw error
        }
        try store.enqueueJob(.embedding, entityType: "capture", entityID: captureID, priority: 5)
        try store.enqueueJob(.projectAssociation, entityType: "capture", entityID: captureID, priority: 15)
    }

    // MARK: Embeddings

    static func captureEmbeddingText(_ c: CaptureRecord) -> String {
        [c.applicationName, c.windowTitle, c.aiDescription, c.ocrText.clipped(1500)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func embedCapture(_ id: Int64) async throws {
        let s = settings()
        let model = s.embeddingModel
        guard !model.isEmpty, let capture = try store.capture(id: id) else { return }
        // Redaction applies to everything sent to a provider, not just stored text.
        let raw = Self.captureEmbeddingText(capture)
        let text = s.redactionEnabled ? s.sensitiveRules.redact(raw) : raw
        guard text.count > 3 else { return }
        let vector = try await ai.embed(model: model, inputs: [text])[0]
        try store.saveEmbedding(entityType: "capture", entityID: id, model: s.embeddingIndexKey, vector: VectorMath.normalized(vector),
                                entityTime: capture.capturedAt)
    }

    func embedSession(_ id: Int64) async throws {
        let s = settings()
        let model = s.embeddingModel
        guard !model.isEmpty, let session = try store.session(id: id) else { return }
        let text = [session.title, session.summary, session.projectName ?? "", session.applicationNames.joined(separator: ", ")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let vector = try await ai.embed(model: model, inputs: [text])[0]
        try store.saveEmbedding(entityType: "session", entityID: id, model: s.embeddingIndexKey, vector: VectorMath.normalized(vector),
                                entityTime: session.startedAt)
    }

    // MARK: Projects

    func associateCapture(_ id: Int64) throws {
        guard let capture = try store.capture(id: id) else { return }
        let projects = try store.projects()
        guard !projects.isEmpty else { return }
        let aiProject = capture.aiJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ActivityAnalysis.self, from: $0) }?.project
        let signals = ProjectClassifier.Signals(windowTitles: [capture.windowTitle], text: capture.ocrText + " " + capture.aiDescription,
                                                bundleIdentifiers: [capture.bundleIdentifier], aiProjectNames: aiProject.map { [$0] } ?? [])
        let match = ProjectClassifier().classify(signals, projects: projects)
        // Only set — never clear — automatically; a weak later signal shouldn't undo an earlier strong one.
        if let match, capture.projectID != match.projectID, capture.projectID == nil {
            try store.setCaptureProject(captureID: id, projectID: match.projectID)
        }
    }

    func associateSession(_ id: Int64) throws {
        guard let session = try store.session(id: id), session.projectSource != "user" else { return }
        let captures = try store.captures(inSession: id)
        let projects = try store.projects()
        guard !projects.isEmpty, !captures.isEmpty else { return }
        // Majority vote of capture-level associations, falling back to classifying the whole session text.
        var votes: [Int64: Int] = [:]
        for c in captures { if let p = c.projectID { votes[p, default: 0] += 1 } }
        if let (winner, count) = votes.max(by: { $0.value < $1.value }), Double(count) / Double(captures.count) >= 0.4 {
            let runnerUp = votes.filter { $0.key != winner }.values.max() ?? 0
            if Double(runnerUp) < Double(count) * 0.6 {
                try store.setSessionProject(id: id, projectID: winner, source: "auto", confidence: Double(count) / Double(captures.count))
                return
            }
        }
        let signals = ProjectClassifier.Signals(
            windowTitles: captures.map(\.windowTitle),
            text: captures.prefix(30).map { $0.aiDescription + " " + $0.ocrText.clipped(400) }.joined(separator: "\n") + " " + session.summary,
            bundleIdentifiers: captures.map(\.bundleIdentifier))
        if let match = ProjectClassifier().classify(signals, projects: projects) {
            try store.setSessionProject(id: id, projectID: match.projectID, source: "auto", confidence: match.confidence)
        }
    }

    // MARK: Session summaries

    func summarizeSession(_ id: Int64) async throws {
        let model = settings().summaryModel
        guard !model.isEmpty, let session = try store.session(id: id) else { return }
        try await ai.validate(model: model, role: "summary")
        let captures = try store.captures(inSession: id)
        guard !captures.isEmpty else { return }
        let sampled = Self.sample(captures, max: 40)
        let tz = TimeZone(identifier: captures[0].timezone) ?? .current
        let lines = sampled.map { c -> String in
            let detail = c.aiDescription.isEmpty ? c.ocrText.replacingOccurrences(of: "\n", with: " ").clipped(200) : c.aiDescription.clipped(240)
            return "- \(Self.time(c.capturedAt, tz: tz)) \(c.applicationName) — \(c.windowTitle.clipped(100)) — \(detail)"
        }
        let s = settings()
        let body = (s.redactionEnabled ? s.sensitiveRules.redact(lines.joined(separator: "\n")) : lines.joined(separator: "\n"))
        let user = """
        Session from \(Self.time(session.startedAt, tz: tz)) to \(Self.time(session.endedAt, tz: tz)), \(captures.count) observations.
        Observations:
        \(body)
        """
        let raw = try await ai.chat(model: model, messages: [
            ChatMessage(role: "system", content: Prompts.sessionSystem()),
            ChatMessage(role: "user", content: user),
        ], schema: SessionAnalysis.schema)
        let analysis = try SessionAnalysis.parse(raw)
        try store.applyAISessionResult(id: id, title: analysis.title, summary: analysis.summary, confidence: analysis.confidence)
        try store.enqueueJob(.embedding, entityType: "session", entityID: id, priority: 4)
        try store.enqueueJob(.projectAssociation, entityType: "session", entityID: id, priority: 6)
    }

    static func sample<T>(_ items: [T], max: Int) -> [T] {
        guard items.count > max else { return items }
        let step = Double(items.count - 1) / Double(max - 1)
        return (0..<max).map { items[Int((Double($0) * step).rounded())] }
    }

    static func time(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func localTimestamp(_ date: Date, tz: String) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: tz) ?? .current
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
