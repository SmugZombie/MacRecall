import CoreGraphics
import Foundation
import Vision

public struct OCRLine: Sendable {
    public var text: String
    public var confidence: Float
    /// Normalized, bottom-left origin (Vision coordinates).
    public var boundingBox: CGRect
    /// Box of a substring, when the recognizer can report it (same coordinate space).
    public var locate: (@Sendable (Range<String.Index>) -> CGRect?)?

    public init(text: String, confidence: Float, boundingBox: CGRect, locate: (@Sendable (Range<String.Index>) -> CGRect?)? = nil) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.locate = locate
    }

    /// Where `range` sits on screen. Uses Vision's box for the substring when it has one; otherwise
    /// the whole line, because estimating from character counts can miss the text in a
    /// proportional font, and a missed secret is worse than an over-redacted line.
    public func box(for range: Range<String.Index>) -> CGRect {
        if let exact = locate?(range), !exact.isEmpty, exact.intersects(boundingBox.insetBy(dx: -0.01, dy: -0.01)) {
            return exact
        }
        return boundingBox
    }
}

public struct OCRResult: Sendable {
    public var lines: [OCRLine]
    public var text: String { lines.map(\.text).joined(separator: "\n") }
    public var meanConfidence: Double? {
        guard !lines.isEmpty else { return nil }
        return Double(lines.map(\.confidence).reduce(0, +)) / Double(lines.count)
    }
}

/// Local text recognition with Apple Vision. Never touches the network.
public struct VisionOCRService: Sendable {
    public var languages: [String]

    public init(languages: [String] = ["en-US"]) { self.languages = languages }

    public func recognize(_ image: CGImage) async throws -> OCRResult {
        // No completion handler: on failure Vision may both invoke the handler *and* throw from
        // perform(), and resuming a continuation twice is fatal. perform() is synchronous, so run it
        // off the caller's executor and resume exactly once with its outcome.
        let languages = self.languages
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try Self.perform(image, languages: languages) })
            }
        }
    }

    /// Box for `range` of `text` (our copy of the candidate's string), asked of Vision safely.
    ///
    /// `VNRecognizedText.string` returns a new String on each access, and an index from one String
    /// isn't valid in another — using it can trap, which `try?` doesn't catch. So the range is
    /// rebuilt on a fresh read of `candidate.string` from UTF-16 offsets, and only if the text matches.
    static func visionBox(_ candidate: VNRecognizedText, text: String, range: Range<String.Index>) -> CGRect? {
        let start = range.lowerBound.utf16Offset(in: text)
        let end = range.upperBound.utf16Offset(in: text)
        let fresh = candidate.string
        guard fresh == text, start >= 0, start <= end, end <= fresh.utf16.count else { return nil }
        let lower = String.Index(utf16Offset: start, in: fresh)
        let upper = String.Index(utf16Offset: end, in: fresh)
        // An offset inside a surrogate pair or grapheme cluster doesn't land on a character boundary.
        guard lower.samePosition(in: fresh) != nil, upper.samePosition(in: fresh) != nil else { return nil }
        return (try? candidate.boundingBox(for: lower..<upper))?.boundingBox
    }

    static func perform(_ image: CGImage, languages: [String]) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction "fixes" identifiers, paths and command output into English words.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        // Vision returns observations roughly top-to-bottom; sort explicitly to keep reading order stable.
        let lines = observations.compactMap { obs -> OCRLine? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let text = candidate.string
            return OCRLine(text: text, confidence: candidate.confidence, boundingBox: obs.boundingBox) { range in
                Self.visionBox(candidate, text: text, range: range)
            }
        }.sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        return OCRResult(lines: lines)
    }
}
