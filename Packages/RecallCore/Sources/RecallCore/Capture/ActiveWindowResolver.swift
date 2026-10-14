import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

public struct ResolvedWindow: @unchecked Sendable {
    public var scWindow: SCWindow
    public var windowID: CGWindowID
    public var title: String
    public var frame: CGRect
    public var bundleIdentifier: String
    public var applicationName: String
    public var pid: pid_t
    /// How the focused window was identified: "ax_frame", "ax_title", "z_order".
    public var matchMethod: String
}

public enum WindowResolution: @unchecked Sendable {
    case resolved(ResolvedWindow)
    case skipped(SkipReason, detail: String)
}

/// Finds the window that actually has focus and matches it to a ScreenCaptureKit window.
///
/// There is no public API mapping an Accessibility element to a CGWindowID, so we match on
/// geometry and title. If Accessibility is unavailable we fall back to the frontmost on-screen
/// window of the frontmost process (CGWindowList is ordered front-to-back). We never fall back
/// to capturing a display.
public struct ActiveWindowResolver: Sendable {
    public init() {}

    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func resolve(app: NSRunningApplication) async -> WindowResolution {
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? "pid.\(pid)"
        let name = app.localizedName ?? bundle

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            return .skipped(.noPermission, detail: "shareable content unavailable")
        }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen
                && $0.frame.width >= 40 && $0.frame.height >= 40
        }
        guard !candidates.isEmpty else { return .skipped(.noFocusedWindow, detail: "no on-screen windows") }

        func make(_ w: SCWindow, title: String?, method: String) -> WindowResolution {
            .resolved(ResolvedWindow(scWindow: w, windowID: w.windowID, title: title ?? w.title ?? "", frame: w.frame,
                                     bundleIdentifier: bundle, applicationName: name, pid: pid, matchMethod: method))
        }

        // Accessibility and CGWindowList queries run on the main thread; everything after is pure.
        let facts = await MainActor.run { Self.focusFacts(pid: pid) }
        let ranked = candidates.map {
            WindowCandidate(id: $0.windowID, title: $0.title, frame: $0.frame, zIndex: facts.zOrder.firstIndex(of: $0.windowID))
        }
        switch Self.match(focus: facts.focus, accessibilityAvailable: facts.trusted, candidates: ranked) {
        case .window(let id, let method):
            guard let w = candidates.first(where: { $0.windowID == id }) else { break }
            return make(w, title: facts.focus.window?.title, method: method)
        case .skip(let reason, let detail):
            return .skipped(reason, detail: detail)
        }
        return .skipped(.noFocusedWindow, detail: "could not determine focused window")
    }

    // MARK: Matching (pure, unit-tested)

    struct WindowCandidate: Equatable {
        var id: CGWindowID
        var title: String?
        var frame: CGRect
        /// Position in the front-to-back on-screen order (0 = frontmost), if known.
        var zIndex: Int?
    }

    enum FocusState: Equatable {
        case focused(AXWindowInfo)
        /// The app has windows but none is focused (e.g. Finder showing only the desktop).
        case noFocusedWindow
        /// Accessibility is unavailable or the app exposes no AX windows.
        case unknown

        var window: AXWindowInfo? { if case .focused(let w) = self { return w }; return nil }
    }

    enum MatchResult: Equatable {
        case window(CGWindowID, method: String)
        case skip(SkipReason, detail: String)
    }

    /// AX and ScreenCaptureKit frames can disagree by a few points (fractional origins, title-bar
    /// insets in some apps), so frames are scored rather than compared exactly.
    static let frameTolerance: CGFloat = 24

    static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// Picks the focused window among an app's capturable windows. Ties — several windows with the
    /// same frame or title, common in browsers and editors — go to the frontmost by z-order, since the
    /// focused window of the active app is its frontmost one.
    static func match(focus: FocusState, accessibilityAvailable: Bool, candidates: [WindowCandidate]) -> MatchResult {
        func frontmost(_ list: [WindowCandidate]) -> WindowCandidate? {
            list.min { ($0.zIndex ?? .max) < ($1.zIndex ?? .max) }
        }
        switch focus {
        case .focused(let ax):
            if ax.minimized { return .skip(.noFocusedWindow, detail: "focused window minimized") }
            if let frame = ax.frame {
                let scored = candidates.map { ($0, frameDistance($0.frame, frame)) }.filter { $0.1 <= frameTolerance }
                if let best = scored.map(\.1).min() {
                    // Everything within a couple of points of the best score counts as the same fit.
                    var near = scored.filter { $0.1 <= best + 2 }.map(\.0)
                    if let t = ax.title, !t.isEmpty, near.contains(where: { $0.title == t }) { near = near.filter { $0.title == t } }
                    if let w = frontmost(near) { return .window(w.id, method: near.count == 1 ? "ax_frame" : "ax_frame_z") }
                }
            }
            if let t = ax.title, !t.isEmpty {
                let byTitle = candidates.filter { $0.title == t }
                if let w = frontmost(byTitle) { return .window(w.id, method: byTitle.count == 1 ? "ax_title" : "ax_title_z") }
            }
            // AX names a focused window we can't see (off-Space, not shareable, or a sheet/panel).
            return .skip(.windowNotShareable, detail: "focused window not matched to a capturable window")
        case .noFocusedWindow:
            return .skip(.noFocusedWindow, detail: "no AX focused window")
        case .unknown:
            // No Accessibility: the frontmost on-screen window of the frontmost app.
            if let w = frontmost(candidates.filter { $0.zIndex != nil }) { return .window(w.id, method: "z_order") }
            return .skip(.noFocusedWindow, detail: accessibilityAvailable ? "app exposes no windows" : "could not determine focused window")
        }
    }

    // MARK: Main-thread queries

    struct FocusFacts {
        var trusted: Bool
        var focus: FocusState
        var zOrder: [CGWindowID]
    }

    @MainActor
    static func focusFacts(pid: pid_t) -> FocusFacts {
        let trusted = accessibilityTrusted
        var focus = FocusState.unknown
        if trusted {
            if let info = focusedWindowInfo(pid: pid) {
                focus = .focused(info)
            } else if appExposesAXWindows(pid: pid) {
                focus = .noFocusedWindow
            }
        }
        return FocusFacts(trusted: trusted, focus: focus, zOrder: windowZOrder(pid: pid))
    }

    struct AXWindowInfo: Equatable {
        var title: String?
        var frame: CGRect?
        var minimized: Bool
    }

    @MainActor
    static func focusedWindowInfo(pid: pid_t) -> AXWindowInfo? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = window as! AXUIElement

        func attr(_ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success ? v : nil
        }
        let title = attr(kAXTitleAttribute) as? String
        let minimized = (attr(kAXMinimizedAttribute) as? Bool) ?? false
        var frame: CGRect?
        if let posValue = attr(kAXPositionAttribute), let sizeValue = attr(kAXSizeAttribute),
           CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(posValue as! AXValue, .cgPoint, &point), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: point, size: size)
            }
        }
        return AXWindowInfo(title: title, frame: frame, minimized: minimized)
    }

    @MainActor
    static func appExposesAXWindows(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return false }
        return ((value as? [AnyObject])?.count ?? 0) > 0
    }

    /// This process's normal-layer on-screen windows, front to back (CGWindowList's order).
    @MainActor
    static func windowZOrder(pid: pid_t) -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
    }
}
