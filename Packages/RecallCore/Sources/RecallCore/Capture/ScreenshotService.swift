import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures a single window, independent of whatever surrounds it on screen.
public struct ScreenshotService: Sendable {
    public init() {}

    public static var hasScreenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

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
