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

    func removeAll() { cache.removeAllObjects() }

    /// Decrypts and decodes a stored image. Throws `ScreenshotVault.Failure.missingKey` for screenshots
    /// encrypted with a key that isn't on this Mac.
    func image(_ relativePath: String, maxPixel: Int?, vault: ScreenshotVault) async throws -> NSImage {
        let key = "\(relativePath)#\(maxPixel ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = try await Task.detached(priority: .userInitiated) { () throws -> NSImage in
            let cg = try vault.image(relativePath, maxPixel: maxPixel)
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
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
    @State private var locked = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: locked ? "lock.fill" : "photo.badge.exclamationmark").foregroundStyle(.secondary)
                }
                .help(locked ? "Encrypted with a key that isn't on this Mac. Import its recovery key in Settings → Privacy." : "")
            } else {
                Rectangle().fill(.quaternary.opacity(0.5)).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: relativePath) {
            guard let store = state.store, !relativePath.isEmpty else { failed = true; return }
            do {
                image = try await ImageCache.shared.image(relativePath, maxPixel: maxPixel, vault: store.vault)
                failed = false
            } catch {
                image = nil
                failed = true
                locked = (error as? ScreenshotVault.Failure) == .missingKey
            }
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

/// Explains what deleting screenshots removes, for confirmation dialogs.
enum CaptureDeletionText {
    static func message(count: Int) -> String {
        (count == 1 ? "The screenshot, its recognized text, AI description and search entries are"
                    : "These \(count) screenshots, their recognized text, AI descriptions and search entries are")
            + " permanently deleted. Session and daily summaries that drew on \(count == 1 ? "it" : "them") are rebuilt without \(count == 1 ? "it" : "them"); summaries you wrote yourself are kept."
    }
}

extension Date {
    var timeString: String { formatted(date: .omitted, time: .shortened) }
}

func formatDuration(_ seconds: Double) -> String { DailySummaryService.duration(seconds) }

func timeRange(_ start: Date, _ end: Date) -> String {
    "\(start.timeString) – \(end.timeString)"
}
