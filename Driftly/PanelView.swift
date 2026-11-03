import AppKit
import SwiftUI

enum PanelPage: Hashable {
    case onboarding, main, settings, triggers
    case editTrigger(UUID?)   // nil adds a new one

    /// How deep the page sits, so slides go the right way.
    var depth: Int {
        switch self {
        case .onboarding, .main: 0
        case .settings, .triggers: 1
        case .editTrigger: 2
        }
    }
}

/// The whole app UI: one menu-bar panel. Settings and Triggers slide in over the main page.
struct PanelView: View {
    @State var page: PanelPage
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(initialPage: PanelPage? = nil) {
        _page = State(initialValue: initialPage ?? (Onboarding.isComplete ? .main : .onboarding))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch page {
                case .onboarding:
                    OnboardingPage(done: {
                        Onboarding.finish()
                        go(.main)
                    })
                case .main:
                    MainPage(openSettings: { go(.settings) }, openTriggers: { go(.triggers) })
                case .settings:
                    SettingsPage(back: { go(.main) })
                case .triggers:
                    TriggersPage(back: { go(.main) }, edit: { go(.editTrigger($0)) })
                case .editTrigger(let id):
                    TriggerEditor(id: id, done: { go(.triggers) })
                }
            }
            .id(page)
            .transition(transition)
        }
        .frame(width: Metrics.width)
        .clipped()
        .focusEffectDisabled()   // no focus ring on the first control when the panel opens
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                           removal: .move(edge: forward ? .leading : .trailing)).combined(with: .opacity)
    }

    private func go(_ next: PanelPage) {
        forward = next.depth >= page.depth
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.28)) { page = next }
    }
}

// MARK: - Main page

struct MainPage: View {
    @EnvironmentObject var state: AppState
    let openSettings: () -> Void
    let openTriggers: () -> Void

    @AppStorage("open.movement") private var movementOpen = false
    @AppStorage("open.activity") private var activityOpen = false

    var body: some View {
        VStack(spacing: 0) {
            FittedForm {
                Section {
                    StatusRow()
                }

                Section {
                    SessionRows()
                }

                Section {
                    Toggle(isOn: $state.config.simulateActivity) {
                        SectionLabel(symbol: "cursorarrow.motionlines", tint: .blue, title: "Simulate activity",
                                     summary: activitySummary)
                    }
                    if state.config.simulateActivity {
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
                        DisclosureGroup(isExpanded: $movementOpen) { MovementRows() } label: {
                            DisclosureSummary(title: "Movement", value: Summary.movement(state.config))
                        }
                        DisclosureGroup(isExpanded: $activityOpen) { ActivityRows() } label: {
                            DisclosureSummary(title: "Extra activity", value: Summary.activity(state.config))
                        }
                    }
                }

                Section {
                    Button(action: openTriggers) {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Text(Summary.triggers(state.config))
                                Image(systemName: "chevron.right").imageScale(.small)
                            }
                            .foregroundStyle(.secondary)
                        } label: {
                            Label { Text("Triggers") } icon: { IconTile(symbol: "bolt.fill", tint: .green) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Start sessions automatically")
                }
            }

            Divider()
            HStack(spacing: 12) {
                Text("\(state.config.shortcut.display) starts or ends a session")
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

    /// Live state while a session runs, otherwise what the feature is for.
    private var activitySummary: String {
        // Missing permission has its own row below, so it isn't repeated here.
        guard state.config.simulateActivity, state.canPost else { return "Keeps chat apps showing you as active" }
        return state.isActive && !state.activityStatus.isEmpty ? state.activityStatus : "Starts with each session"
    }
}

/// Disclosure row label: title, then a one-line secondary value at the trailing edge.
struct DisclosureSummary: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title).layoutPriority(1)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Top row in the Wi‑Fi / Bluetooth style: session gauge, state, master switch.
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
            .animation(.linear(duration: 0.25), value: state.ringProgress)
            .accessibilityLabel(state.isActive ? "Session time left" : "No session")
            .accessibilityValue(Text("\(Int(state.ringProgress * 100)) percent"))

            VStack(alignment: .leading, spacing: 1) {
                Text(state.isActive ? "Awake" : "Driftly").font(.headline)
                Text(state.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            Toggle("Keep awake", isOn: Binding(get: { state.isActive }, set: { _ in state.toggle() }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// How long a session lasts and what happens to the display.
struct SessionRows: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Picker(selection: $state.config.length) {
            Text("Indefinitely").tag(SessionLength.indefinitely)
            Divider()
            ForEach(SessionLength.presets, id: \.self) { Text(Summary.length($0)).tag($0) }
            Divider()
            Text("Until a time").tag(SessionLength.untilTime)
        } label: {
            Label { Text("Keep awake") } icon: { IconTile(symbol: "clock.fill", tint: .orange) }
        }
        .help(state.isActive ? "Changing this restarts the countdown from now." : "Applies when you start a session.")
        if state.config.length == .untilTime {
            DatePicker("Until", selection: clockBinding($state.config.untilTime), displayedComponents: .hourAndMinute)
        }
        Picker(selection: $state.config.display) {
            Text("Stays on").tag(DisplayMode.stayOn)
            Text("Can sleep").tag(DisplayMode.canSleep)
        } label: {
            Label { Text("Display") } icon: { IconTile(symbol: "display", tint: .indigo) }
        }
        .help("With Can sleep, the screen turns off as usual but the Mac stays awake.")
    }
}

/// Binds a DatePicker (hour and minute) to a ClockTime.
func clockBinding(_ time: Binding<ClockTime>) -> Binding<Date> {
    Binding(
        get: { Calendar.current.date(bySettingHour: time.wrappedValue.hour, minute: time.wrappedValue.minute,
                                     second: 0, of: Date()) ?? Date() },
        set: {
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            time.wrappedValue = ClockTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
        })
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
