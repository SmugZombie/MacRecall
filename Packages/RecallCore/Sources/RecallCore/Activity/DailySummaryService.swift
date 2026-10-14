import Foundation

/// Builds a Markdown summary of one local day from observed sessions.
///
/// The factual sections (time, projects, apps, issues, transitions) are computed deterministically.
/// When a summary model is configured, a short narrative overview is added, generated only from
/// those facts and clearly labelled as AI-written.
public struct DailySummaryService: Sendable {
    let store: RecallStore
    let ai: (any AIProvider)?
    let settings: @Sendable () -> RecallSettings

    public init(store: RecallStore, ai: (any AIProvider)?, settings: @escaping @Sendable () -> RecallSettings) {
        self.store = store
        self.ai = ai
        self.settings = settings
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> Int64 {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return Int64(c.year! * 10000 + c.month! * 100 + c.day!)
    }

    public static func dayRange(for key: Int64, calendar: Calendar = .current) -> (Date, Date)? {
        let comps = DateComponents(year: Int(key / 10000), month: Int(key / 100 % 100), day: Int(key % 100))
        guard let start = calendar.date(from: comps), let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    public static func localDateString(_ key: Int64) -> String {
        String(format: "%04d-%02d-%02d", key / 10000, key / 100 % 100, key % 100)
    }

    public struct Facts: Sendable {
        public var observedSeconds: Double = 0
        public var estimatedSeconds: Double = 0
        public var byProject: [(String, Double)] = []
        public var byApp: [(String, Double)] = []
        public var unclassifiedSeconds: Double = 0
        public var sessions: [SessionRecord] = []
        public var issues: [(String, Int64)] = []
        public var captureCount = 0
    }

    public func facts(for key: Int64) throws -> Facts {
        guard let (start, end) = Self.dayRange(for: key) else { return Facts() }
        var facts = Facts()
        let credit = settings().captureInterval
        facts.sessions = try store.sessions(from: start, to: end, ascending: true, limit: 1000)

        var appIntervals: [String: [(start: Date, lastSeen: Date)]] = [:]
        var allIntervals: [(start: Date, lastSeen: Date)] = []
        var offset = 0
        var issueSet: Set<String> = []
        while true {
            let page = try store.captures(from: start, to: end, ascending: true, limit: 1000, offset: offset)
            if page.isEmpty { break }
            offset += page.count
            for c in page {
                let interval = (start: c.capturedAt, lastSeen: min(c.lastSeenAt, end))
                appIntervals[c.applicationName, default: []].append(interval)
                allIntervals.append(interval)
                facts.observedSeconds += max(0, interval.lastSeen.timeIntervalSince(interval.start))
                if facts.issues.count < 8 {
                    for line in c.ocrText.split(separator: "\n") where Self.looksLikeIssue(line) {
                        let text = String(line.trimmingCharacters(in: .whitespaces).prefix(140))
                        if issueSet.insert(text.lowercased()).inserted { facts.issues.append((text, c.id)) }
                        break
                    }
                }
            }
        }
        facts.captureCount = allIntervals.count
        facts.estimatedSeconds = SessionBuilder.activeSeconds(for: allIntervals, credit: credit)
        facts.byApp = appIntervals.map { ($0.key, SessionBuilder.activeSeconds(for: $0.value, credit: credit)) }
            .sorted { $0.1 > $1.1 }

        var projects: [String: Double] = [:]
        for s in facts.sessions {
            if let name = s.projectName { projects[name, default: 0] += s.activeSeconds } else { facts.unclassifiedSeconds += s.activeSeconds }
        }
        facts.byProject = projects.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        return facts
    }

    static func looksLikeIssue<S: StringProtocol>(_ line: S) -> Bool {
        let l = line.lowercased()
        guard l.count >= 12 else { return false }
        return ["error:", "error ", "exception", "failed", "fatal", "traceback", "denied", "refused", "timed out", "panic:"]
            .contains { l.contains($0) }
    }

    public func markdown(for key: Int64, facts: Facts, narrative: String?) -> String {
        var md = "# Daily summary — \(Self.localDateString(key))\n\n"
        if facts.captureCount == 0 { return md + "_No activity was captured on this day._\n" }
        if let narrative, !narrative.isEmpty {
            md += "## Overview _(AI-generated from the facts below)_\n\n\(narrative)\n\n"
        }
        md += "## Time\n\n"
        md += "- Estimated active time: **\(Self.duration(facts.estimatedSeconds))** (sampled every \(Int(settings().captureInterval))s; gaps over the idle timeout excluded)\n"
        md += "- Directly observed (unchanged screens seen repeatedly): \(Self.duration(facts.observedSeconds))\n"
        md += "- Screenshots: \(facts.captureCount), sessions: \(facts.sessions.count)\n\n"
        if !facts.byProject.isEmpty || facts.unclassifiedSeconds > 0 {
            md += "## Projects\n\n"
            for (name, secs) in facts.byProject { md += "- \(name): \(Self.duration(secs))\n" }
            if facts.unclassifiedSeconds > 0 { md += "- _Unclassified_: \(Self.duration(facts.unclassifiedSeconds))\n" }
            md += "\n"
        }
        md += "## Applications\n\n"
        for (name, secs) in facts.byApp.prefix(10) { md += "- \(name): \(Self.duration(secs))\n" }
        md += "\n## Activity\n\n"
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        for s in facts.sessions {
            let project = s.projectName.map { " · \($0)" } ?? ""
            md += "- \(f.string(from: s.startedAt))–\(f.string(from: s.endedAt)) **\(s.title)**\(project) [session \(s.id)]\n"
            if !s.summary.isEmpty { md += "  \(s.summary)\n" }
        }
        if !facts.issues.isEmpty {
            md += "\n## Observed issues\n\n"
            for (text, id) in facts.issues { md += "- `\(text.replacingOccurrences(of: "`", with: "'"))` [capture \(id)]\n" }
        }
        return md
    }

    @discardableResult
    public func generate(dayKey key: Int64) async throws -> DailySummaryRecord {
        let facts = try facts(for: key)
        var narrative: String?
        let s = settings()
        if let ai, !s.summaryModel.isEmpty, facts.captureCount > 0 {
            let factsText = markdown(for: key, facts: facts, narrative: nil)
            let redacted = s.redactionEnabled ? s.sensitiveRules.redact(factsText) : factsText
            narrative = try await ai.chat(model: s.summaryModel, messages: [
                ChatMessage(role: "system", content: """
                    You write a 2–4 sentence overview of a person's workday using ONLY the facts provided.
                    \(Prompts.groundingRules)
                    Do not invent projects, times or outcomes. Plain prose, no headings.
                    """),
                ChatMessage(role: "user", content: redacted),
            ]).trimmingCharacters(in: .whitespacesAndNewlines).clipped(1200)
        }
        let record = DailySummaryRecord(localDate: Self.localDateString(key), timezone: TimeZone.current.identifier,
                                        summary: markdown(for: key, facts: facts, narrative: narrative), generatedAt: Date())
        try store.saveDailySummary(record)
        return record
    }

    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}
