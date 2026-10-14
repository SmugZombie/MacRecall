import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures a single window, independent of whatever surrounds it on screen.
public struct ScreenshotService: Sendable {
    public init() {}

    /// `CGPreflightScreenCaptureAccess()` is evaluated once per process, so a grant made while the app
    /// is running isn't reflected until relaunch. Window titles of *other* processes are only visible
    /// with Screen Recording access, which gives a live answer without ever triggering a prompt.
    public static var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess() || canReadForeignWindowTitles()
    }

    static func canReadForeignWindowTitles() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  // The Dock and WindowServer expose titles regardless of permission.
                  owner != "Dock", owner != "Window Server",
                  let name = info[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }

    /// True when Screen Recording appears granted but ScreenCaptureKit in this process still refuses,
    /// which happens until the app is relaunched after granting.
    public static func needsRelaunchForScreenCapture() async -> Bool {
        guard hasScreenCapturePermission, !CGPreflightScreenCaptureAccess() else { return false }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return false
        } catch {
            return true
        }
    }

    @discardableResult
    public static func requestScreenCapturePermission() -> Bool { CGRequestScreenCaptureAccess() }

    public func capture(window: SCWindow, maxWidth: Int, maxHeight: Int, showsCursor: Bool) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var width = window.frame.width * scale
        var height = window.frame.height * scale
        // Let ScreenCaptureKit do the downscale: cheaper than capturing full size and resizing.
        let fit = min(1, CGFloat(maxWidth) / width, CGFloat(maxHeight) / height)
        width = (width * fit).rounded()
        height = (height * fit).rounded()
        config.width = max(1, Int(width))
        config.height = max(1, Int(height))
        config.showsCursor = showsCursor
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
