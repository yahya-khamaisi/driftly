import AppKit

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

    static func time(_ t: ClockTime) -> String { String(format: "%02d:%02d", t.hour, t.minute) }

    static func modeHint(_ mode: MoveMode) -> String {
        switch mode {
        case .standard: "Straight, steady moves at exact intervals."
        case .natural: "Curved paths and varied timing that feel human."
        case .silent: "Keeps you active without moving the cursor."
        }
    }

    static func movement(_ c: Config) -> String {
        if c.mode == .silent { return "After \(short(c.startAfterIdle)) idle · no visible movement" }
        let every = c.interval == 0 ? "continuous" : "every \(short(c.interval))"
        return "After \(short(c.startAfterIdle)) idle · \(every) · \(c.range.rawValue.capitalized)"
    }

    static func activity(_ c: Config) -> String {
        var parts: [String] = []
        switch c.clickType {
        case .none: break
        case .left, .right:
            parts.append("\(c.clickType.rawValue.capitalized) click" + (c.clickPoints.count > 1 ? " ×\(c.clickPoints.count)" : ""))
        case .both: parts.append("Alternating clicks")
        }
        if c.scroll != .none && c.mode != .silent { parts.append("Scroll") }
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

    static func schedule(_ c: Config) -> String {
        var parts: [String] = []
        let approx = c.mode == .natural ? "≈" : ""
        if c.scheduleEnabled {
            parts.append("\(days(c.scheduleDays)) \(approx)\(time(c.scheduleFrom))–\(approx)\(time(c.scheduleTo))")
        }
        if c.deactivateEnabled {
            parts.append(c.deactivateKind == .at ? "stops \(approx)\(time(c.deactivateAt))"
                                                 : "stops after \(short(c.deactivateAfter))")
        }
        return parts.isEmpty ? "Off" : parts.joined(separator: " · ")
    }

    static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func apps(_ c: Config) -> String {
        guard c.appRuleEnabled, let first = c.appBundleIDs.first else { return "Off" }
        let names = appName(first) + (c.appBundleIDs.count > 1 ? " +\(c.appBundleIDs.count - 1)" : "")
        switch c.appRule {
        case .isRunning: return "While \(names) is running"
        case .inFront: return "While \(names) is in front"
        case .notInFront: return "Paused while \(names) is in front"
        }
    }
}
