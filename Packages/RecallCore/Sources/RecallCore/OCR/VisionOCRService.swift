import CoreGraphics
import Foundation
import Vision

public struct OCRLine: Sendable {
    public var text: String
    public var confidence: Float
    /// Normalized, bottom-left origin (Vision coordinates).
    public var boundingBox: CGRect
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
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Vision returns observations roughly top-to-bottom; sort explicitly to keep reading order stable.
                let lines = observations.compactMap { obs -> OCRLine? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return OCRLine(text: candidate.string, confidence: candidate.confidence, boundingBox: obs.boundingBox)
                }.sorted {
                    abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                        ? $0.boundingBox.midY > $1.boundingBox.midY
                        : $0.boundingBox.minX < $1.boundingBox.minX
                }
                continuation.resume(returning: OCRResult(lines: lines))
            }
            request.recognitionLevel = .accurate
            // Language correction "fixes" identifiers, paths and command output into English words.
            request.usesLanguageCorrection = false
            request.recognitionLanguages = languages
            request.minimumTextHeight = 0.006
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) } catch { continuation.resume(throwing: error) }
        }
    }
}
