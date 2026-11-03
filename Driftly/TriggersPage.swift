import AppKit
import SwiftUI

/// The list of triggers: each turns Awake, Drift or both on while its condition is true.
struct TriggersPage: View {
    @EnvironmentObject var state: AppState
    let back: () -> Void
    let edit: (UUID?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Triggers", back: back)
            FittedForm(topEdge: 4) {
                Section {
                    if state.config.triggers.isEmpty {
                        Text("Turn Awake or Drift on automatically, for example during work hours or while an app is open.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($state.config.triggers) { $trigger in
                        TriggerRow(trigger: $trigger, natural: state.config.naturalMode, edit: { edit(trigger.id) },
                                   delete: { state.config.triggers.removeAll { $0.id == trigger.id } })
                    }
                    Button { edit(nil) } label: {
                        Label("Add Trigger…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text("A trigger turns its feature on while it matches, and off when it stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct TriggerRow: View {
    @Binding var trigger: Trigger
    let natural: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            Button(action: edit) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Summary.title(trigger.kind))
                        Text(Summary.condition(trigger, natural: natural))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } icon: {
                    TriggerIcon(trigger: trigger)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit trigger")
            TargetTag(target: trigger.target)
            Toggle(Summary.title(trigger.kind), isOn: $trigger.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

/// Which feature a trigger turns on, as a small tinted capsule.
struct TargetTag: View {
    let target: FeatureTarget
    var body: some View {
        let tint: Color = switch target {
        case .awake: .orange
        case .drift: .blue
        case .both: .secondary
        }
        Text(Summary.target(target))
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: .capsule)
            .accessibilityLabel("Turns on \(Summary.target(target))")
    }
}

/// The app's own icon for app triggers, a tinted symbol tile for everything else.
struct TriggerIcon: View {
    let trigger: Trigger
    var body: some View {
        if trigger.kind == .app, !trigger.bundleID.isEmpty {
            AppIcon(bundleID: trigger.bundleID).frame(width: 22, height: 22)
        } else {
            let (symbol, tint) = Summary.symbol(trigger.kind)
            IconTile(symbol: symbol, tint: tint)
        }
    }
}

// MARK: - Editor

/// Adds or edits one trigger: what it turns on, a condition and its options. How long and how
/// each feature runs is set on that feature's own page.
struct TriggerEditor: View {
    @EnvironmentObject var state: AppState
    let id: UUID?
    let done: () -> Void
    @State private var draft: Trigger
    @State private var devices: [String] = []
    @State private var outputs: [String] = []
    @State private var drives: [String] = []

    init(id: UUID?, done: @escaping () -> Void) {
        self.id = id
        self.done = done
        let existing = id.flatMap { id in AppState.shared.config.triggers.first { $0.id == id } }
        _draft = State(initialValue: existing ?? Trigger(kind: .schedule))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: id == nil ? "New Trigger" : "Edit Trigger", back: done)
            FittedForm(topEdge: 4) {
                Section {
                    Picker("Turns on", selection: $draft.target) {
                        ForEach(FeatureTarget.allCases) { Text(Summary.target($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Start when", selection: $draft.kind) {
                        ForEach(TriggerKind.allCases) { kind in
                            Label(Summary.title(kind), systemImage: Summary.symbol(kind).0).tag(kind)
                        }
                    }
                    options
                } footer: {
                    if let hint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if id != nil {
                    Section {
                        Button("Delete Trigger", role: .destructive) {
                            state.config.triggers.removeAll { $0.id == id }
                            done()
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button(id == nil ? "Add Trigger" : "Done", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isComplete)
            }
            .padding(.horizontal, Metrics.contentInset - 10)
            .padding(.vertical, 10)
        }
        .onAppear(perform: refreshLists)
        .onChange(of: draft.kind) { _, _ in refreshLists() }
    }

    @ViewBuilder private var options: some View {
        switch draft.kind {
        case .schedule:
            DatePicker("From", selection: clockBinding($draft.from), displayedComponents: .hourAndMinute)
            DatePicker("To", selection: clockBinding($draft.to), displayedComponents: .hourAndMinute)
            DaysMenu(days: $draft.days)
        case .app:
            LabeledContent("App") {
                Menu {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? "?") { draft.bundleID = app.bundleIdentifier ?? "" }
                    }
                    Divider()
                    Button("Choose…", action: chooseApp)
                } label: {
                    Text(draft.bundleID.isEmpty ? "Choose" : Summary.appName(draft.bundleID))
                }
                .fixedSize()
            }
            Picker("Condition", selection: $draft.frontOnly) {
                Text("Is running").tag(false)
                Text("Is in front").tag(true)
            }
        case .power:
            Picker("Condition", selection: $draft.power) {
                Text("Charger connected").tag(PowerCondition.charger)
                Text("On battery").tag(PowerCondition.battery)
                Text("Battery above").tag(PowerCondition.batteryAbove)
            }
            if draft.power == .batteryAbove {
                Picker("Battery above", selection: $draft.batteryAbove) {
                    ForEach([20, 30, 40, 50, 60, 70, 80, 90], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
        case .display:
            Picker("Condition", selection: $draft.display) {
                Text("External display connected").tag(DisplayCondition.external)
                Text("Screen mirroring on").tag(DisplayCondition.mirroring)
            }
        case .device:
            NamePicker(title: "Device", empty: "No devices connected", names: devices, name: $draft.name)
        case .network:
            Picker("Condition", selection: $draft.network) {
                Text("Wi-Fi network").tag(NetworkCondition.wifi)
                Text("VPN connected").tag(NetworkCondition.vpn)
            }
            if draft.network == .wifi {
                LabeledContent("Network") {
                    HStack(spacing: 6) {
                        TextField("Network", text: $draft.name, prompt: Text("Office Wi-Fi"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        Button("Use Current") {
                            LocationAccess.shared.request { draft.name = TriggerProbes.wifiName() ?? draft.name }
                        }
                    }
                }
            }
        case .audio:
            NamePicker(title: "Output", empty: "No output devices", names: outputs, name: $draft.name)
        case .drive:
            NamePicker(title: "Drive", empty: "No drives connected", names: drives, name: $draft.name)
        case .download:
            EmptyView()
        case .cpu:
            Picker("Above", selection: $draft.cpuAbove) {
                ForEach([25, 50, 75, 90], id: \.self) { Text("\($0)%").tag($0) }
            }
        }
    }

    private var hint: String? {
        switch draft.kind {
        case .schedule: "Overnight hours, like 22:00–06:00, work too."
        case .app: nil
        case .power: "Desktop Macs always count as connected to a charger."
        case .display: nil
        case .device: "USB and Bluetooth devices that are connected now."
        case .network: draft.network == .wifi ? "Reading the Wi-Fi name needs Location access." : "Any VPN that routes IPv4 traffic."
        case .audio: "Matches while this device is the sound output."
        case .drive: "External and network drives that are mounted now."
        case .download: "Runs while a browser saves files to your Downloads folder, and ends 30 seconds after the last one finishes."
        case .cpu: "Useful for long builds and exports."
        }
    }

    private func refreshLists() {
        switch draft.kind {
        case .device: devices = TriggerProbes.connectedDevices()
        case .audio: outputs = TriggerProbes.outputDevices()
        case .drive: drives = TriggerProbes.mountedDrives()
        default: break
        }
    }

    private func save() {
        if let i = state.config.triggers.firstIndex(where: { $0.id == draft.id }) {
            state.config.triggers[i] = draft
        } else {
            state.config.triggers.append(draft)
        }
        done()
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            draft.bundleID = id
        }
    }
}

/// A pop-up of names found on this Mac, keeping a saved name that isn't present right now.
struct NamePicker: View {
    let title: String
    let empty: String
    let names: [String]
    @Binding var name: String

    var body: some View {
        let all = name.isEmpty || names.contains(name) ? names : [name] + names
        if all.isEmpty {
            LabeledContent(title) { Text(empty).foregroundStyle(.secondary) }
        } else {
            Picker(title, selection: $name) {
                if name.isEmpty { Text("Choose").tag("") }
                ForEach(all, id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

/// Weekday checkmarks, with quick picks for weekdays and every day.
struct DaysMenu: View {
    @Binding var days: Set<Int>
    private let weekdays = [2, 3, 4, 5, 6, 7, 1]   // Mon…Sun

    var body: some View {
        LabeledContent("Days") {
            Menu(Summary.days(days)) {
                ForEach(weekdays, id: \.self) { day in
                    Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(
                        get: { days.contains(day) },
                        set: { if $0 { days.insert(day) } else { days.remove(day) } }))
                }
                Divider()
                Button("Weekdays") { days = [2, 3, 4, 5, 6] }
                Button("Every Day") { days = Set(1...7) }
            }
            .fixedSize()
        }
    }
}
