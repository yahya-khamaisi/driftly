import AppKit
import SwiftUI

enum PanelPage: Hashable {
    case onboarding, main, awake, drift, settings, triggers
    case editTrigger(UUID?)   // nil adds a new one

    /// How deep the page sits, so slides go the right way.
    var depth: Int {
        switch self {
        case .onboarding, .main: 0
        case .awake, .drift, .settings, .triggers: 1
        case .editTrigger: 2
        }
    }
}

/// The whole app UI: one menu-bar panel. Option pages, Triggers and Settings slide in over the main page.
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
                    MainPage(open: go)
                case .awake:
                    AwakePage(back: { go(.main) })
                case .drift:
                    DriftPage(back: { go(.main) })
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

/// Two cards of the same shape, Awake and Drift, then Triggers.
struct MainPage: View {
    @EnvironmentObject var state: AppState
    let open: (PanelPage) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FittedForm {
                Section {
                    FeatureHeader(feature: .awake)
                    LengthRows(feature: .awake, title: "Duration", icon: ("clock.fill", .orange))
                    Picker(selection: $state.config.display) {
                        Text("Stays on").tag(DisplayMode.stayOn)
                        Text("Can sleep").tag(DisplayMode.canSleep)
                    } label: {
                        Label { Text("Display") } icon: { IconTile(symbol: "display", tint: .indigo) }
                    }
                    .help("With Can sleep, the screen turns off as usual but the Mac stays awake.")
                    NavigationRow(title: "Awake options", symbol: "slider.horizontal.3", tint: .gray) { open(.awake) }
                }

                Section {
                    FeatureHeader(feature: .drift)
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
                                IconTile(symbol: "exclamationmark.triangle.fill", tint: .yellow)
                            }
                        }
                    }
                    Picker(selection: $state.config.mode) {
                        Text("Standard").tag(MoveMode.standard)
                        Text("Natural").tag(MoveMode.natural)
                        Text("Silent").tag(MoveMode.silent)
                    } label: {
                        Label { Text("Style") } icon: { IconTile(symbol: "wand.and.stars", tint: .teal) }
                    }
                    .help(Summary.modeHint(state.config.mode))
                    LabeledContent {
                        Text(Summary.movement(state.config))
                    } label: {
                        Label { Text("Movement") } icon: {
                            IconTile(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", tint: .blue)
                        }
                    }
                    NavigationRow(title: "Drift options", symbol: "slider.horizontal.3", tint: .gray) { open(.drift) }
                }

                Section {
                    NavigationRow(title: "Triggers", symbol: "bolt.fill", tint: .pink,
                                  value: Summary.triggers(state.config)) { open(.triggers) }
                        .accessibilityHint("Turn Awake or Drift on automatically")
                }
            }

            Divider()
            HStack(spacing: 12) {
                Text("\(state.config.awake.shortcut.display) Awake · \(state.config.drift.shortcut.display) Drift")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                FooterButton(symbol: "gearshape", label: "Settings") { open(.settings) }
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

/// Top row of each feature card, in the Wi‑Fi / Bluetooth style: ring, name, state, switch.
struct FeatureHeader: View {
    @EnvironmentObject var state: AppState
    let feature: Feature

    var body: some View {
        let s = state[feature]
        HStack(spacing: 10) {
            Gauge(value: s.progress) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: symbol(on: s.isOn))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(s.isOn ? Color.accentColor : Color.secondary)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(s.isOn ? Color.accentColor : Color.secondary)
            .scaleEffect(0.62)
            .frame(width: 36, height: 36)
            .animation(.linear(duration: 0.25), value: s.progress)
            .accessibilityLabel(s.isOn ? "\(feature.title) time left" : "\(feature.title) off")
            .accessibilityValue(Text("\(Int(s.progress * 100)) percent"))

            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title).font(.headline)
                Text(s.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            Toggle(feature.title, isOn: Binding(get: { s.isOn }, set: { _ in state.toggle(feature) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func symbol(on: Bool) -> String {
        switch feature {
        case .awake: on ? "sun.max.fill" : "sun.max"
        case .drift: on ? "cursorarrow.motionlines" : "cursorarrow"
        }
    }
}

/// How long a feature stays on when turned on by hand, plus the time for "Until a time".
struct LengthRows: View {
    @EnvironmentObject var state: AppState
    let feature: Feature
    let title: String
    var icon: (String, Color)?

    var body: some View {
        let settings = Config.settings(feature)
        Picker(selection: $state.config[dynamicMember: settings.appending(path: \.length)]) {
            Text(Summary.length(.indefinitely)).tag(SessionLength.indefinitely)
            Divider()
            ForEach(SessionLength.presets, id: \.self) { Text(Summary.length($0)).tag($0) }
            Divider()
            Text(Summary.length(.untilTime)).tag(SessionLength.untilTime)
        } label: {
            if let icon {
                Label { Text(title) } icon: { IconTile(symbol: icon.0, tint: icon.1) }
            } else {
                Text(title)
            }
        }
        .help(state[feature].isOn ? "Changing this restarts the countdown from now." : "Applies when you turn \(feature.title) on.")
        if state.config[feature].length == .untilTime {
            DatePicker("Until", selection: clockBinding($state.config[dynamicMember: settings.appending(path: \.untilTime)]),
                       displayedComponents: .hourAndMinute)
        }
    }
}

/// A row that opens another page: icon tile, title, optional value, chevron.
struct NavigationRow: View {
    let title: String
    let symbol: String
    let tint: Color
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    if let value { Text(value) }
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .foregroundStyle(.secondary)
            } label: {
                Label { Text(title) } icon: { IconTile(symbol: symbol, tint: tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
