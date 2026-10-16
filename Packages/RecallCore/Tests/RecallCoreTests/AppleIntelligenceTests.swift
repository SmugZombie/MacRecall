import Foundation
import Testing
@testable import RecallCore

@Suite struct AppleIntelligenceTests {
    static let available = AppleIntelligenceProvider.unavailabilityReason == nil

    @Test func selectingItPicksItsModelsAndStaysLocal() {
        var s = RecallSettings()
        s.aiProvider = .appleIntelligence
        #expect(s.summaryModel == AppleIntelligenceProvider.languageModel)
        #expect(s.embeddingModel == AppleIntelligenceProvider.embeddingModel)
        #expect(s.visionModel.isEmpty)
        #expect(!s.providerIsRemote)
        #expect(s.aiTransmissionAllowed)
        #expect(s.unconfiguredJobTypes.isEmpty)
        #expect(s.embeddingIndexKey == "appleIntelligence/apple-nl-latin")
        #expect(s.makeProvider().kind == .appleIntelligence)

        // A cleared choice stays cleared.
        s.summaryModel = ""
        #expect(s.summaryModel.isEmpty)
        // Other providers still start with nothing chosen.
        s.aiProvider = .openAI
        #expect(s.summaryModel.isEmpty)
    }

    @Test func refusesImagesAndUnknownModels() async {
        let provider = AppleIntelligenceProvider()
        await #expect(throws: AIProviderError.self) { try await provider.validate(model: "anything", role: "vision") }
        await #expect(throws: AIProviderError.modelUnavailable("llama3")) { try await provider.validate(model: "llama3", role: "summary") }
        await #expect(throws: AIProviderError.self) {
            _ = try await provider.chat(model: AppleIntelligenceProvider.languageModel,
                                        messages: [ChatMessage(role: "user", content: "hi", images: [Data([1])])])
        }
    }

    @Test func longPromptsKeepTheirStartAndEnd() {
        let text = "START " + String(repeating: "x", count: 20_000) + " Question: what did I do?"
        let trimmed = AppleIntelligenceProvider.trimMiddle(text, to: 2500)
        #expect(trimmed.count == 2500)
        #expect(trimmed.hasPrefix("START "))
        #expect(trimmed.hasSuffix("Question: what did I do?"))
        #expect(trimmed.contains("shortened to fit"))
        #expect(AppleIntelligenceProvider.trimMiddle("short", to: 2500) == "short")
    }

    @Test func recallsSchemasConvert() throws {
        guard #available(macOS 26.0, *) else { return }
        #if canImport(FoundationModels)
        _ = try AppleIntelligenceProvider.generationSchema(ActivityAnalysis.schema)
        _ = try AppleIntelligenceProvider.generationSchema(SessionAnalysis.schema)
        #endif
    }

    // These run the real on-device models when Apple Intelligence is on.

    @Test(.enabled(if: available)) func summarizesIntoRecallsSchema() async throws {
        let raw = try await AppleIntelligenceProvider().chat(model: AppleIntelligenceProvider.languageModel, messages: [
            ChatMessage(role: "system", content: Prompts.sessionSystem()),
            ChatMessage(role: "user", content: """
                Session from 10:00 to 10:20, 3 observations.
                Observations:
                - 10:00 Xcode — RecallStore+Notes.swift — editing note storage code
                - 10:10 Terminal — swift test — 167 tests passed
                - 10:20 Safari — GitHub pull request "Add notes" — reviewing the diff
                """),
        ], schema: SessionAnalysis.schema)
        let analysis = try SessionAnalysis.parse(raw)
        #expect(!analysis.title.isEmpty)
        #expect(!analysis.summary.isEmpty)
    }

    @Test(.enabled(if: available)) func analyzesAScreenFromItsText() async throws {
        let raw = try await AppleIntelligenceProvider().chat(model: AppleIntelligenceProvider.languageModel, messages: [
            ChatMessage(role: "system", content: Prompts.visionSystem()),
            ChatMessage(role: "user", content: Prompts.visionUser(app: "Terminal", title: "zsh", timestamp: "Thursday 2026-10-15 10:00",
                                                                  ocr: "psql: error: connection to server at \"db\" (10.0.0.5), port 5432 failed: Connection refused",
                                                                  previous: [])),
        ], schema: ActivityAnalysis.schema)
        let analysis = try ActivityAnalysis.parse(raw)
        #expect(!analysis.description.isEmpty)
    }

    @Test(.enabled(if: available)) func oversizedPromptsAreShortenedToFit() async throws {
        // A long day of facts (roughly 12,000 tokens of screen text) still gets an answer.
        let lines = (0..<400).map { "- 09:\(String(format: "%02d", $0 % 60)) Terminal — build log line \($0): compiling module RecallCore target arm64" }
        let answer = try await AppleIntelligenceProvider().chat(model: AppleIntelligenceProvider.languageModel, messages: [
            ChatMessage(role: "system", content: "Answer in one short sentence using only the facts."),
            ChatMessage(role: "user", content: "Facts:\n" + lines.joined(separator: "\n") + "\n\nQuestion: which app was used?"),
        ])
        #expect(!answer.isEmpty)
    }

    @Test(.enabled(if: available)) func embeddingsPlaceRelatedTextCloser() async throws {
        let vectors = try await AppleIntelligenceProvider().embed(model: AppleIntelligenceProvider.embeddingModel, inputs: [
            "Debugging a PostgreSQL connection refused error in the terminal",
            "The database server rejected the connection",
            "A recipe for chocolate chip cookies",
        ])
        #expect(vectors.count == 3)
        #expect(vectors.allSatisfy { $0.count == 512 })
        let v = vectors.map(VectorMath.normalized)
        func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(cosine(v[0], v[1]) > cosine(v[0], v[2]))
    }
}
