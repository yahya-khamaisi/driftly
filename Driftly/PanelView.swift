import AppKit
import SwiftUI

enum PanelPage { case onboarding, main, settings }

/// The whole app UI: one menu-bar panel. Settings slides in over the main page.
struct PanelView: View {
    @State var page: PanelPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(initialPage: PanelPage? = nil) {
        _page = State(initialValue: initialPage ?? (Onboarding.isComplete ? .main : .onboarding))
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .onboarding:
                OnboardingPage(done: {
                    Onboarding.finish()
                    go(.main)
                })
                .transition(.opacity)
            case .main:
                MainPage(openSettings: { go(.settings) })
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            case .settings:
                SettingsPage(back: { go(.main) })
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: Metrics.width)
        .clipped()
        .focusEffectDisabled()   // no focus ring on the first control when the panel opens
    }

    private func go(_ next: PanelPage) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.28)) { page = next }
    }
}

// MARK: - Main page

struct MainPage: View {
    @EnvironmentObject var state: AppState
    let openSettings: () -> Void

    @AppStorage("open.movement") private var movementOpen = true
    @AppStorage("open.activity") private var activityOpen = false
    @AppStorage("open.schedule") private var scheduleOpen = false
    @AppStorage("open.apps") private var appsOpen = false

    var body: some View {
        VStack(spacing: 0) {
            FittedForm {
                Section {
                    StatusRow()
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Mode", selection: $state.config.mode) {
                            Text("Standard").tag(MoveMode.standard)
                            Text("Natural").tag(MoveMode.natural)
                            Text("Silent").tag(MoveMode.silent)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(Summary.modeHint(state.config.mode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !state.canPost {
                        LabeledContent {
                            Button("Allow…") {
                                InputPoster.requestAccess()
                                Permissions.open(.accessibility)
                            }
                        } label: {
                            Label {
                                Text("Accessibility access needed")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.multicolor)
                            }
                        }
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $movementOpen) { MovementRows() } label: {
                        SectionLabel(symbol: "cursorarrow.motionlines", tint: .blue,
                                     title: "Movement", summary: Summary.movement(state.config))
                    }
                    DisclosureGroup(isExpanded: $activityOpen) { ActivityRows() } label: {
                        SectionLabel(symbol: "cursorarrow.click.2", tint: .purple,
                                     title: "Extra Activity", summary: Summary.activity(state.config))
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $scheduleOpen) { ScheduleRows() } label: {
                        SectionLabel(symbol: "calendar.badge.clock", tint: .green,
                                     title: "Schedule", summary: Summary.schedule(state.config))
                    }
                    DisclosureGroup(isExpanded: $appsOpen) { AppRuleRows() } label: {
                        SectionLabel(symbol: "app.badge.checkmark", tint: .orange,
                                     title: "App Rules", summary: Summary.apps(state.config))
                    }
                }
            }

            Divider()
            HStack(spacing: 12) {
                Text("\(state.config.shortcut.display) toggles Driftly")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                FooterButton(symbol: "gearshape", label: "Settings", action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                FooterButton(symbol: "power", label: "Quit Driftly") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            // Optical alignment: the caption's first glyph carries ~1pt of side bearing, and the
            // icons sit centred in 28pt hit targets (~4pt each side), so pull both onto the 30pt row edge.
            .padding(.leading, Metrics.contentInset - 1)
            .padding(.trailing, Metrics.contentInset - 6)
            .padding(.vertical, 6)
        }
    }
}

/// Top row in the Wi‑Fi / Bluetooth style: status gauge, name, state, master switch.
struct StatusRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Gauge(value: state.ringProgress) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: state.isActive ? state.config.menuIcon.active : state.config.menuIcon.idle)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(state.isActive ? Color.accentColor : Color.secondary)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(state.isActive ? Color.accentColor : Color.secondary)
            .scaleEffect(0.62)
            .frame(width: 36, height: 36)
            .animation(.linear(duration: 1), value: state.ringProgress)
            .accessibilityLabel(state.isActive ? "Time until next move" : "Driftly is off")
            .accessibilityValue(Text("\(Int(state.ringProgress * 100)) percent"))

            VStack(alignment: .leading, spacing: 1) {
                Text("Driftly").font(.headline)
                Text(state.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer()
            Toggle("Driftly", isOn: Binding(get: { state.isActive }, set: { _ in state.toggle() }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - Section rows (all stock controls)

struct MovementRows: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Picker("Start after idle", selection: $state.config.startAfterIdle) {
            ForEach([5, 10, 30, 60, 120, 300, 600], id: \.self) { Text(Summary.duration($0)).tag(TimeInterval($0)) }
        }
        Picker("Move every", selection: $state.config.interval) {
            Text("Continuously").tag(TimeInterval(0))
            ForEach([5, 10, 30, 60, 120, 300], id: \.self) { Text(Summary.duration($0)).tag(TimeInterval($0)) }
        }
        Picker("Range", selection: $state.config.range) {
            Text("Small").tag(MovementRange.small)
            Text("Medium").tag(MovementRange.medium)
            Text("Full").tag(MovementRange.full)
        }
        .pickerStyle(.segmented)
        .disabled(state.config.mode == .silent)
        .help(state.config.mode == .silent
              ? "Silent mode doesn't move the cursor."
              : "Small stays within a few pixels, Medium wanders nearby, Full uses the whole screen.")
    }
}

struct ActivityRows: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Picker("Click", selection: $state.config.clickType) {
            Text("None").tag(ClickType.none)
            Divider()
            Text("Left").tag(ClickType.left)
            Text("Right").tag(ClickType.right)
            Text("Alternate").tag(ClickType.both)
        }
        .disabled(state.config.mode == .silent)
        .help(state.config.mode == .silent ? "Silent mode never clicks." : "Clicks at each position before moving away.")
        if state.config.clickType != .none && state.config.mode != .silent {
            LabeledContent("Positions") {
                HStack(spacing: 8) {
                    Text(state.config.clickPoints.isEmpty ? "At cursor" : "\(state.config.clickPoints.count) set")
                        .foregroundStyle(.secondary)
                    if !state.config.clickPoints.isEmpty {
                        Button("Clear") { state.config.clickPoints = [] }
                    }
                    Button("Add…") { state.addClickPoint() }
                }
            }
        }
        Picker("Scroll", selection: $state.config.scroll) {
            Text("None").tag(ScrollAxis.none)
            Divider()
            Text("Vertical").tag(ScrollAxis.vertical)
            Text("Horizontal").tag(ScrollAxis.horizontal)
            Text("Both").tag(ScrollAxis.both)
        }
        .disabled(state.config.mode == .silent)
        .help(state.config.mode == .silent ? "Silent mode never scrolls." : "Scrolls a little and back after each move.")
        Toggle("Key press", isOn: $state.config.keyPress)
            .help("A bare Control tap with each move. Types nothing.")
    }
}

struct ScheduleRows: View {
    @EnvironmentObject var state: AppState
    private let weekdays = [2, 3, 4, 5, 6, 7, 1]   // Mon…Sun

    var body: some View {
        Toggle("Active hours", isOn: $state.config.scheduleEnabled)
        if state.config.scheduleEnabled {
            DatePicker("From", selection: timeBinding(\.scheduleFrom), displayedComponents: .hourAndMinute)
            DatePicker("To", selection: timeBinding(\.scheduleTo), displayedComponents: .hourAndMinute)
            LabeledContent("Days") {
                Menu(Summary.days(state.config.scheduleDays)) {
                    ForEach(weekdays, id: \.self) { day in
                        Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: dayBinding(day))
                    }
                    Divider()
                    Button("Weekdays") { state.config.scheduleDays = [2, 3, 4, 5, 6] }
                    Button("Every Day") { state.config.scheduleDays = Set(1...7) }
                }
                .fixedSize()
            }
        }
        Toggle("Auto-stop", isOn: $state.config.deactivateEnabled)
        if state.config.deactivateEnabled {
            Picker("Stop", selection: $state.config.deactivateKind) {
                Text("At Time").tag(DeactivateKind.at)
                Text("After").tag(DeactivateKind.after)
            }
            .pickerStyle(.segmented)
            if state.config.deactivateKind == .at {
                DatePicker("Time", selection: timeBinding(\.deactivateAt), displayedComponents: .hourAndMinute)
            } else {
                Picker("Duration", selection: $state.config.deactivateAfter) {
                    ForEach([900, 1800, 3600, 7200, 10800, 14400, 21600, 28800, 43200], id: \.self) {
                        Text(Summary.duration($0)).tag(TimeInterval($0))
                    }
                }
            }
        }
    }

    private func timeBinding(_ kp: WritableKeyPath<Config, ClockTime>) -> Binding<Date> {
        Binding(
            get: {
                let t = state.config[keyPath: kp]
                return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                state.config[keyPath: kp] = ClockTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
            })
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(get: { state.config.scheduleDays.contains(day) },
                set: { on in
                    if on { state.config.scheduleDays.insert(day) } else { state.config.scheduleDays.remove(day) }
                })
    }
}

struct AppRuleRows: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Toggle("Only while app", isOn: $state.config.appRuleEnabled)
        if state.config.appRuleEnabled {
            Picker("When", selection: $state.config.appRule) {
                Text("Is running").tag(AppRule.isRunning)
                Text("Is in front").tag(AppRule.inFront)
                Text("Isn't in front").tag(AppRule.notInFront)
            }
            if state.config.appBundleIDs.isEmpty {
                Text("Add the apps Driftly should watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.appBundleIDs, id: \.self) { id in
                LabeledContent {
                    Button { state.config.appBundleIDs.removeAll { $0 == id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(Summary.appName(id))")
                    .accessibilityLabel("Remove \(Summary.appName(id))")
                } label: {
                    Label { Text(Summary.appName(id)) } icon: { AppIcon(bundleID: id) }
                }
            }
            LabeledContent("Apps") {
                Menu("Add App") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? "?") { add(app.bundleIdentifier) }
                    }
                    Divider()
                    Button("Choose…") { chooseApp() }
                }
                .fixedSize()
            }
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func add(_ id: String?) {
        if let id, !state.config.appBundleIDs.contains(id) { state.config.appBundleIDs.append(id) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { add(Bundle(url: url)?.bundleIdentifier) }
    }
}
