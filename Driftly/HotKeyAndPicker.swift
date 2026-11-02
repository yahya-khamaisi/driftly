import AppKit
import Carbon.HIToolbox

/// A recorded key combination, stored with Carbon modifier flags for `RegisterEventHotKey`.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var carbonModifiers: Int
    var display: String

    static let `default` = Shortcut(keyCode: kVK_ANSI_D, carbonModifiers: cmdKey | controlKey, display: "⌃⌘D")

    init(keyCode: Int, carbonModifiers: Int, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; symbols += "⌘" }
        keyCode = Int(event.keyCode)
        carbonModifiers = carbon
        display = symbols + (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Global hotkey via Carbon (still the only sandbox-safe way).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(_ shortcut: Shortcut, action: @escaping () -> Void) {
        let keyCode = shortcut.keyCode
        let modifiers = shortcut.carbonModifiers
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                            EventHotKeyID(signature: OSType(0x4452_4654), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Full-screen dimmed overlay on every display; the next click returns its global CG position.
/// Esc cancels.
@MainActor
enum ClickPointPicker {
    private static var windows: [PickerWindow] = []

    static func pick(_ done: @escaping (CGPoint?) -> Void) {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = NSColor.black.withAlphaComponent(0.2)
            w.onPick = { point in
                finish()
                done(point)
            }
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private static func finish() {
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

final class PickerWindow: NSWindow {
    var onPick: ((CGPoint?) -> Void)?
    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { onPick?(CGEvent(source: nil)?.location) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onPick?(nil) }
    }
}
