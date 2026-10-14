import Foundation

/// Rule-based project association. Ambiguous matches are left unclassified rather than guessed.
public struct ProjectClassifier: Sendable {
    public struct Signals: Sendable {
        public var windowTitles: [String]
        public var text: String
        public var bundleIdentifiers: [String]
        /// Project name proposed by the AI model, if any. Treated as a hint, never as truth.
        public var aiProjectNames: [String]

        public init(windowTitles: [String], text: String, bundleIdentifiers: [String], aiProjectNames: [String] = []) {
            self.windowTitles = windowTitles
            self.text = text
            self.bundleIdentifiers = bundleIdentifiers
            self.aiProjectNames = aiProjectNames
        }
    }

    public struct Match: Sendable, Equatable {
        public var projectID: Int64
        public var score: Double
        public var confidence: Double
    }

    public var minimumScore: Double = 3
    /// The runner-up must score below this fraction of the winner for an unambiguous match.
    public var ambiguityRatio: Double = 0.7

    public init() {}

    public func classify(_ signals: Signals, projects: [ProjectRecord]) -> Match? {
        let titles = signals.windowTitles.joined(separator: "\n").lowercased()
        let text = signals.text.lowercased()
        let aiNames = Set(signals.aiProjectNames.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let bundles = Set(signals.bundleIdentifiers)

        var scored: [(Int64, Double)] = []
        for project in projects {
            var score = 0.0
            let names = [project.name] + project.rules.aliases
            for name in names where !name.isEmpty {
                let n = name.lowercased()
                if Self.containsWord(titles, n) { score += 4 }
                if Self.containsWord(text, n) { score += 2 }
                if aiNames.contains(n) { score += 2 }
            }
            for path in project.rules.repositoryPaths where !path.isEmpty {
                let p = path.lowercased()
                if titles.contains(p) || text.contains(p) { score += 5 }
                else if let last = p.split(separator: "/").last, Self.containsWord(titles, String(last)) { score += 3 }
            }
            for domain in project.rules.domains where !domain.isEmpty {
                if titles.contains(domain.lowercased()) || text.contains(domain.lowercased()) { score += 4 }
            }
            for keyword in project.rules.keywords where !keyword.isEmpty {
                let k = keyword.lowercased()
                if Self.containsWord(titles, k) { score += 2 } else if Self.containsWord(text, k) { score += 1 }
            }
            if !project.rules.bundleIdentifiers.isEmpty, !bundles.isDisjoint(with: project.rules.bundleIdentifiers) {
                score += 0.5
            }
            if score > 0 { scored.append((project.id, score)) }
        }
        scored.sort { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= minimumScore else { return nil }
        if scored.count > 1, scored[1].1 >= best.1 * ambiguityRatio { return nil }
        let runnerUp = scored.count > 1 ? scored[1].1 : 0
        let confidence = min(0.99, 0.5 + (best.1 - runnerUp) / (best.1 + 6))
        return Match(projectID: best.0, score: best.1, confidence: confidence)
    }

    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            let beforeOK = range.lowerBound == haystack.startIndex || !haystack[haystack.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == haystack.endIndex || !haystack[range.upperBound].isLetter
            if beforeOK && afterOK { return true }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return false
    }
}
