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
                    Toggle("Show time left", isOn: $state.config.showTimeLeft)
                    Toggle("Dim icon when off", isOn: $state.config.dimWhenIdle)
                }

                Section("General") {
                    LabeledContent("Shortcut") {
                        ShortcutRecorder(shortcut: $state.config.shortcut)
                    }
                    Toggle(isOn: $state.config.launchAtLogin) {
                        Text("Open at login")
                        Text("Resumes a session that was on when you quit.")
                    }
                    Toggle("Notify when a session ends", isOn: $state.config.notifyOnEnd)
                }

                Section("Power") {
                    Picker("When the screen is locked", selection: $state.config.whenLocked) {
                        Text("Pause").tag(LockBehavior.pause)
                        Text("Keep going").tag(LockBehavior.keepGoing)
                    }
                    .help("Pause lets the display sleep and stops simulated activity; the Mac stays awake.")
                    Picker("Lock screen when idle for", selection: $state.config.lockAfterIdle) {
                        Text("Never").tag(TimeInterval(0))
                        Divider()
                        ForEach([60, 120, 300, 600, 900, 1800], id: \.self) { Text(Summary.duration($0)).tag(TimeInterval($0)) }
                    }
                    .help("During a session, locks the screen after this long without real input.")
                    Picker("End session below", selection: $state.config.batteryCutoff) {
                        Text("Never").tag(0)
                        Divider()
                        ForEach([5, 10, 15, 20, 30, 50], id: \.self) { Text("\($0)% battery").tag($0) }
                    }
                    LabeledContent("Keep drive awake") {
                        Menu(state.config.keepDriveName ?? "None") {
                            Button("None") {
                                state.config.keepDriveName = nil
                                state.config.keepDriveBookmark = nil
                            }
                            Divider()
                            Button("Choose Drive…") {
                                if let drive = DriveKeeper.choose() {
                                    state.config.keepDriveName = drive.name
                                    state.config.keepDriveBookmark = drive.bookmark
                                }
                            }
                        }
                        .fixedSize()
                    }
                    .help("Writes a tiny hidden file to the drive once a minute during a session.")
                }

                Section("Statistics") {
                    LabeledContent("Awake today") {
                        Text("\(Summary.total(state.statsSnapshot.today)) · this week \(Summary.total(state.statsSnapshot.week))")
                    }
                    .contextMenu { Button("Reset Statistics", role: .destructive) { state.resetStats() } }
                }

                Section {
                    PermissionRow(title: "Accessibility", detail: "Simulates activity and locks the screen.",
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
