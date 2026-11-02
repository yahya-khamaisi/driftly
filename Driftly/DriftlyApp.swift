import AppKit
import SwiftUI

/// Driftly lives entirely in one menu-bar panel: no Dock icon, no windows.
@main
struct DriftlyApp: App {
    @StateObject private var state = AppState.shared

    init() {
        #if DEBUG
        if DesignPreview.runIfRequested() { return }
        #endif
        Onboarding.presentIfNeeded()
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
    /// Returns true when running as a design preview.
    @discardableResult
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-preview") else { return false }
        let pages: [PanelPage] = args.contains("settings") ? [.settings]
            : args.contains("onboarding") ? [.onboarding]
            : args.contains("all") ? [.main, .settings] : [.main]
        DispatchQueue.main.async {
            if args.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if args.contains("light") { NSApp.appearance = NSAppearance(named: .aqua) }
            for page in pages {
                let panel = GlassPanel(rootView: PanelView(initialPage: page).environmentObject(AppState.shared))
                panel.title = "Driftly \(page)"
                panel.hasShadow = false   // keep captures to exactly what the app draws
                panel.showUnderMenuBar()
            }
        }
        _ = i
        return true
    }

}
#endif
