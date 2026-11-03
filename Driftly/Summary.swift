import AppKit
import SwiftUI

/// One-line summaries shown under each collapsed section, plus shared labels.
enum Summary {
    static func duration(_ s: Int) -> String {
        s < 60 ? "\(s) sec" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h"
    }

    /// Compact form for one-line summaries: 30s, 5m, 2h.
    static func short(_ s: TimeInterval) -> String {
        let s = Int(s)
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
    }

    /// "1:24:10" with seconds, "1:24" without.
    static func clock(_ t: TimeInterval, seconds: Bool) -> String {
        let s = Int(t.rounded(.up))
        return seconds ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                       : String(format: "%d:%02d", s / 3600, s / 60 % 60)
    }

    /// "6h 12m", "45m".
    static func total(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    static func time(_ t: ClockTime) -> String { String(format: "%02d:%02d", t.hour, t.minute) }

    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func length(_ l: SessionLength) -> String {
        switch l {
        case .indefinitely: "Indefinitely"
        case .minutes(let m): m < 60 ? "For \(m) minutes" : m == 60 ? "For 1 hour" : "For \(m / 60) hours"
        case .untilTime: "Until a time"
        }
    }

    static func modeHint(_ mode: MoveMode) -> String {
        switch mode {
        case .standard: "Straight, steady moves at exact intervals."
        case .natural: "Curved paths and varied timing that feel human."
        case .silent: "Keeps you active without moving the cursor."
        }
    }

    static func movement(_ c: Config) -> String {
        let every = c.interval == 0 ? "continuous" : "every \(short(c.interval))"
        return "After \(short(c.startAfterIdle)) · \(every)"
    }

    static func activity(_ c: Config) -> String {
        var parts: [String] = []
        if c.mode != .silent {
            switch c.clickType {
            case .none: break
            case .left, .right:
                parts.append("\(c.clickType.rawValue.capitalized) click" + (c.clickPoints.count > 1 ? " ×\(c.clickPoints.count)" : ""))
            case .both: parts.append("Alternating clicks")
            }
            if c.scroll != .none { parts.append("Scroll") }
        }
        if c.keyPress { parts.append("Key press") }
        return parts.isEmpty ? "Off" : parts.joined(separator: " · ")
    }

    static func days(_ d: Set<Int>) -> String {
        switch d {
        case [2, 3, 4, 5, 6]: "Weekdays"
        case [1, 7]: "Weekends"
        case Set(1...7): "Every day"
        default:
            [2, 3, 4, 5, 6, 7, 1].filter(d.contains)
                .map { Calendar.current.shortWeekdaySymbols[$0 - 1] }
                .joined(separator: ", ")
        }
    }

    static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func triggers(_ c: Config) -> String {
        let on = c.triggers.filter(\.enabled).count
        return c.triggers.isEmpty ? "None" : on == 0 ? "All off" : "\(on) on"
    }

    // MARK: Triggers

    static func title(_ kind: TriggerKind) -> String {
        switch kind {
        case .schedule: "Schedule"
        case .app: "App"
        case .power: "Power"
        case .display: "Display"
        case .device: "Device"
        case .network: "Network"
        case .audio: "Audio"
        case .drive: "Drive"
        case .download: "Download"
        case .cpu: "CPU busy"
        }
    }

    static func symbol(_ kind: TriggerKind) -> (String, Color) {
        switch kind {
        case .schedule: ("calendar", .pink)
        case .app: ("app.badge.checkmark", .blue)
        case .power: ("powerplug.fill", .green)
        case .display: ("display", .indigo)
        case .device: ("cable.connector", .orange)
        case .network: ("wifi", .cyan)
        case .audio: ("headphones", .purple)
        case .drive: ("externaldrive.fill", .gray)
        case .download: ("arrow.down.circle.fill", .teal)
        case .cpu: ("cpu", .red)
        }
    }

    /// The condition in words: "Zoom is running", "Mon–Fri · 09:00–17:30".
    static func condition(_ t: Trigger, natural: Bool = false) -> String {
        let approx = natural ? "≈" : ""
        switch t.kind {
        case .schedule: return "\(days(t.days)) · \(approx)\(time(t.from))–\(approx)\(time(t.to))"
        case .app:
            let name = t.bundleID.isEmpty ? "An app" : appName(t.bundleID)
            return t.frontOnly ? "\(name) is in front" : "\(name) is running"
        case .power:
            switch t.power {
            case .charger: return "Charger connected"
            case .battery: return "On battery"
            case .batteryAbove: return "Battery above \(t.batteryAbove)%"
            }
        case .display: return t.display == .external ? "External display connected" : "Screen mirroring on"
        case .device: return "\(t.name.isEmpty ? "A device" : t.name) connected"
        case .network: return t.network == .vpn ? "VPN connected" : "On \(t.name.isEmpty ? "a Wi-Fi network" : t.name)"
        case .audio: return "Playing through \(t.name.isEmpty ? "a device" : t.name)"
        case .drive: return "\(t.name.isEmpty ? "A drive" : t.name) mounted"
        case .download: return "Downloading to Downloads"
        case .cpu: return "CPU above \(t.cpuAbove)%"
        }
    }

    /// Header text while a triggered session runs.
    static func whileText(_ t: Trigger) -> String {
        if t.kind == .schedule { return "Until \(time(t.to)) · schedule" }
        let c = condition(t)
        // App, device and drive conditions start with a name; keep its capital.
        let named: Set<TriggerKind> = [.app, .device, .drive]
        return "While " + (named.contains(t.kind) ? c : c.prefix(1).lowercased() + c.dropFirst())
    }
}
