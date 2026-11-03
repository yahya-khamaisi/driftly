import AppKit
import SwiftUI

/// Settings, inside the same menu-bar panel, laid out like System Settings.
struct SettingsPage: View {
    @EnvironmentObject var state: AppState
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings", back: back)

            FittedForm(topEdge: 4) {
                Section("Menu Bar") {
                    Picker("Icon", selection: $state.config.menuIcon) {
                        ForEach(MenuIcon.allCases) { icon in
                            Label(icon.title, systemImage: icon.active).tag(icon)
                        }
                    }
                    Picker("Icon lights up for", selection: $state.config.iconFor) {
                        Text("Awake or Drift").tag(IconSource.either)
                        Divider()
                        Text("Awake").tag(IconSource.awake)
                        Text("Drift").tag(IconSource.drift)
                    }
                    Toggle("Dim icon when off", isOn: $state.config.dimWhenIdle)
                }

                Section("General") {
                    Toggle(isOn: $state.config.launchAtLogin) {
                        Text("Open at login")
                        Text("Turns back on what was on when you quit.")
                    }
                }

                Section("Statistics") {
                    LabeledContent("Awake today") {
                        Text("\(Summary.total(state.statsSnapshot.awakeToday)) · week \(Summary.total(state.statsSnapshot.awakeWeek))")
                    }
                    LabeledContent("Drift today") {
                        Text("\(Summary.total(state.statsSnapshot.driftToday)) · week \(Summary.total(state.statsSnapshot.driftWeek))")
                    }
                }
                .contextMenu { Button("Reset Statistics", role: .destructive) { state.resetStats() } }

                Section {
                    PermissionRow(title: "Accessibility", detail: "Drift and screen lock.",
                                  granted: state.canPost, pane: .accessibility)
                    PermissionRow(title: "Input Monitoring", detail: "Notices when you're typing.",
                                  granted: state.canListen, pane: .inputMonitoring)
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Driftly \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// A standard push button that records the next key combination.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let defaultShortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if shortcut != defaultShortcut && !recording {
                Button { shortcut = defaultShortcut } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset to \(defaultShortcut.display)")
                    .accessibilityLabel("Reset shortcut")
            }
            Button(recording ? "Type Shortcut…" : shortcut.display) { recording ? stop() : start() }
                .monospacedDigit()
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }   // Esc cancels
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            if mods.isEmpty { NSSound.beep(); return nil }  // require ⌘, ⌥ or ⌃
            shortcut = Shortcut(event: event)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

enum Permissions {
    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let pane: Permissions.Pane

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow…") {
                    InputPoster.requestAccess()
                    Permissions.open(pane)
                }
                .help("Opens Privacy & Security in System Settings")
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
