import AppKit
import Carbon
import CoreGraphics
import Foundation
import IOKit.ps

/// Observes app activation, lock/unlock, sleep/wake, idle and power state.
///
/// Main-actor bound because NSWorkspace notifications are delivered there.
@MainActor
public final class SystemStateMonitor {
    public enum Event: Sendable {
        case appActivated(bundleIdentifier: String?, name: String?, pid: pid_t)
        case screenLocked, screenUnlocked
        case willSleep, didWake
        case screensSlept, screensWoke
        case sessionResigned, sessionBecameActive
        case idle, resumed
    }

    public private(set) var screenLocked = false
    public private(set) var asleep = false
    public private(set) var screensAsleep = false
    public private(set) var sessionActive = true
    public private(set) var userIdle = false

    public var idleTimeout: TimeInterval = 300
    public var onEvent: ((Event) -> Void)?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var idleTimer: Timer?

    public init() {}

    public func start() {
        // Notifications only report changes; read the current state so a launch while locked,
        // on a switched-out session, or with displays asleep starts out correct.
        let live = Self.liveState()
        screenLocked = live.locked
        sessionActive = live.onConsole
        screensAsleep = live.displaysAsleep

        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        observe(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.emit(.appActivated(bundleIdentifier: app?.bundleIdentifier, name: app?.localizedName, pid: app?.processIdentifier ?? 0))
        }
        observe(ws, NSWorkspace.willSleepNotification) { [weak self] _ in self?.asleep = true; self?.emit(.willSleep) }
        observe(ws, NSWorkspace.didWakeNotification) { [weak self] _ in self?.asleep = false; self?.emit(.didWake) }
        observe(ws, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.screensAsleep = true; self?.emit(.screensSlept) }
        observe(ws, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.screensAsleep = false; self?.emit(.screensWoke) }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.sessionActive = false; self?.emit(.sessionResigned) }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.sessionActive = true; self?.emit(.sessionBecameActive) }
        observe(dist, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.screenLocked = true; self?.emit(.screenLocked) }
        observe(dist, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.screenLocked = false; self?.emit(.screenUnlocked) }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile()
                self?.checkIdle()
            }
        }
    }

    public func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        observers.append((center, token))
    }

    private func emit(_ event: Event) { onEvent?(event) }

    /// Corrects state from the live session in case a notification was missed.
    private func reconcile() {
        let live = Self.liveState()
        if live.locked != screenLocked {
            screenLocked = live.locked
            emit(live.locked ? .screenLocked : .screenUnlocked)
        }
        if live.onConsole != sessionActive {
            sessionActive = live.onConsole
            emit(live.onConsole ? .sessionBecameActive : .sessionResigned)
        }
        if live.displaysAsleep != screensAsleep {
            screensAsleep = live.displaysAsleep
            emit(live.displaysAsleep ? .screensSlept : .screensWoke)
        }
        // This timer only fires while the system runs. If displays are awake but we still think the
        // system is asleep, the wake notification was missed. (During a dark wake displays stay asleep.)
        if asleep && !live.displaysAsleep {
            asleep = false
            emit(.didWake)
        }
    }

    public struct LiveState: Equatable, Sendable {
        public var locked: Bool
        public var onConsole: Bool
        public var displaysAsleep: Bool
    }

    public nonisolated static func liveState() -> LiveState {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        return LiveState(locked: isLocked(sessionInfo: info), onConsole: isOnConsole(sessionInfo: info),
                         displaysAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0)
    }

    /// Fails safe: no session information is treated as locked.
    nonisolated static func isLocked(sessionInfo: [String: Any]?) -> Bool {
        guard let info = sessionInfo else { return true }
        if (info["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return !isOnConsole(sessionInfo: info)
    }

    nonisolated static func isOnConsole(sessionInfo: [String: Any]?) -> Bool {
        guard let info = sessionInfo else { return false }
        return (info[kCGSessionOnConsoleKey as String] as? Bool) ?? true
    }

    private func checkIdle() {
        let idleFor = Self.secondsSinceLastInput
        if !userIdle && idleFor >= idleTimeout {
            userIdle = true
            emit(.idle)
        } else if userIdle && idleFor < idleTimeout {
            userIdle = false
            emit(.resumed)
        }
    }

    /// Seconds since any keyboard/mouse input, system-wide. No permission required.
    public static var secondsSinceLastInput: TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// True while a password field (or similar) has enabled secure keyboard entry anywhere.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    public static var onBatteryPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return type == kIOPSBatteryPowerValue
    }
}
