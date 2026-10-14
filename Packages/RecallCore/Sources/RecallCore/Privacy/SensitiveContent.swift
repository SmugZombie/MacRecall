import Foundation

/// User-configurable patterns for text that should be redacted before storage or transmission.
///
/// Best effort only: OCR can miss or mangle secrets, so this complements — never replaces —
/// application exclusions and secure-input detection.
public struct SensitiveContentRules: Codable, Sendable, Equatable {
    public struct Rule: Codable, Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var pattern: String
        public var enabled: Bool

        public init(name: String, pattern: String, enabled: Bool = true) {
            self.name = name
            self.pattern = pattern
            self.enabled = enabled
        }
    }

    public var rules: [Rule]

    public init(rules: [Rule] = SensitiveContentRules.defaults) { self.rules = rules }

    public static let defaults: [Rule] = [
        Rule(name: "AWS access key", pattern: #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Rule(name: "Private key block", pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        Rule(name: "GitHub token", pattern: #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
        Rule(name: "Slack token", pattern: #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#),
        Rule(name: "OpenAI/Anthropic-style key", pattern: #"\bsk-[A-Za-z0-9_-]{20,}\b"#),
        Rule(name: "JSON Web Token", pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#),
        Rule(name: "Password assignment", pattern: #"(?i)\b(pass(word|wd)?|secret|api[_-]?key|token)\s*[:=]\s*\S{4,}"#),
        Rule(name: "Connection string credentials", pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s@]+@"#),
        Rule(name: "Payment card number", pattern: #"\b(?:\d[ -]?){13,19}\b"#),
    ]

    private var compiled: [(Rule, NSRegularExpression)] {
        rules.filter(\.enabled).compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern)).map { (rule, $0) }
        }
    }

    public func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return compiled.contains { rule, regex in
            guard let match = regex.firstMatch(in: text, range: range) else { return false }
            if rule.name == "Payment card number" {
                return Self.luhnValid(String(text[Range(match.range, in: text)!]))
            }
            return true
        }
    }

    /// Replaces matching spans with a placeholder.
    public func redact(_ text: String) -> String {
        var result = text
        for (rule, regex) in compiled {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                if rule.name == "Payment card number", !Self.luhnValid(String(result[range])) { continue }
                result.replaceSubrange(range, with: "[REDACTED]")
            }
        }
        return result
    }

    static func luhnValid(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }
}
