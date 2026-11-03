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
        case .eye: "Eye"
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

/// Driftly's two features: Awake holds off sleep, Drift simulates activity. Each runs on its own.
enum Feature: String, Codable, CaseIterable, Identifiable {
    case awake, drift
    var id: Self { self }
    var title: String { self == .awake ? "Awake" : "Drift" }
}

/// What a trigger turns on.
enum FeatureTarget: String, Codable, CaseIterable, Identifiable {
    case awake, drift, both
    var id: Self { self }
    func includes(_ f: Feature) -> Bool { self == .both || rawValue == f.rawValue }
}

/// Which feature lights up the menu-bar icon.
enum IconSource: String, Codable, CaseIterable, Identifiable {
    case either, awake, drift
    var id: Self { self }
}

/// Settings both features have, each set separately.
struct FeatureSettings: Codable, Equatable {
    var length: SessionLength = .indefinitely
    var untilTime = ClockTime(hour: 17, minute: 30)
    var whenLocked: LockBehavior = .pause
    var notify = true
    var shortcut: Shortcut
    var wasOn = false                        // restored on launch
}

/// Everything the user can configure. Persisted as JSON in UserDefaults.
struct Config: Codable, Equatable {
    var awake = FeatureSettings(shortcut: .awakeDefault)
    var drift = FeatureSettings(notify: false, shortcut: .driftDefault)
    var triggers: [Trigger] = []

    // Awake
    var display: DisplayMode = .stayOn
    var showTimeLeft = true
    var lockAfterIdle: TimeInterval = 0      // 0 = never
    var batteryCutoff = 5                    // % — turn Awake off on battery below this; 0 = never
    var keepDriveName: String?
    var keepDriveBookmark: Data?

    // Drift
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
    var iconFor: IconSource = .either
    var dimWhenIdle = true

    // General
    var launchAtLogin = false

    var mode: MoveMode {
        get { silentMode ? .silent : naturalMode ? .natural : .standard }
        set {
            silentMode = newValue == .silent
            naturalMode = newValue == .natural
        }
    }

    static func settings(_ f: Feature) -> WritableKeyPath<Config, FeatureSettings> {
        f == .awake ? \.awake : \.drift
    }

    subscript(f: Feature) -> FeatureSettings {
        get { self[keyPath: Self.settings(f)] }
        set { self[keyPath: Self.settings(f)] = newValue }
    }

    private static let key = "config.v3"
    private static let legacyKeys = ["config.v2", "config.v1"]

    /// Decodes whatever is stored over the defaults, so settings added in later versions
    /// don't reset everything else. An older config is migrated once.
    static func load() -> Config {
        let defaults = UserDefaults.standard
        let current = defaults.data(forKey: key)
        guard let data = current ?? legacyKeys.lazy.compactMap({ defaults.data(forKey: $0) }).first,
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = jsonObject(Config()),
              let merged = try? JSONSerialization.data(withJSONObject: merge(base, stored)),
              var config = try? JSONDecoder().decode(Config.self, from: merged)
        else { return Config() }
        if current == nil {
            if let legacy = try? JSONDecoder().decode(LegacyConfig.self, from: data) { config.migrate(legacy) }
            config.save()
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    /// Stored values win. Awake's and Drift's settings and each trigger are merged one level
    /// deeper; values inside them (like a length) are taken whole, since enums encode as objects.
    private static func merge(_ base: [String: Any], _ stored: [String: Any], deep: Bool = true) -> [String: Any] {
        var out = base
        for (k, v) in stored {
            if deep, let b = base[k] as? [String: Any], let s = v as? [String: Any], b["shortcut"] != nil {
                out[k] = merge(b, s, deep: false)
            } else if k == "triggers", let list = v as? [[String: Any]], let t = jsonObject(Trigger(kind: .schedule)) {
                out[k] = list.map { merge(t, $0, deep: false) }
            } else {
                out[k] = v
            }
        }
        return out
    }

    /// v1 had Schedule, App Rules and Auto-stop beside the switch; v2 ran one session with
    /// activity simulation inside it. Both become Awake, plus Drift where activity was on.
    private mutating func migrate(_ old: LegacyConfig) {
        let drifted = old.simulateActivity ?? true
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
        for i in triggers.indices { triggers[i].target = drifted ? .both : .awake }
        if old.preventSleep == false { display = .canSleep }
        let locked: LockBehavior? = old.whenLocked ?? (old.pauseWhenLocked == false ? .keepGoing : nil)
        if let locked { awake.whenLocked = locked; drift.whenLocked = locked }
        if old.deactivateEnabled == true, old.deactivateKind == "after", let after = old.deactivateAfter {
            awake.length = .minutes(Int(after / 60))
            drift.length = awake.length
        }
        if let length = old.length { awake.length = length; drift.length = length }
        if let until = old.untilTime { awake.untilTime = until; drift.untilTime = until }
        if let notify = old.notifyOnEnd { awake.notify = notify }
        if old.wasActive == true { awake.wasOn = true; drift.wasOn = drifted }
        // The old shortcut started the whole session, which is Awake now.
        if let s = old.shortcut, s != .driftDefault { awake.shortcut = s }
    }
}

private struct LegacyConfig: Decodable {
    // v1
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
    // v1 and v2
    var wasActive: Bool?
    var shortcut: Shortcut?
    // v2
    var simulateActivity: Bool?
    var length: SessionLength?
    var untilTime: ClockTime?
    var whenLocked: LockBehavior?
    var notifyOnEnd: Bool?
}
