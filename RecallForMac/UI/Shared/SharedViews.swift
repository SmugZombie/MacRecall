import AppKit
import RecallCore
import SwiftUI

/// Decoded thumbnails/screenshots, bounded so long histories don't grow memory.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        c.totalCostLimit = 300 * 1024 * 1024
        return c
    }()

    func image(for url: URL, maxPixel: Int?) async -> NSImage? {
        let key = "\(url.path)#\(maxPixel ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = ImageProcessing.load(url, maxPixel: maxPixel) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
}

/// Loads an image lazily from the library when it scrolls into view.
struct StoredImage: View {
    let relativePath: String
    var maxPixel: Int? = nil
    @EnvironmentObject private var state: AppState
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                }
            } else {
                Rectangle().fill(.quaternary.opacity(0.5)).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: relativePath) {
            guard let store = state.store, !relativePath.isEmpty else { failed = true; return }
            image = await ImageCache.shared.image(for: store.paths.absolute(relativePath), maxPixel: maxPixel)
            failed = image == nil
        }
    }
}

struct AppIcon: View {
    let bundleIdentifier: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: Self.icon(for: bundleIdentifier))
            .resizable()
            .frame(width: size, height: size)
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for bundle: String) -> NSImage {
        if let cached = cache[bundle] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundle] = image
        return image
    }
}

/// Renders an FTS snippet, bolding the «matched» spans.
struct HighlightedText: View {
    let snippet: String

    var body: some View { Text(Self.attributed(snippet)) }

    static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.firstIndex(of: "«") {
            result += AttributedString(String(rest[..<open]))
            rest = rest[rest.index(after: open)...]
            if let close = rest.firstIndex(of: "»") {
                var match = AttributedString(String(rest[..<close]))
                match.font = .body.bold()
                match.backgroundColor = .yellow.opacity(0.35)
                result += match
                rest = rest[rest.index(after: close)...]
            }
        }
        result += AttributedString(String(rest))
        return result
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct ProcessingBadge: View {
    let capture: CaptureRecord

    var body: some View {
        HStack(spacing: 4) {
            if capture.ocrStatus == .pending || capture.ocrStatus == .running { StatusPill(text: "OCR…", color: .orange) }
            if capture.ocrStatus == .failed { StatusPill(text: "OCR failed", color: .red) }
            if capture.aiStatus == .running { StatusPill(text: "Analyzing…", color: .blue) }
            if capture.redacted { StatusPill(text: "Redacted", color: .purple) }
        }
    }
}

extension Date {
    var timeString: String { formatted(date: .omitted, time: .shortened) }
}

func formatDuration(_ seconds: Double) -> String { DailySummaryService.duration(seconds) }

func timeRange(_ start: Date, _ end: Date) -> String {
    "\(start.timeString) – \(end.timeString)"
}
