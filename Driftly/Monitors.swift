import AppKit
import CoreGraphics
import IOKit.pwr_mgt

/// Tracks the last *real* user input, ignoring events we posted ourselves.
@MainActor
final class ActivityMonitor {
    private(set) var lastUserActivity = Date()
    private var monitor: Any?

    var idleSeconds: TimeInterval { Date().timeIntervalSince(lastUserActivity) }

    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel,
            .keyDown, .flagsChanged, .magnify, .swipe, .rotate, .pressure,
        ]
        // Keyboard events here need Input Monitoring permission; mouse events need Accessibility.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return }
            MainActor.assumeIsolated { self?.markActive() }
        }
    }

    func markActive() { lastUserActivity = Date() }
}

/// System states that should pause jiggling: lock, fast-user-switch, sleep, screensaver.
@MainActor
final class SystemPauses {
    private(set) var screenLocked = false
    private(set) var sessionInactive = false
    private(set) var asleep = false
    private(set) var screensaver = false
    var onResume: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    init() {
        let dnc = DistributedNotificationCenter.default()
        let ws = NSWorkspace.shared.notificationCenter
        observe(dnc, "com.apple.screenIsLocked") { $0.screenLocked = true }
        observe(dnc, "com.apple.screenIsUnlocked") { $0.screenLocked = false; $0.onResume?() }
        observe(dnc, "com.apple.screensaver.didstart") { $0.screensaver = true }
        observe(dnc, "com.apple.screensaver.didstop") { $0.screensaver = false; $0.onResume?() }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.sessionInactive = true }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.sessionInactive = false; $0.onResume?() }
        observe(ws, NSWorkspace.willSleepNotification.rawValue) { $0.asleep = true }
        observe(ws, NSWorkspace.didWakeNotification.rawValue) { $0.asleep = false; $0.onResume?() }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ apply: @escaping (SystemPauses) -> Void) {
        tokens.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { apply(self) } }
        })
    }

    /// True while another app has a menu open or the screenshot UI (⌘⇧4 / ⌘⇧5) is up.
    /// Uses only window layer + owner name, which need no Screen Recording permission.
    static func transientUIOnScreen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains { w in
            let pid = w[kCGWindowOwnerPID as String] as? Int32
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            return pid != me && (layer == menuLevel || owner == "screencaptureui" || owner == "Screenshot")
        }
    }
}

/// Keeps the Mac awake while Awake is on: always the system, and the display unless it may sleep.
final class PowerAssertion {
    private var systemID: IOPMAssertionID?
    private var displayID: IOPMAssertionID?

    func hold(system: Bool, display: Bool) {
        update(&systemID, on: system, type: kIOPMAssertionTypePreventUserIdleSystemSleep)
        update(&displayID, on: display, type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
    }

    private func update(_ id: inout IOPMAssertionID?, on: Bool, type: String) {
        if on, id == nil {
            var new: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Driftly Awake" as CFString, &new) == kIOReturnSuccess {
                id = new
            }
        } else if !on, let current = id {
            IOPMAssertionRelease(current)
            id = nil
        }
    }

    /// Resets the system idle timer without any visible input (used by Silent Mode).
    static func declareUserActivity() {
        var aid: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("User activity" as CFString, kIOPMUserActiveLocal, &aid)
    }
}
