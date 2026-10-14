import Foundation

/// Structured description of one screenshot, as returned by the vision model.
public struct ActivityAnalysis: Codable, Sendable, Equatable {
    public var activity: String
    public var description: String
    public var project: String?
    public var applications: [String]
    public var topics: [String]
    public var confidence: Double

    public static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "activity": ["type": "string", "description": "Short category, e.g. 'Backend development'"],
            "description": ["type": "string", "description": "One or two sentences describing only what is visible"],
            "project": ["type": ["string", "null"], "description": "Project name only if clearly visible, else null"],
            "applications": ["type": "array", "items": ["type": "string"]],
            "topics": ["type": "array", "items": ["type": "string"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
        ],
        "required": ["activity", "description", "applications", "topics", "confidence"],
    ]

    /// Parses and sanity-checks model output. Invalid output never reaches the database.
    public static func parse(_ raw: String) throws -> ActivityAnalysis {
        guard let data = Self.extractJSON(raw).data(using: .utf8) else { throw AIProviderError.invalidResponse("not UTF-8") }
        var value: ActivityAnalysis
        do {
            value = try JSONDecoder().decode(ActivityAnalysis.self, from: data)
        } catch {
            throw AIProviderError.invalidResponse("does not match schema")
        }
        value.activity = value.activity.trimmingCharacters(in: .whitespacesAndNewlines).clipped(80)
        value.description = value.description.trimmingCharacters(in: .whitespacesAndNewlines).clipped(600)
        value.project = value.project?.trimmingCharacters(in: .whitespacesAndNewlines).clipped(60)
        if let p = value.project, p.isEmpty || ["null", "none", "unknown", "n/a"].contains(p.lowercased()) { value.project = nil }
        value.applications = Array(value.applications.prefix(8).map { $0.clipped(60) })
        value.topics = Array(value.topics.prefix(12).map { $0.clipped(60) })
        value.confidence = min(1, max(0, value.confidence.isFinite ? value.confidence : 0))
        guard !value.activity.isEmpty, !value.description.isEmpty else { throw AIProviderError.invalidResponse("empty fields") }
        return value
    }

    /// Some models wrap JSON in prose or code fences despite the format constraint.
    static func extractJSON(_ raw: String) -> String {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return raw }
        return String(raw[start...end])
    }

    public var searchableText: String {
        ([activity, description, project ?? ""] + topics).filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

public struct SessionAnalysis: Codable, Sendable, Equatable {
    public var title: String
    public var summary: String
    public var project: String?
    public var confidence: Double

    public static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "project": ["type": ["string", "null"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
        ],
        "required": ["title", "summary", "confidence"],
    ]

    public static func parse(_ raw: String) throws -> SessionAnalysis {
        guard let data = ActivityAnalysis.extractJSON(raw).data(using: .utf8),
              var value = try? JSONDecoder().decode(SessionAnalysis.self, from: data) else {
            throw AIProviderError.invalidResponse("does not match schema")
        }
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines).clipped(90)
        value.summary = value.summary.trimmingCharacters(in: .whitespacesAndNewlines).clipped(1500)
        value.confidence = min(1, max(0, value.confidence.isFinite ? value.confidence : 0))
        guard !value.title.isEmpty else { throw AIProviderError.invalidResponse("empty title") }
        return value
    }
}

enum Prompts {
    static let groundingRules = """
    Rules:
    - Describe only what is visible in the provided evidence. Do not guess intentions or outcomes.
    - Never claim a problem was solved, a task finished, or an action taken unless the evidence shows it.
    - If something is unclear, say so and lower your confidence.
    - Do not repeat secrets, passwords, tokens or keys even if visible.
    """

    static func visionSystem() -> String {
        """
        You analyze a single screenshot of one application window from the user's own Mac to build a private activity log.
        \(groundingRules)
        Respond with JSON only.
        """
    }

    static func visionUser(app: String, title: String, timestamp: String, ocr: String, previous: [String]) -> String {
        var text = """
        Application: \(app)
        Window title: \(title)
        Time: \(timestamp)
        """
        if !previous.isEmpty {
            text += "\nPreceding activity (context only, may be unrelated):\n" + previous.map { "- \($0)" }.joined(separator: "\n")
        }
        if !ocr.isEmpty { text += "\nText recognized on screen (may contain OCR errors):\n\"\"\"\n\(ocr)\n\"\"\"" }
        text += "\nDescribe what the user is looking at or working on."
        return text
    }

    static func sessionSystem() -> String {
        """
        You summarize a period of computer activity from a chronological list of observed screenshots.
        \(groundingRules)
        - The title is at most 8 words. The summary is 1–3 sentences.
        Respond with JSON only.
        """
    }
}

extension String {
    func clipped(_ max: Int) -> String { count > max ? String(prefix(max)) : self }
}
