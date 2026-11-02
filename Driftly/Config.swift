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

enum AppRule: String, Codable, CaseIterable, Identifiable {
    case isRunning, inFront, notInFront
    var id: Self { self }
}

enum DeactivateKind: String, Codable, CaseIterable, Identifiable {
    case at, after
    var id: Self { self }
}

struct ClockTime: Codable, Equatable {
    var hour: Int
    var minute: Int
    var minutes: Int { hour * 60 + minute }
}

/// Everything the user can configure. Persisted as JSON in UserDefaults.
struct Config: Codable, Equatable {
    // Modes
    var naturalMode = false
    var silentMode = false

    // Core
    var startAfterIdle: TimeInterval = 30
    var interval: TimeInterval = 10          // 0 = continuous
    var range: MovementRange = .medium
    var clickType: ClickType = .none
    var clickPoints: [CGPoint] = []         // global CG coordinates (top-left origin)
    var scroll: ScrollAxis = .none
    var keyPress = false

    // Schedule
    var scheduleEnabled = false
    var scheduleFrom = ClockTime(hour: 9, minute: 0)
    var scheduleTo = ClockTime(hour: 18, minute: 0)
    var scheduleDays: Set<Int> = [2, 3, 4, 5, 6]   // Calendar weekday, 1 = Sunday

    // Deactivate
    var deactivateEnabled = false
    var deactivateKind: DeactivateKind = .at
    var deactivateAt = ClockTime(hour: 18, minute: 0)
    var deactivateAfter: TimeInterval = 3600

    // Only While App
    var appRuleEnabled = false
    var appRule: AppRule = .isRunning
    var appBundleIDs: [String] = []

    // System
    var pauseWhenLocked = true
    var preventSleep = false
    var batteryCutoff = 5                    // % — deactivate when on battery and below this; 0 = off
    var launchAtLogin = false
    var wasActive = false                    // restored on launch ("if it was already active")
    var menuIcon: MenuIcon = .cursor
    var dimWhenIdle = true
    var shortcut = Shortcut.default

    var mode: MoveMode {
        get { silentMode ? .silent : naturalMode ? .natural : .standard }
        set {
            silentMode = newValue == .silent
            naturalMode = newValue == .natural
        }
    }

    private static let key = "config.v1"

    static func load() -> Config {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
