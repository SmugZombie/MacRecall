import CoreGraphics
import Foundation

/// The redact-before-store step. Fails closed: if text can't be recognized, the caller must not
/// store the image, because unrecognized text can't be checked for secrets.
public enum RedactionGate {
    public struct Prepared {
        public var image: CGImage
        public var ocrText: String
        public var ocrConfidence: Double?
        public var redacted: Bool
    }

    public struct Unavailable: Error, LocalizedError {
        public let underlying: String
        public var errorDescription: String? { "Text recognition failed, so the screenshot couldn't be checked for sensitive content: \(underlying)" }
    }

    public static func prepare(_ image: CGImage, rules: SensitiveContentRules,
                               paint: (CGImage, [CGRect]) -> CGImage? = ImageProcessing.redact,
                               recognize: (CGImage) async throws -> OCRResult) async throws -> Prepared {
        let result: OCRResult
        do {
            result = try await recognize(image)
        } catch {
            throw Unavailable(underlying: error.localizedDescription)
        }
        // Black out only the matched spans, not whole lines.
        let rects = result.lines.flatMap { line in rules.matchRanges(in: line.text).map { line.box(for: $0) } }
        guard !rects.isEmpty else {
            return Prepared(image: image, ocrText: rules.redact(result.text), ocrConfidence: result.meanConfidence, redacted: false)
        }
        // If the boxes can't be painted, fail closed exactly like a failed OCR.
        guard let redacted = paint(image, rects) else {
            throw Unavailable(underlying: "couldn't draw the redaction over the image")
        }
        return Prepared(image: redacted, ocrText: rules.redact(result.text), ocrConfidence: result.meanConfidence, redacted: true)
    }
}

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

    /// Saved settings keep the whole rule list, so built-in rules added in later versions are
    /// appended here. Rules can be switched off but not removed, so a missing one was never seen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decode([Rule].self, forKey: .rules)
        let names = Set(rules.map(\.name))
        rules += Self.defaults.filter { !names.contains($0.name) }
    }

    public static let defaults: [Rule] = [
        Rule(name: "AWS access key", pattern: #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Rule(name: "Private key block", pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        Rule(name: "GitHub token", pattern: #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
        Rule(name: "Slack token", pattern: #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#),
        Rule(name: "OpenAI/Anthropic-style key", pattern: #"\bsk-[A-Za-z0-9_-]{20,}\b"#),
        Rule(name: "JSON Web Token", pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#),
        Rule(name: "Password assignment", pattern: #"(?i)\b(pass(word|wd)?|secret|api[_-]?key|token)\s*[:=]\s*\S{4,}"#),
        Rule(name: "Connection string credentials", pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s@]+@"#),
        // Not part of a longer number; validated further by `isLikelyCardNumber`.
        Rule(name: "Payment card number", pattern: #"(?<![\d-])\d(?:[ -]?\d){12,18}(?![\d])"#),
        // xxx-xx-xxxx, not part of a longer number; validated further by `isLikelySSN`.
        Rule(name: "Social Security number", pattern: #"(?<![\d\-–])\d{3}[\-–]\d{2}[\-–]\d{4}(?![\d\-–])"#),
    ]

    /// Extra checks for rules whose pattern alone matches too many ordinary numbers.
    static let validators: [String: @Sendable (String) -> Bool] = [
        "Payment card number": isLikelyCardNumber,
        "Social Security number": isLikelySSN,
    ]

    private var compiled: [(Rule, NSRegularExpression)] {
        rules.filter(\.enabled).compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern)).map { (rule, $0) }
        }
    }

    public func matches(_ text: String) -> Bool { !matchRanges(in: text).isEmpty }

    /// Ranges of `text` matched by enabled rules, merged where they overlap.
    public func matchRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for (rule, regex) in compiled {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                if let validate = Self.validators[rule.name], !validate(String(text[range])) { continue }
                ranges.append(range)
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Replaces matching spans with a placeholder.
    public func redact(_ text: String) -> String {
        var result = text
        for range in matchRanges(in: text).reversed() {
            result.replaceSubrange(range, with: "[REDACTED]")
        }
        return result
    }

    /// Luhn-valid *and* shaped like a real card (issuer prefix and length), which rejects most
    /// long numeric IDs, timestamps and phone numbers that happen to pass Luhn.
    static func isLikelyCardNumber(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard luhnValid(digits) else { return false }
        let n = digits.count
        let s = digits.map(String.init).joined()
        func prefix(_ length: Int) -> Int { Int(s.prefix(length)) ?? -1 }
        switch true {
        case s.hasPrefix("4"): return [13, 16, 19].contains(n)                                        // Visa
        case (51...55).contains(prefix(2)) || (2221...2720).contains(prefix(4)): return n == 16      // Mastercard
        case [34, 37].contains(prefix(2)): return n == 15                                            // Amex
        case s.hasPrefix("6011") || s.hasPrefix("65") || (644...649).contains(prefix(3))
            || (622126...622925).contains(prefix(6)): return (16...19).contains(n)                   // Discover
        case (3528...3589).contains(prefix(4)): return (16...19).contains(n)                         // JCB
        case (300...305).contains(prefix(3)) || [36, 38, 39].contains(prefix(2)): return (14...19).contains(n)  // Diners
        default: return false
        }
    }

    /// Numbers the SSA never issues: area 000, 666 or 900–999, group 00, serial 0000.
    static func isLikelySSN(_ candidate: String) -> Bool {
        let parts = candidate.split(whereSeparator: { $0 == "-" || $0 == "–" }).compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let (area, group, serial) = (parts[0], parts[1], parts[2])
        return (1...899).contains(area) && area != 666 && group != 0 && serial != 0
    }

    static func luhnValid(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }
}
