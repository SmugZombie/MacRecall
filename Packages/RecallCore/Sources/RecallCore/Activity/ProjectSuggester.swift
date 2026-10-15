import Foundation

/// A project the user hasn't created yet but that recurs in unassigned activity.
public struct ProjectSuggestion: Sendable, Identifiable, Hashable {
    public var name: String
    /// Other spellings seen for the same project ("Mac Recall" for "MacRecall").
    public var aliases: [String]
    public var repositoryPaths: [String]
    public var captureCount: Int
    public var dayCount: Int
    public var lastSeen: Date

    public var id: String { ProjectSuggester.key(name) }
    public var rules: ProjectRules { ProjectRules(aliases: aliases, repositoryPaths: repositoryPaths) }
}

/// Proposes projects from evidence already collected: names the vision model saw on screen and
/// repository folders in window titles and terminal text. Deterministic, so it works without AI;
/// names are only suggested once they recur, and the user decides whether to create them.
public struct ProjectSuggester: Sendable {
    public struct Observation: Sendable {
        public var capturedAt: Date
        public var applicationName: String
        public var windowTitle: String
        /// Project name proposed by the vision model for this capture.
        public var aiProject: String?
        /// Text that may contain repository paths (OCR), or empty.
        public var pathText: String

        public init(capturedAt: Date, applicationName: String, windowTitle: String, aiProject: String?, pathText: String = "") {
            self.capturedAt = capturedAt
            self.applicationName = applicationName
            self.windowTitle = windowTitle
            self.aiProject = aiProject
            self.pathText = pathText
        }
    }

    public var minimumCaptures = 5
    /// Seen on at least this many days, or on fewer with `4 × minimumCaptures` captures.
    public var minimumDays = 2
    public var maximumSuggestions = 8

    public init() {}

    /// Names that describe a context rather than a project.
    static let genericNames: Set<String> = [
        "untitled", "home", "desktop", "documents", "downloads", "personal", "work", "general", "misc", "other",
        "project", "projects", "github", "gitlab", "bitbucket", "google", "macos", "settings", "systemsettings",
        "inbox", "email", "mail", "calendar", "notes", "dashboard", "localhost", "src", "test", "tests", "tmp", "temp",
    ]

    public func suggest(_ observations: [Observation], existing: [ProjectRecord], dismissed: Set<String> = [],
                        calendar: Calendar = .current) -> [ProjectSuggestion] {
        struct Candidate {
            var spellings: [String: Int] = [:]
            var aiSpellings: [String: Int] = [:]
            var paths: Set<String> = []
            var captures = 0
            var days: Set<DateComponents> = []
            var lastSeen = Date.distantPast
        }

        let excluded = Self.existingKeys(existing).union(dismissed)
            .union(Set(observations.map { Self.key($0.applicationName) }))
            .union(Self.genericNames)
        let existingPaths = Set(existing.flatMap(\.rules.repositoryPaths).map { $0.lowercased() })

        var candidates: [String: Candidate] = [:]
        for o in observations {
            var seen: [String: (spelling: String, fromAI: Bool, path: String?)] = [:]
            for repo in Self.repositories(in: o.windowTitle + "\n" + o.pathText)
            where !existingPaths.contains(repo.path.lowercased()) {
                seen[Self.key(repo.name)] = (repo.name, false, repo.path)
            }
            if let ai = o.aiProject?.trimmingCharacters(in: .whitespacesAndNewlines), !ai.isEmpty {
                let k = Self.key(ai)
                seen[k] = (ai, true, seen[k]?.path)
            }
            for (k, hit) in seen where k.count >= 2 && !excluded.contains(k) {
                var c = candidates[k, default: Candidate()]
                if hit.fromAI { c.aiSpellings[hit.spelling, default: 0] += 1 } else { c.spellings[hit.spelling, default: 0] += 1 }
                if let path = hit.path { c.paths.insert(path) }
                c.captures += 1
                c.days.insert(calendar.dateComponents([.year, .month, .day], from: o.capturedAt))
                c.lastSeen = max(c.lastSeen, o.capturedAt)
                candidates[k] = c
            }
        }

        return candidates.values
            .filter { $0.captures >= minimumCaptures && ($0.days.count >= minimumDays || $0.captures >= minimumCaptures * 4) }
            .map { c -> ProjectSuggestion in
                // Prefer how the project is written on screen over its folder name; a matching folder name breaks ties.
                let pool = c.aiSpellings.isEmpty ? c.spellings : c.aiSpellings
                let votes = pool.map { ($0.key, $0.value + (c.aiSpellings.isEmpty ? 0 : c.spellings[$0.key] ?? 0)) }
                let name = votes.sorted { ($0.1, $1.0) > ($1.1, $0.0) }[0].0
                let aliases = Set(c.spellings.keys).union(c.aiSpellings.keys)
                    .filter { $0.lowercased() != name.lowercased() }
                return ProjectSuggestion(name: name, aliases: aliases.sorted(), repositoryPaths: c.paths.sorted(),
                                         captureCount: c.captures, dayCount: c.days.count, lastSeen: c.lastSeen)
            }
            .sorted { ($0.dayCount, $0.captureCount, $1.name) > ($1.dayCount, $1.captureCount, $0.name) }
            .prefix(maximumSuggestions)
            .map { $0 }
    }

    /// Case- and punctuation-insensitive identity: "Mac Recall", "mac-recall" and "MacRecall" are one project.
    public static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func existingKeys(_ projects: [ProjectRecord]) -> Set<String> {
        var keys: Set<String> = []
        for p in projects {
            for name in [p.name] + p.rules.aliases + p.rules.keywords { keys.insert(key(name)) }
            for path in p.rules.repositoryPaths {
                if let last = path.split(separator: "/").last { keys.insert(key(String(last))) }
            }
        }
        keys.remove("")
        return keys
    }

    private static let repositoryPattern = try! NSRegularExpression(
        pattern: #"(?:~|/Users/[^/\s]+)/((?:github|gitlab|git|src|source|projects|developer|code|repos|repositories|dev|workspace|work)/[A-Za-z0-9][A-Za-z0-9._-]*)"#,
        options: [.caseInsensitive])

    /// Folders directly under a conventional code directory, e.g. `~/Github/MacRecall/...` → ("MacRecall", "~/Github/MacRecall").
    static func repositories(in text: String) -> [(name: String, path: String)] {
        let ns = text as NSString
        var result: [(String, String)] = []
        var seen: Set<String> = []
        for m in repositoryPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var relative = ns.substring(with: m.range(at: 1))
            while relative.hasSuffix(".") { relative.removeLast() }
            if relative.lowercased().hasSuffix(".git") { relative.removeLast(4) }
            guard let name = relative.split(separator: "/").last.map(String.init), !name.isEmpty,
                  seen.insert(relative.lowercased()).inserted else { continue }
            result.append((name, "~/" + relative))
        }
        return result
    }
}
