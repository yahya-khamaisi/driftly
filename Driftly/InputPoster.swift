import AppKit
import CoreGraphics

/// Stamped into every event we post so ActivityMonitor can tell them apart from real input.
let syntheticMarker: Int64 = 0x4452_4654 // "DRFT"

/// Thin wrapper over CGEvent posting. Requires Accessibility ("post event") permission.
enum InputPoster {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static var canPost: Bool { CGPreflightPostEventAccess() }
    static var canListen: Bool { CGPreflightListenEventAccess() }

    /// Opens the System Settings prompts. Works inside the App Sandbox.
    static func requestAccess() {
        if !canPost { CGRequestPostEventAccess() }
        if !canListen { CGRequestListenEventAccess() }
    }

    /// Current cursor position in global CG coordinates (top-left origin of the main display).
    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func move(to p: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                     mouseCursorPosition: p, mouseButton: .left))
    }

    static func click(at p: CGPoint, right: Bool) {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        post(CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: button))
        post(CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: p, mouseButton: button))
    }

    static func scroll(dx: Int32, dy: Int32) {
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                     wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
    }

    /// A bare Control tap (flagsChanged down/up): counts as keyboard activity, types nothing.
    static func silentKeyPress() {
        let control: CGKeyCode = 0x3B
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: control, keyDown: down)
            e?.type = .flagsChanged
            e?.flags = down ? .maskControl : []
            post(e)
        }
    }

    /// ⌃⌘Q, the system Lock Screen shortcut.
    static func lockScreen() {
        let q: CGKeyCode = 0x0C
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: down)
            e?.flags = [.maskCommand, .maskControl]
            post(e)
        }
    }

    /// Bounds of the display under `p`, in global CG coordinates.
    static func displayBounds(containing p: CGPoint) -> CGRect {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 {
            return CGDisplayBounds(id)
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}
