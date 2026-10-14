import Foundation

/// Deterministic, LLM-free grouping of captures into activity sessions.
///
/// Rules, in order:
/// 1. An interruption (idle, lock, sleep, pause) or a gap longer than `maxGap` always starts a new session.
/// 2. Two different known projects never share a session.
/// 3. A sustained context change (two consecutive captures whose window-title/OCR tokens barely
///    overlap the session's recent vocabulary) starts a new session. A single off-topic capture —
///    a quick glance at chat or mail — stays in the current session.
/// 4. Sessions longer than `maxDuration` split at the next context change, even a weak one.
public struct SessionBuilder: Sendable {
    public struct Config: Sendable {
        public var maxGap: TimeInterval = 5 * 60
        public var maxDuration: TimeInterval = 3 * 60 * 60
        public var similarityThreshold: Double = 0.12
        /// Credit given to each capture beyond its last-seen time (≈ the sampling interval).
        public var sampleCredit: TimeInterval = 30
        public init() {}
    }

    public struct Item: Sendable {
        public var captureID: Int64
        public var start: Date
        public var lastSeen: Date
        public var applicationName: String
        public var windowTitle: String
        public var text: String
        public var projectID: Int64?

        public init(captureID: Int64, start: Date, lastSeen: Date, applicationName: String, windowTitle: String,
                    text: String, projectID: Int64? = nil) {
            self.captureID = captureID
            self.start = start
            self.lastSeen = lastSeen
            self.applicationName = applicationName
            self.windowTitle = windowTitle
            self.text = text
            self.projectID = projectID
        }

        public init(_ capture: CaptureRecord) {
            self.init(captureID: capture.id, start: capture.capturedAt, lastSeen: capture.lastSeenAt,
                      applicationName: capture.applicationName, windowTitle: capture.windowTitle,
                      text: capture.aiDescription + " " + String(capture.ocrText.prefix(2000)), projectID: capture.projectID)
        }

        var tokens: Set<String> {
            // Titles are the strongest signal, so they are weighted by being included in full.
            Set(TextTokens.tokens(windowTitle + " " + applicationName) + TextTokens.tokens(text, limit: 120))
        }
    }

    public struct Group: Sendable {
        /// Existing session id when this group continues the open session.
        public var existingSessionID: Int64?
        public var items: [Item]
        public var start: Date { items.first?.start ?? .distantPast }
        public var end: Date { items.map { max($0.lastSeen, $0.start) }.max() ?? .distantPast }
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    /// Groups `items` (any order), optionally continuing an open session whose recent items are `openItems`.
    public func group(_ items: [Item], openSessionID: Int64? = nil, openItems: [Item] = [], interruptions: [Date] = []) -> [Group] {
        let sorted = items.sorted { $0.start < $1.start }
        let breaks = interruptions.sorted()
        var groups: [Group] = []
        var current = Group(existingSessionID: openSessionID, items: [])
        var context = Set(openItems.suffix(12).flatMap(\.tokens))
        var lastItem = openItems.last
        var sessionStart = openItems.first?.start
        var sessionProject = openItems.last(where: { $0.projectID != nil })?.projectID
        var pendingOffTopic: Item?

        func startNew(with item: Item) {
            if !current.items.isEmpty { groups.append(current) }
            current = Group(existingSessionID: nil, items: [item])
            context = item.tokens
            sessionStart = item.start
            sessionProject = item.projectID
        }

        for item in sorted {
            defer { lastItem = item }
            guard let previous = lastItem, sessionStart != nil else {
                startNew(with: item)
                continue
            }
            let previousEnd = max(previous.lastSeen, previous.start)
            let gap = item.start.timeIntervalSince(previousEnd)
            let interrupted = breaks.contains { $0 > previous.start && $0 <= item.start }
            if interrupted || gap > config.maxGap {
                if let pending = pendingOffTopic { current.items.append(pending); pendingOffTopic = nil }
                startNew(with: item)
                continue
            }
            if let p = item.projectID, let s = sessionProject, p != s {
                if let pending = pendingOffTopic { current.items.append(pending); pendingOffTopic = nil }
                startNew(with: item)
                continue
            }

            let tokens = item.tokens
            let similarity = TextTokens.containment(tokens, in: context)
            let long = item.start.timeIntervalSince(sessionStart!) > config.maxDuration
            let threshold = long ? 0.5 : config.similarityThreshold

            if similarity >= threshold || tokens.isEmpty {
                if let pending = pendingOffTopic { current.items.append(pending); pendingOffTopic = nil }
                current.items.append(item)
                context.formUnion(tokens)
                if sessionProject == nil { sessionProject = item.projectID }
            } else if let pending = pendingOffTopic {
                // Second consecutive off-topic capture: the context really changed.
                // If the two off-topic captures resemble each other, they open the new session together.
                pendingOffTopic = nil
                if TextTokens.jaccard(pending.tokens, tokens) >= config.similarityThreshold || pending.applicationName == item.applicationName {
                    startNew(with: pending)
                    current.items.append(item)
                    context.formUnion(tokens)
                } else {
                    current.items.append(pending)
                    startNew(with: item)
                }
            } else {
                pendingOffTopic = item
            }
        }
        if let pending = pendingOffTopic { current.items.append(pending) }
        if !current.items.isEmpty { groups.append(current) }
        return groups
    }

    /// Union of observed intervals, each extended by `credit` but never across idle gaps.
    public static func activeSeconds(for intervals: [(start: Date, lastSeen: Date)], credit: TimeInterval = 30,
                                     maxGap: TimeInterval = 5 * 60) -> Double {
        let sorted = intervals.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var runStart: Date?
        var runEnd: Date?
        for (index, interval) in sorted.enumerated() {
            var end = max(interval.lastSeen, interval.start).addingTimeInterval(credit)
            if index + 1 < sorted.count {
                let next = sorted[index + 1].start
                // Don't credit time past the next capture, or across a gap that suggests absence.
                if next.timeIntervalSince(interval.lastSeen) <= maxGap { end = min(end, max(next, interval.lastSeen)) }
            }
            if let re = runEnd, interval.start <= re {
                runEnd = max(re, end)
            } else {
                if let rs = runStart, let re = runEnd { total += re.timeIntervalSince(rs) }
                runStart = interval.start
                runEnd = end
            }
        }
        if let rs = runStart, let re = runEnd { total += re.timeIntervalSince(rs) }
        return total
    }

    /// Human-readable title from the most common window title and dominant applications.
    public static func deterministicTitle(for items: [Item]) -> String {
        guard !items.isEmpty else { return "Activity" }
        var appCounts: [String: Int] = [:]
        var titleCounts: [String: Int] = [:]
        for item in items {
            appCounts[item.applicationName, default: 0] += 1
            let title = cleanTitle(item.windowTitle, app: item.applicationName)
            if !title.isEmpty { titleCounts[title, default: 0] += 1 }
        }
        let apps = appCounts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(2).map(\.key)
        let appPart = apps.joined(separator: ", ")
        if let title = titleCounts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key {
            return "\(appPart): \(title.prefix(70))"
        }
        return appPart
    }

    static func cleanTitle(_ title: String, app: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" — \(app)", " - \(app)", " – \(app)"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        return t
    }
}
