import Foundation

public struct GroundedAnswer: Sendable {
    public enum Citation: Sendable, Hashable {
        case capture(Int64)
        case session(Int64)
    }

    public var text: String
    public var citations: [Citation]
    public var sufficientEvidence: Bool

    public init(text: String, citations: [Citation], sufficientEvidence: Bool) {
        self.text = text
        self.citations = citations
        self.sufficientEvidence = sufficientEvidence
    }
}

/// Answers a question strictly from retrieved records. Every claim must cite evidence ids;
/// citations that don't correspond to supplied evidence are stripped, and an answer with no
/// valid citations is reported as insufficient evidence.
public struct GroundedAnswerer: Sendable {
    let ollama: OllamaService
    let model: String
    let rules: SensitiveContentRules?

    public init(ollama: OllamaService, model: String, redactWith rules: SensitiveContentRules?) {
        self.ollama = ollama
        self.model = model
        self.rules = rules
    }

    public static let insufficient = "I couldn't find enough captured evidence to answer that."

    public func answer(question: String, results: SearchResults) async throws -> GroundedAnswer {
        let captures = Array(results.captures.prefix(14))
        let sessions = Array(results.sessions.prefix(6))
        guard !captures.isEmpty || !sessions.isEmpty else {
            return GroundedAnswer(text: Self.insufficient, citations: [], sufficientEvidence: false)
        }
        let f = DateFormatter()
        f.dateFormat = "EEE yyyy-MM-dd HH:mm"
        var evidence: [String] = []
        for s in sessions {
            evidence.append("[S\(s.session.id)] \(f.string(from: s.session.startedAt))–\(f.string(from: s.session.endedAt)) session “\(s.session.title)”"
                + (s.session.summary.isEmpty ? "" : ": \(s.session.summary.clipped(300))")
                + (s.session.projectName.map { " (project: \($0))" } ?? ""))
        }
        for h in captures {
            let c = h.capture
            let detail = c.aiDescription.isEmpty ? c.ocrText.replacingOccurrences(of: "\n", with: " ").clipped(400) : c.aiDescription.clipped(300)
            evidence.append("[C\(c.id)] \(f.string(from: c.capturedAt)) \(c.applicationName) — \(c.windowTitle.clipped(120)) — \(detail)")
        }
        var evidenceText = evidence.joined(separator: "\n")
        if let rules { evidenceText = rules.redact(evidenceText) }
        let now = f.string(from: Date())

        let raw = try await ollama.chat(model: model, messages: [
            ChatMessage(role: "system", content: """
                You answer questions about the user's own computer activity history using ONLY the evidence records given.
                \(Prompts.groundingRules)
                - Cite every factual statement with record ids in square brackets, e.g. [C12] or [S3].
                - If the evidence does not answer the question, reply exactly: INSUFFICIENT_EVIDENCE
                - Be brief: at most 4 sentences. Current time: \(now).
                """),
            ChatMessage(role: "user", content: "Evidence:\n\(evidenceText)\n\nQuestion: \(question)"),
        ], temperature: 0)

        return Self.validate(raw, captureIDs: Set(captures.map(\.capture.id)), sessionIDs: Set(sessions.map(\.session.id)))
    }

    static func validate(_ raw: String, captureIDs: Set<Int64>, sessionIDs: Set<Int64>) -> GroundedAnswer {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("INSUFFICIENT_EVIDENCE") {
            return GroundedAnswer(text: insufficient, citations: [], sufficientEvidence: false)
        }
        var citations: [GroundedAnswer.Citation] = []
        var text = trimmed
        let regex = try! NSRegularExpression(pattern: #"\[([CS])(\d+)\]"#)
        let ns = trimmed as NSString
        for m in regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)).reversed() {
            let kind = ns.substring(with: m.range(at: 1))
            let id = Int64(ns.substring(with: m.range(at: 2))) ?? -1
            let valid = kind == "C" ? captureIDs.contains(id) : sessionIDs.contains(id)
            if valid {
                let c: GroundedAnswer.Citation = kind == "C" ? .capture(id) : .session(id)
                if !citations.contains(c) { citations.insert(c, at: 0) }
            } else if let r = Range(m.range, in: text) {
                // A citation to a record we never supplied is fabricated: remove it.
                text.removeSubrange(r)
            }
        }
        guard !citations.isEmpty else {
            return GroundedAnswer(text: insufficient, citations: [], sufficientEvidence: false)
        }
        return GroundedAnswer(text: text, citations: citations, sufficientEvidence: true)
    }
}
