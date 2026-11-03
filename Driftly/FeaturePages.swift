import SwiftUI

/// Everything about keeping the Mac awake that isn't on the main card.
struct AwakePage: View {
    @EnvironmentObject var state: AppState
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Awake", back: back)
            FittedForm(topEdge: 4) {
                Section("Session") {
                    Toggle("Show time left in menu bar", isOn: $state.config.showTimeLeft)
                    FeatureSessionRows(feature: .awake,
                                       lockHelp: "Pause lets the display sleep while locked; the Mac stays awake.")
                }

                Section("Power") {
                    Picker("End below battery", selection: $state.config.batteryCutoff) {
                        Text("Never").tag(0)
                        Divider()
                        ForEach([5, 10, 15, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .help("On battery, turns Awake off below this level.")
                    Picker("Lock screen when idle for", selection: $state.config.lockAfterIdle) {
                        Text("Never").tag(TimeInterval(0))
                        Divider()
                        ForEach([60, 120, 300, 600, 900, 1800], id: \.self) { Text(Summary.duration($0)).tag(TimeInterval($0)) }
                    }
                    .help("While Awake is on, locks the screen after this long without real input.")
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
                    .help("Writes a tiny hidden file to the drive once a minute while Awake is on.")
                }

                FeatureShortcutSection(feature: .awake)
            }
        }
    }
}

/// Everything about simulated activity that isn't on the main card.
struct DriftPage: View {
    @EnvironmentObject var state: AppState
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Drift", back: back)
            FittedForm(topEdge: 4) {
                Section("Movement") { MovementRows() }
                Section("Extra Activity") { ActivityRows() }
                Section("Session") {
                    LengthRows(feature: .drift, title: "Run for")
                    FeatureSessionRows(feature: .drift, lockHelp: "Pause stops simulated activity while the screen is locked.")
                }
                FeatureShortcutSection(feature: .drift)
            }
        }
    }
}

/// The two session settings both features have, each set on its own page.
struct FeatureSessionRows: View {
    @EnvironmentObject var state: AppState
    let feature: Feature
    let lockHelp: String

    var body: some View {
        let settings = Config.settings(feature)
        Picker("When the screen is locked", selection: $state.config[dynamicMember: settings.appending(path: \.whenLocked)]) {
            Text("Pause").tag(LockBehavior.pause)
            Text("Keep going").tag(LockBehavior.keepGoing)
        }
        .help(lockHelp)
        Toggle("Notify when it turns off", isOn: $state.config[dynamicMember: settings.appending(path: \.notify)])
            .help("When its time runs out or its trigger stops matching.")
    }
}

struct FeatureShortcutSection: View {
    @EnvironmentObject var state: AppState
    let feature: Feature

    var body: some View {
        Section("Shortcut") {
            LabeledContent("Turn \(feature.title) on or off") {
                ShortcutRecorder(shortcut: $state.config[dynamicMember: Config.settings(feature).appending(path: \.shortcut)],
                                 defaultShortcut: feature == .awake ? .awakeDefault : .driftDefault)
            }
        }
    }
}
