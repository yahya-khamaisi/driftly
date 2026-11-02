import AppKit
import SwiftUI

/// Driftly lives entirely in one menu-bar panel: no Dock icon, no windows.
@main
struct DriftlyApp: App {
    @StateObject private var state = AppState.shared

    init() {
        #if DEBUG
        DesignPreview.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(state)
        } label: {
            let icon = state.config.menuIcon
            Image(systemName: state.isActive ? icon.active : icon.idle)
                .opacity(!state.isActive && state.config.dimWhenIdle ? 0.45 : 1)
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppState {
    static let shared = AppState()
}

#if DEBUG
/// `-preview [main|settings|all] [light|dark]` shows the panel in a borderless, menu-like
/// window so it can be captured for design review without the menu bar.
enum DesignPreview {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-preview") else { return }
        let pages: [PanelPage] = args.contains("settings") ? [.settings]
            : args.contains("all") ? [.main, .settings] : [.main]
        DispatchQueue.main.async {
            if args.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if args.contains("light") { NSApp.appearance = NSAppearance(named: .aqua) }
            for (n, page) in pages.enumerated() {
                let host = NSHostingView(rootView: PanelView(initialPage: page).environmentObject(AppState.shared))
                let blur = Self.panelBackground(size: host.fittingSize)
                host.frame = blur.bounds
                host.autoresizingMask = [.width, .height]
                if #available(macOS 26.0, *), let glass = blur as? NSGlassEffectView {
                    glass.contentView = host
                } else {
                    blur.addSubview(host)
                }

                let panel = KeyPanel(contentRect: blur.frame, styleMask: [.borderless],
                                     backing: .buffered, defer: false)
                panel.title = "Driftly \(page)"
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.contentView = blur
                let topLeft = NSPoint(x: 120 + CGFloat(n) * 360, y: 960)
                panel.setFrameTopLeftPoint(topLeft)
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                // Content measures itself after the first layout pass; refit like MenuBarExtra does.
                for delay in [0.3, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        panel.setContentSize(host.fittingSize)
                        panel.setFrameTopLeftPoint(topLeft)
                        // A borderless window's shadow is traced from its alpha once and cached;
                        // retrace it now that the rounded glass is drawn, or the square frame shows.
                        panel.display()
                        panel.invalidateShadow()
                    }
                }
            }
        }
        _ = i
    }

    /// Borderless panels can't become key by default; the real menu-bar panel is key while open,
    /// so controls must render in their active state here too.
    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// The same backdrop the menu-bar panel gets: Liquid Glass on 26+, popover material before.
    @MainActor private static func panelBackground(size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = 16
            return glass
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .popover
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        return blur
    }
}
#endif
