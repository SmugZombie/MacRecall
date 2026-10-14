import Foundation

/// `MAJOR.MINOR.PATCH[-prerelease]`, accepting a leading "v" as used in tags.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }  // build metadata doesn't affect order
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".").map(String.init)
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let n = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
        self.init(major: n[0], minor: n[1], patch: n[2], prerelease: pre)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }
    public var description: String { "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A release outranks its prereleases; prerelease identifiers compare numerically when numeric.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false):
            for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
                switch (Int(x), Int(y)) {
                case let (i?, j?): return i < j
                case (.some, nil): return true
                case (nil, .some): return false
                default: return x < y
                }
            }
            return a.prerelease.count < b.prerelease.count
        }
    }
}
