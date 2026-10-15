import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, Sendable, Codable, CaseIterable {
    case heic, jpeg
    var utType: UTType { self == .heic ? .heic : .jpeg }
    var fileExtension: String { self == .heic ? "heic" : "jpg" }
}

public enum ImageProcessing {
    /// Scales down (never up) to fit within `maxWidth` × `maxHeight`, preserving aspect ratio.
    public static func resize(_ image: CGImage, maxWidth: Int, maxHeight: Int) -> CGImage {
        let scale = min(1, Double(maxWidth) / Double(image.width), Double(maxHeight) / Double(image.height))
        guard scale < 1 else { return image }
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        return draw(width: width, height: height) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        } ?? image
    }

    /// Paints opaque boxes over regions given in Vision's normalized, bottom-left-origin coordinates.
    /// Returns nil if the image couldn't be redrawn: callers must not fall back to the original.
    public static func redact(_ image: CGImage, normalizedRects: [CGRect]) -> CGImage? {
        guard !normalizedRects.isEmpty else { return image }
        let w = image.width, h = image.height
        return draw(width: w, height: h) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for rect in normalizedRects {
                let r = CGRect(x: rect.minX * Double(w), y: rect.minY * Double(h),
                               width: rect.width * Double(w), height: rect.height * Double(h)).insetBy(dx: -4, dy: -3)
                ctx.fill(r)
            }
        }
    }

    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        body(ctx)
        return ctx.makeImage()
    }

    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// Writes via a temporary file + rename so readers never see a partial image.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// Decodes image bytes. Stored files are encrypted, so read them through `ScreenshotVault`.
    public static func load(_ data: Data, maxPixel: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Perceptual fingerprint used to skip visually identical frames.
///
/// A 64-bit difference hash alone is too coarse for text-heavy windows: a new terminal line
/// barely moves it. So we pair it with a 32×32 luminance grid and compare mean absolute difference.
public struct ImageFingerprint: Sendable, Equatable {
    public let dHash: UInt64
    public let grid: [UInt8]

    public static let gridSize = 32

    public init(dHash: UInt64, grid: [UInt8]) {
        self.dHash = dHash
        self.grid = grid
    }

    public init?(image: CGImage) {
        guard let small = Self.grayscale(image, width: 9, height: 8),
              let grid = Self.grayscale(image, width: Self.gridSize, height: Self.gridSize) else { return nil }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                hash <<= 1
                if small[row * 9 + col] < small[row * 9 + col + 1] { hash |= 1 }
            }
        }
        self.dHash = hash
        self.grid = grid
    }

    public var hexHash: String { String(format: "%016llx", dHash) }

    public func hammingDistance(to other: ImageFingerprint) -> Int { (dHash ^ other.dHash).nonzeroBitCount }

    /// Mean absolute luminance difference (0–255) across the grid.
    public func gridDifference(to other: ImageFingerprint) -> Double {
        guard grid.count == other.grid.count, !grid.isEmpty else { return 255 }
        var total = 0
        for i in 0..<grid.count { total += abs(Int(grid[i]) - Int(other.grid[i])) }
        return Double(total) / Double(grid.count)
    }

    /// `sensitivity` 0…1: higher means more frames are considered changed (fewer duplicates).
    public func isDuplicate(of other: ImageFingerprint, sensitivity: Double) -> Bool {
        let s = min(1, max(0, sensitivity))
        let maxHamming = Int((1 - s) * 6)          // 0…6 bits
        let maxGridDiff = 0.4 + (1 - s) * 2.6      // 0.4…3.0 luminance levels
        return hammingDistance(to: other) <= maxHamming && gridDifference(to: other) <= maxGridDiff
    }

    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }
}
