import Foundation

/// Structured filters extracted from a natural-language query, without an LLM.
public struct QueryInterpretation: Sendable, Equatable {
    public var range: DateInterval?
    public var rangeDescription: String?
    public var applicationNames: [String]
    public var keywords: [String]
    public var quotedPhrases: [String]
    public var wantsLatest: Bool

    public var keywordText: String { (quotedPhrases.map { "\"\($0)\"" } + keywords).joined(separator: " ") }
}

public struct QueryInterpreter: Sendable {
    public var calendar: Calendar
    public var now: Date
    public var knownApplications: [String]

    public init(calendar: Calendar = .current, now: Date = Date(), knownApplications: [String] = []) {
        self.calendar = calendar
        self.now = now
        self.knownApplications = knownApplications
    }

    static let appCategories: [String: [String]] = [
        "terminal": ["Terminal", "iTerm2", "iTerm", "Warp", "Ghostty", "Alacritty", "kitty", "WezTerm"],
        "browser": ["Safari", "Google Chrome", "Firefox", "Arc", "Microsoft Edge", "Brave Browser", "Chromium", "Orion"],
        "editor": ["Visual Studio Code", "Code", "Cursor", "Xcode", "Zed", "Sublime Text", "Nova", "IntelliJ IDEA", "PyCharm", "GoLand", "BBEdit"],
        "vs code": ["Visual Studio Code", "Code"], "vscode": ["Visual Studio Code", "Code"],
        "chat": ["Slack", "Messages", "Discord", "Microsoft Teams", "Telegram", "WhatsApp"],
        "email": ["Mail", "Outlook", "Microsoft Outlook", "Spark", "Mimestream"], "mail": ["Mail", "Outlook", "Microsoft Outlook"],
    ]

    static let fillerWords: Set<String> = [
        "when", "was", "were", "what", "where", "which", "who", "how", "did", "do", "does", "i", "me", "my", "we", "the", "a", "an",
        "find", "show", "search", "look", "looking", "for", "of", "on", "in", "at", "to", "that", "this", "those", "these", "it",
        "is", "am", "are", "be", "been", "working", "work", "worked", "use", "used", "using", "saw", "see", "seen", "time", "last",
        "screenshot", "screenshots", "screen", "with", "about", "and", "or", "any", "some", "there", "had", "have", "has", "from",
        "today", "yesterday", "week", "month", "morning", "afternoon", "evening", "tonight", "lunch", "before", "after", "ago",
        "day", "days", "hour", "hours", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "earlier",
        "recently", "recent", "latest", "previous", "page", "window", "app", "application", "where", "doing", "anything",
    ]

    public func interpret(_ query: String) -> QueryInterpretation {
        let lower = query.lowercased()
        var quoted: [String] = []
        if let regex = try? NSRegularExpression(pattern: "\"([^\"]+)\"") {
            for m in regex.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
                if let r = Range(m.range(at: 1), in: query) { quoted.append(String(query[r])) }
            }
        }
        let (range, description) = resolveRange(lower)
        let apps = resolveApplications(lower)
        let appWords = Set(apps.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
            .union(Self.appCategories.keys.filter { lower.contains($0) })
        let unquoted = lower.replacingOccurrences(of: "\"[^\"]*\"", with: " ", options: .regularExpression)
        var keywords: [String] = []
        for raw in unquoted.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/") }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".-/"))
            guard word.count >= 2, !Self.fillerWords.contains(word), !appWords.contains(word), !word.allSatisfy(\.isNumber) else { continue }
            if !keywords.contains(word) { keywords.append(word) }
        }
        let wantsLatest = ["last time", "most recent", "latest"].contains { lower.contains($0) }
        return QueryInterpretation(range: range, rangeDescription: description, applicationNames: apps,
                                   keywords: keywords, quotedPhrases: quoted, wantsLatest: wantsLatest)
    }

    func resolveApplications(_ lower: String) -> [String] {
        var result: [String] = []
        for (key, names) in Self.appCategories where Self.containsWord(lower, key) {
            result += names.filter { n in knownApplications.isEmpty || knownApplications.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }
        }
        for app in knownApplications where app.count >= 3 && Self.containsWord(lower, app.lowercased()) {
            result.append(app)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.lowercased()).inserted }
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
    }

    func resolveRange(_ lower: String) -> (DateInterval?, String?) {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        var base: DateInterval?
        var label: String?

        if Self.containsWord(lower, "today") || lower.contains("this morning") || lower.contains("this afternoon") || lower.contains("tonight") {
            base = DateInterval(start: today, end: day(1)); label = "today"
        } else if Self.containsWord(lower, "yesterday") {
            base = DateInterval(start: day(-1), end: today); label = "yesterday"
        } else if lower.contains("last week") || lower.contains("previous week") {
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
            base = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: thisWeek.start)!, end: thisWeek.start); label = "last week"
        } else if lower.contains("this week") {
            base = DateInterval(start: calendar.dateInterval(of: .weekOfYear, for: now)!.start, end: day(1)); label = "this week"
        } else if lower.contains("this month") {
            base = DateInterval(start: calendar.dateInterval(of: .month, for: now)!.start, end: day(1)); label = "this month"
        } else if let match = lower.range(of: #"(last|past) (\d+) (day|days|hour|hours|week|weeks)"#, options: .regularExpression) {
            let parts = lower[match].split(separator: " ")
            let n = Int(parts[1]) ?? 1
            let unit = parts[2]
            let seconds = unit.hasPrefix("hour") ? 3600.0 : unit.hasPrefix("week") ? 7 * 86400.0 : 86400.0
            base = DateInterval(start: now.addingTimeInterval(-Double(n) * seconds), end: now); label = String(lower[match])
        } else if let match = lower.range(of: #"(\d+) (day|days|week|weeks) ago"#, options: .regularExpression) {
            let parts = lower[match].split(separator: " ")
            let n = Int(parts[0]) ?? 1
            let days = parts[1].hasPrefix("week") ? n * 7 : n
            base = parts[1].hasPrefix("week")
                ? DateInterval(start: day(-days - 3), end: day(-days + 4))
                : DateInterval(start: day(-days), end: day(-days + 1))
            label = String(lower[match])
        } else if let weekday = Self.weekdays.first(where: { Self.containsWord(lower, $0.key) }) {
            // "last tuesday" / "on tuesday": the most recent such day strictly before today.
            let current = calendar.component(.weekday, from: today)
            var back = (current - weekday.value + 7) % 7
            if back == 0 { back = 7 }
            base = DateInterval(start: day(-back), end: day(-back + 1)); label = weekday.key
        } else if let detected = Self.detectDate(lower) {
            let start = calendar.startOfDay(for: detected)
            base = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!); label = "date"
        }

        // Part-of-day refinements apply to a single-day range (defaulting to today).
        let parts: [(String, Int, Int)] = [
            ("before lunch", 0, 12), ("after lunch", 13, 24), ("morning", 5, 12), ("afternoon", 12, 18),
            ("evening", 17, 24), ("tonight", 17, 24), ("lunch", 11, 14),
        ]
        if let part = parts.first(where: { lower.contains($0.0) }) {
            let dayStart = base.map { calendar.startOfDay(for: $0.start) } ?? today
            if base == nil || base!.duration <= 86400 + 3600 {
                let s = calendar.date(byAdding: .hour, value: part.1, to: dayStart)!
                let e = calendar.date(byAdding: .hour, value: part.2, to: dayStart)!
                return (DateInterval(start: s, end: e), [label, part.0].compactMap { $0 }.joined(separator: " "))
            }
        }
        return (base, label)
    }

    static let weekdays: [String: Int] = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]

    static func detectDate(_ text: String) -> Date? {
        guard text.rangeOfCharacter(from: .decimalDigits) != nil,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
    }
}
