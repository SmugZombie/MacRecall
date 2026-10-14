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

        if Self.accessibilityTrusted {
            switch Self.focusedWindowInfo(pid: pid) {
            case .some(let ax):
                if ax.minimized { return .skipped(.noFocusedWindow, detail: "focused window minimized") }
                if let frame = ax.frame {
                    let byFrame = candidates.filter { Self.framesMatch($0.frame, frame) }
                    if byFrame.count == 1 { return make(byFrame[0], title: ax.title, method: "ax_frame") }
                    if let t = ax.title, let w = byFrame.first(where: { $0.title == t }) { return make(w, title: t, method: "ax_frame") }
                    if let w = byFrame.first { return make(w, title: ax.title, method: "ax_frame") }
                }
                if let t = ax.title, !t.isEmpty {
                    let byTitle = candidates.filter { $0.title == t }
                    if byTitle.count == 1 { return make(byTitle[0], title: t, method: "ax_title") }
                }
                // AX gave us a focused window we can't match (e.g. off-Space or not shareable).
                return .skipped(.windowNotShareable, detail: "focused window not matched to a capturable window")
            case .none:
                // The app reports no focused window (e.g. Finder showing only the desktop).
                if Self.appExposesAXWindows(pid: pid) { return .skipped(.noFocusedWindow, detail: "no AX focused window") }
            }
        }

        // Fallback: frontmost window of this process by z-order.
        if let frontID = Self.frontmostWindowID(pid: pid), let w = candidates.first(where: { $0.windowID == frontID }) {
            return make(w, title: nil, method: "z_order")
        }
        return .skipped(.noFocusedWindow, detail: "could not determine focused window")
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    struct AXWindowInfo {
        var title: String?
        var frame: CGRect?
        var minimized: Bool
    }

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

    static func appExposesAXWindows(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return false }
        return ((value as? [AnyObject])?.count ?? 0) > 0
    }

    /// CGWindowList returns on-screen windows front-to-back.
    static func frontmostWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat], (bounds["Width"] ?? 0) < 40 || (bounds["Height"] ?? 0) < 40 { continue }
            return id
        }
        return nil
    }
}
