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
            HStack(spacing: 3) {
                Image(systemName: state.iconLit ? icon.active : icon.idle)
                    .opacity(!state.iconLit && state.config.dimWhenIdle ? 0.45 : 1)
                if let left = state.timeLeft {
                    Text(left).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppState {
    static let shared = AppState()
}

#if DEBUG
/// `-preview [main|awake|drift|settings|triggers|editor|all] [light|dark]` shows the panel in a borderless, menu-like
/// window so it can be captured for design review without the menu bar.
enum DesignPreview {
    /// Returns true when running as a design preview.
    @discardableResult
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-preview") else { return false }
        let pages: [PanelPage] = args.contains("settings") ? [.settings]
            : args.contains("awake") ? [.awake]
            : args.contains("drift") ? [.drift]
            : args.contains("onboarding") ? [.onboarding]
            : args.contains("triggers") ? [.triggers]
            : args.contains("editor") ? [.editTrigger(nil)]
            : args.contains("all") ? [.main, .awake, .drift, .triggers, .editTrigger(nil), .settings] : [.main]
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
