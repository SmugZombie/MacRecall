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

    /// Where `range` sits on screen: Vision's own box if available, otherwise estimated from the
    /// character offsets within the line (exact for monospaced text, close for proportional).
    public func box(for range: Range<String.Index>) -> CGRect {
        if let exact = locate?(range), !exact.isEmpty { return exact }
        let count = max(1, text.count)
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let x = boundingBox.minX + boundingBox.width * CGFloat(start) / CGFloat(count)
        return CGRect(x: x, y: boundingBox.minY, width: boundingBox.width * CGFloat(length) / CGFloat(count), height: boundingBox.height)
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
                // Vision expects ranges into its own string; ours is the same value.
                (try? candidate.boundingBox(for: range))?.boundingBox
            }
        }.sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        return OCRResult(lines: lines)
    }
}
