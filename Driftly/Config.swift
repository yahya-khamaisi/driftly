import Foundation
import CoreGraphics

/// Standard, Natural and Silent are exclusive: Silent never moves, so Natural's paths don't apply.
enum MoveMode: String, CaseIterable, Identifiable {
    case standard, natural, silent
    var id: Self { self }
}

/// Menu bar icon styles; each has an active and an idle symbol so the state is visible at a glance.
enum MenuIcon: String, Codable, CaseIterable, Identifiable {
    case cursor, mouse, path, pulse, eye, coffee, wave, power, dot
    var id: Self { self }

    var active: String {
        switch self {
        case .cursor: "cursorarrow.motionlines"
        case .mouse: "computermouse.fill"
        case .path: "point.topleft.down.to.point.bottomright.curvepath.fill"
        case .pulse: "waveform.path.ecg"
        case .eye: "eye"
        case .coffee: "cup.and.saucer.fill"
        case .wave: "water.waves"
        case .power: "bolt.fill"
        case .dot: "circle.inset.filled"
        }
    }

    var idle: String {
        switch self {
        case .cursor: "cursorarrow"
        case .mouse: "computermouse"
        case .path: "point.topleft.down.to.point.bottomright.curvepath"
        case .pulse: "waveform.path"
        case .eye: "eye.slash"
        case .coffee: "cup.and.saucer"
        case .wave: "water.waves"
        case .power: "bolt.slash"
        case .dot: "circle"
        }
    }

    var title: String {
        switch self {
        case .cursor: "Cursor in motion"
        case .mouse: "Mouse"
        case .path: "Drift path"
        case .pulse: "Keep-alive pulse"
        case .eye: "Awake"
        case .coffee: "Coffee"
        case .wave: "Wave"
        case .power: "Power"
        case .dot: "Dot"
        }
    }
}

enum MovementRange: String, Codable, CaseIterable, Identifiable {
    case small, medium, full
    var id: Self { self }
}

/// Click performed at each saved point (or at the cursor if none saved) before moving on.
/// `both` alternates right/left between cycles.
enum ClickType: String, Codable, CaseIterable, Identifiable {
    case none, left, right, both
    var id: Self { self }
}

enum ScrollAxis: String, Codable, CaseIterable, Identifiable {
    case none, vertical, horizontal, both
    var id: Self { self }
}

struct ClockTime: Codable, Hashable {
    var hour: Int
    var minute: Int
    var minutes: Int { hour * 60 + minute }
}

/// How long a manually started session lasts. Triggered sessions last while their trigger matches.
enum SessionLength: Codable, Hashable {
    case indefinitely
    case minutes(Int)
    case untilTime            // uses `Config.untilTime`

    static let presets: [SessionLength] = [.minutes(15), .minutes(30), .minutes(60), .minutes(120),
                                           .minutes(240), .minutes(480)]
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case stayOn, canSleep
    var id: Self { self }
}

enum LockBehavior: String, Codable, CaseIterable, Identifiable {
    case pause, keepGoing
    var id: Self { self }
}

/// Everything the user can configure. Persisted as JSON in UserDefaults.
struct Config: Codable, Equatable {
    // Session
    var length: SessionLength = .indefinitely
    var untilTime = ClockTime(hour: 17, minute: 30)
    var display: DisplayMode = .stayOn
    var triggers: [Trigger] = []

    // Simulate activity
    var simulateActivity = true
    var naturalMode = false
    var silentMode = false
    var startAfterIdle: TimeInterval = 30
    var interval: TimeInterval = 10          // 0 = continuous
    var range: MovementRange = .medium
    var clickType: ClickType = .none
    var clickPoints: [CGPoint] = []         // global CG coordinates (top-left origin)
    var scroll: ScrollAxis = .none
    var keyPress = false

    // Menu bar
    var menuIcon: MenuIcon = .cursor
    var showTimeLeft = true
    var dimWhenIdle = true

    // General
    var shortcut = Shortcut.default
    var launchAtLogin = false
    var notifyOnEnd = true
    var wasActive = false                    // restored on launch ("if it was already active")

    // Power
    var whenLocked: LockBehavior = .pause
    var lockAfterIdle: TimeInterval = 0      // 0 = never
    var batteryCutoff = 5                    // % — end the session on battery below this; 0 = never
    var keepDriveName: String?
    var keepDriveBookmark: Data?

    var mode: MoveMode {
        get { silentMode ? .silent : naturalMode ? .natural : .standard }
        set {
            silentMode = newValue == .silent
            naturalMode = newValue == .natural
        }
    }

    private static let key = "config.v2"
    private static let legacyKey = "config.v1"

    /// Decodes whatever is stored over the defaults, so settings added in later versions
    /// don't reset everything else. A v1 config is migrated once.
    static func load() -> Config {
        let defaults = UserDefaults.standard
        let current = defaults.data(forKey: key)
        guard let data = current ?? defaults.data(forKey: legacyKey),
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let baseData = try? JSONEncoder().encode(Config()),
              let base = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(stored) { $1 }),
              var config = try? JSONDecoder().decode(Config.self, from: merged)
        else { return Config() }
        if current == nil, let legacy = try? JSONDecoder().decode(LegacyConfig.self, from: data) {
            config.migrate(legacy)
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// v1 had Schedule, App Rules and Auto-stop beside the switch; they are triggers now.
    private mutating func migrate(_ old: LegacyConfig) {
        if old.scheduleEnabled == true {
            var t = Trigger(kind: .schedule)
            t.from = old.scheduleFrom ?? t.from
            t.to = old.scheduleTo ?? t.to
            t.days = old.scheduleDays ?? t.days
            triggers.append(t)
        }
        if old.appRuleEnabled == true, old.appRule != "notInFront" {
            for id in old.appBundleIDs ?? [] {
                var t = Trigger(kind: .app)
                t.bundleID = id
                t.frontOnly = old.appRule == "inFront"
                triggers.append(t)
            }
        }
        if old.preventSleep == false { display = .canSleep }
        if old.pauseWhenLocked == false { whenLocked = .keepGoing }
        if old.deactivateEnabled == true, old.deactivateKind == "after", let after = old.deactivateAfter {
            length = .minutes(Int(after / 60))
        }
    }
}

private struct LegacyConfig: Decodable {
    var scheduleEnabled: Bool?
    var scheduleFrom: ClockTime?
    var scheduleTo: ClockTime?
    var scheduleDays: Set<Int>?
    var appRuleEnabled: Bool?
    var appRule: String?
    var appBundleIDs: [String]?
    var preventSleep: Bool?
    var pauseWhenLocked: Bool?
    var deactivateEnabled: Bool?
    var deactivateKind: String?
    var deactivateAfter: TimeInterval?
}
