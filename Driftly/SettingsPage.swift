import AppKit
import SwiftUI

/// Settings, inside the same menu-bar panel, laid out like System Settings.
struct SettingsPage: View {
    @EnvironmentObject var state: AppState
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .imageScale(.large)
                .help("Back")
                .accessibilityLabel("Back")
                .keyboardShortcut(.cancelAction)
                Text("Settings").font(.headline)
                Spacer()
            }
            .padding(.horizontal, Metrics.contentInset)
            .padding(.top, 14)

            FittedForm(topEdge: 4) {
                Section("Menu Bar") {
                    Picker("Icon", selection: $state.config.menuIcon) {
                        ForEach(MenuIcon.allCases) { icon in
                            Label(icon.title, systemImage: icon.active).tag(icon)
                        }
                    }
                    Toggle("Dim icon when inactive", isOn: $state.config.dimWhenIdle)
                }

                Section("General") {
                    LabeledContent("Toggle shortcut") {
                        ShortcutRecorder(shortcut: $state.config.shortcut)
                    }
                    Toggle(isOn: $state.config.launchAtLogin) {
                        Text("Open at login")
                        Text("Resumes if Driftly was on when you quit.")
                    }
                }

                Section("Power") {
                    Toggle("Pause when screen locks", isOn: $state.config.pauseWhenLocked)
                    Toggle(isOn: $state.config.preventSleep) {
                        Text("Keep Mac awake while active")
                        Text("Closing the lid still puts it to sleep.")
                    }
                    Picker("Stop when battery is below", selection: $state.config.batteryCutoff) {
                        Text("Never").tag(0)
                        Divider()
                        ForEach([5, 10, 15, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                    }
                }

                Section {
                    PermissionRow(title: "Accessibility", detail: "Moves, clicks and scrolls.",
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
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if shortcut != .default && !recording {
                Button { shortcut = .default } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset to \(Shortcut.default.display)")
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
