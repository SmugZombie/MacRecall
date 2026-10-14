import AppKit
import Foundation
import Testing
@testable import RecallCore

/// Exercises the post-capture pipeline end to end with real Vision OCR: no screen capture, no Ollama.
@Suite struct PipelineTests {
    func renderText(_ lines: [String]) -> CGImage {
        let width = 1200, height = 120 + lines.count * 44
        return ImageProcessing.draw(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular), .foregroundColor: NSColor.black]
            for (i, line) in lines.enumerated() {
                NSAttributedString(string: line, attributes: attrs).draw(at: CGPoint(x: 30, y: height - 70 - i * 44))
            }
            NSGraphicsContext.restoreGraphicsState()
        }!
    }

    @Test func ocrStoreSessionSearchSummary() async throws {
        let store = try makeStore()
        let settings = RecallSettings()
        let base = Date().addingTimeInterval(-3600)

        // Write a real image, as the capture coordinator would, and OCR it through the job processor.
        let image = renderText(["$ psql -h db.internal", "psql: error: connection refused", "export AWS_SECRET=AKIAABCDEFGHIJKLMNOP"])
        let (imageRel, thumbRel) = CaptureCoordinator.relativePaths(for: base, format: .heic)
        try ImageProcessing.writeAtomically(try ImageProcessing.encode(image, format: .heic, quality: 0.6), to: store.paths.absolute(imageRel))
        try ImageProcessing.writeAtomically(try ImageProcessing.encode(image, format: .jpeg, quality: 0.6), to: store.paths.absolute(thumbRel))
        let capture = try store.insertCapture(NewCapture(
            bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal", pid: 1, systemWindowID: 7,
            windowTitle: "truesoc — zsh", capturedAt: base, imagePath: imageRel, thumbnailPath: thumbRel,
            imageHash: "", width: image.width, height: image.height))
        try store.enqueueJob(.ocr, entityType: "capture", entityID: capture.id)

        let processor = JobProcessor(store: store, ollama: OllamaService(endpoint: "http://127.0.0.1:1"), settings: { settings })
        let job = try #require(try store.claimJobs(types: [.ocr], limit: 1).first)
        try await processor.process(job)
        try store.completeJob(id: job.id)

        let ocred = try #require(try store.capture(id: capture.id))
        #expect(ocred.ocrStatus == .done)
        #expect(ocred.ocrText.lowercased().contains("connection refused"))
        // Redaction applied to stored text.
        #expect(!ocred.ocrText.contains("AKIAABCDEFGHIJKLMNOP"))
        // OCR completion schedules downstream work.
        #expect(try store.queueCounts().byType[.projectAssociation] == 1)

        // A second, related capture a minute later, then sessionize.
        try addCapture(store, title: "truesoc — zsh", at: base.addingTimeInterval(60), ocr: "psql connection refused db.internal truesoc")
        let grouped = try ActivitySessionManager(store: store).update(now: base.addingTimeInterval(600))
        #expect(grouped == 2)
        let sessions = try store.sessions(from: base.addingTimeInterval(-1), to: base.addingTimeInterval(3600))
        #expect(sessions.count == 1)
        #expect(sessions[0].captureCount == 2)

        // Keyword search through the hybrid path (no Ollama) finds it and filters by app.
        let search = HybridSearch(store: store, ollama: nil, embeddingModel: "")
        let results = try await search.search("Find the terminal where I saw connection refused")
        #expect(results.captures.first?.capture.id == capture.id || results.captures.contains { $0.capture.id == capture.id })
        #expect(results.interpretation.applicationNames == ["Terminal"])
        #expect(!results.semanticUsed)
        #expect(!results.sessions.isEmpty)

        // Deterministic daily summary with grounded issue references.
        let key = DailySummaryService.dayKey(for: base)
        let summary = try await DailySummaryService(store: store, ollama: nil, settings: { settings }).generate(dayKey: key)
        #expect(summary.summary.contains("Terminal"))
        #expect(summary.summary.contains("[capture \(capture.id)]") || summary.summary.contains("[session"))
        #expect(!summary.summary.contains("Overview"))

        // Retention removes the files too.
        _ = try RetentionManager(store: store).enforce(retentionDays: 1, now: base.addingTimeInterval(3 * 86400))
        #expect(try store.storageStats().captureCount == 0)
        #expect(!FileManager.default.fileExists(atPath: store.paths.absolute(imageRel).path))
    }

    @Test func aiJobsWaitWhileOllamaIsDown() async throws {
        let store = try makeStore()
        var settings = RecallSettings()
        settings.summaryModel = "llama3.2"
        let c = try addCapture(store, at: Date(), ocr: "hello")
        try store.enqueueJob(.visionAnalysis, entityType: "capture", entityID: c.id)
        let processor = JobProcessor(store: store, ollama: OllamaService(endpoint: "http://127.0.0.1:1", timeout: 2), settings: { settings })
        let job = try #require(try store.claimJobs(types: [.visionAnalysis], limit: 1).first)
        await #expect(throws: OllamaError.self) { try await processor.process(job) }
        do { try await processor.process(job) } catch let error as OllamaError {
            #expect(error.isOutage)
        }
        // Capture data is intact and still awaiting analysis.
        #expect(try store.capture(id: c.id)?.aiStatus == .pending)
    }
}
