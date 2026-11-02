import AppKit
import SwiftUI

enum Onboarding {
    private static let key = "onboarding.completed"

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static var panel: GlassPanel?

    /// On first launch, shows the welcome page in a glass panel under the menu bar.
    /// (MenuBarExtra has no public API to open its own panel, and on recent macOS the
    /// status item is hosted out of process, so we present the same page ourselves.)
    @MainActor static func presentIfNeeded() {
        guard !isComplete else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let page = OnboardingPage(done: finish).environmentObject(AppState.shared)
            let panel = GlassPanel(rootView: page.frame(width: Metrics.width).focusEffectDisabled())
            panel.showUnderMenuBar()
            self.panel = panel
        }
    }

    @MainActor static func finish() {
        isComplete = true
        panel?.close()
        panel = nil
    }
}

/// First-run welcome: what Driftly does, the two permissions, and where to find it.
struct OnboardingPage: View {
    @EnvironmentObject var state: AppState
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text("Welcome to Driftly")
                    .font(.title3.weight(.semibold))
                Text("Keeps your Mac awake and your status active by gently moving the cursor while you're away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Metrics.contentInset)
            .padding(.top, 24)

            FittedForm(topEdge: 6) {
                Section {
                    PermissionRow(title: "Accessibility", detail: "Required to move the cursor.",
                                  granted: state.canPost, pane: .accessibility)
                    PermissionRow(title: "Input Monitoring", detail: "Optional. Pauses while you type.",
                                  granted: state.canListen, pane: .inputMonitoring)
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Turn Driftly on in each list. If it doesn't update here, quit and reopen Driftly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent {
                        Image(systemName: state.config.menuIcon.active)
                            .imageScale(.large)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Lives in the menu bar")
                        Text("Click its icon any time, or press \(state.config.shortcut.display).")
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                if state.canPost {
                    Button("Get Started", action: done)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Set Up Later", action: done)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, Metrics.contentInset - 10)
            .padding(.vertical, 10)
        }
    }
}
