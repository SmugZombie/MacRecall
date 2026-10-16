import AppKit
import Foundation

/// Where an image on the clipboard came from.
public enum ClipboardImageKind: String, Sendable {
    /// Taken with ⌃⇧⌘3 / ⌃⇧⌘4 (or `screencapture -c`).
    case screenClipping
    /// Copied from an app, such as Copy Image in a browser or ⌘C in Preview.
    case copiedImage

    private static let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "public.heic"]
    /// Flags that describe a clipboard rather than add content to it.
    private static let markerTypes: Set<String> = ["com.apple.is-remote-clipboard", "org.nspasteboard.source"]
    /// See nspasteboard.org: content the copying app asked other apps not to keep.
    private static let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    /// Classifies a clipboard's items by their type identifiers, or returns nil if there's no image to take.
    ///
    /// macOS puts a screen clipping on the clipboard as a single item holding nothing but PNG data. Apps that
    /// copy an image add their own types alongside it (TIFF, HTML, a source URL, private formats), which is
    /// what tells the two apart. Items marked concealed or transient (password managers, clipboard tools)
    /// are never taken.
    public static func classify(items: [[String]], remoteFlag: Data? = nil) -> ClipboardImageKind? {
        let all = Set(items.flatMap { $0 })
        if !all.isDisjoint(with: privateTypes) { return nil }
        guard all.contains(where: imageTypes.contains) else { return nil }
        // An image that arrived from another device over Universal Clipboard wasn't clipped on this Mac.
        let remote = remoteFlag.map { $0.contains { $0 != 0 } } ?? false
        let meaningful = all.subtracting(markerTypes)
        if items.count == 1, !remote, meaningful == ["public.png"] { return .screenClipping }
        return .copiedImage
    }
}

/// Polls the general pasteboard and hands newly copied images to `onImage`.
///
/// macOS has no clipboard-change notification, so this compares `changeCount` twice a second, which is
/// cheap. Contents are read only when the count changes and only if the matching setting is on.
@MainActor
public final class ClipboardWatcher {
    public typealias Handler = @MainActor (CGImage, ClipboardImageKind) -> Void

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var enabledKinds: Set<ClipboardImageKind> = []
    public var onImage: Handler?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    /// Watches for the given kinds; an empty set stops watching.
    public func watch(_ kinds: Set<ClipboardImageKind>) {
        enabledKinds = kinds
        if kinds.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            // Only images copied from now on count, not whatever was already on the clipboard.
            lastChangeCount = pasteboard.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let items = (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        let remoteFlag = pasteboard.data(forType: NSPasteboard.PasteboardType("com.apple.is-remote-clipboard"))
        guard let kind = ClipboardImageKind.classify(items: items, remoteFlag: remoteFlag),
              enabledKinds.contains(kind), let image = readImage() else { return }
        onImage?(image, kind)
    }

    private func readImage() -> CGImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = ImageProcessing.load(data) { return image }
        }
        return NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
