import Foundation

enum TextTokens {
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "you", "your", "are", "was", "but", "not", "all",
        "can", "has", "have", "had", "will", "its", "our", "out", "new", "one", "use", "into", "about", "more",
        "file", "edit", "view", "window", "help", "untitled", "home", "tab", "page", "google", "chrome", "safari",
    ]

    /// Lowercased word tokens useful for similarity comparisons.
    static func tokens(_ text: String, limit: Int = 400) -> [String] {
        var result: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            guard raw.count >= 3, raw.count <= 40, !raw.allSatisfy(\.isNumber) else { continue }
            let token = String(raw)
            guard !stopwords.contains(token) else { continue }
            result.append(token)
            if result.count >= limit { break }
        }
        return result
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        let inter = a.intersection(b).count
        return Double(inter) / Double(a.union(b).count)
    }

    /// Fraction of `a` found in `b` — tolerant of `b` being a large accumulated bag.
    static func containment(_ a: Set<String>, in b: Set<String>) -> Double {
        guard !a.isEmpty else { return 1 }
        return Double(a.intersection(b).count) / Double(a.count)
    }
}
