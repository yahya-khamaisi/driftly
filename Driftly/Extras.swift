import AppKit
import UserNotifications

/// "Session ended" notifications.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: content, trigger: nil))
    }
}

/// Keeps an external drive spinning by touching a small hidden file on it once a minute.
/// The drive is chosen in an open panel, so the sandbox grants access through a bookmark.
enum DriveKeeper {
    static let interval: TimeInterval = 60
    private static let fileName = ".driftly-keepalive"

    /// Lets the user pick a drive; returns its name and a security-scoped bookmark.
    @MainActor static func choose() -> (name: String, bookmark: Data)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.prompt = "Keep Awake"
        panel.message = "Choose the drive Driftly should keep awake during sessions."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
        else { return nil }
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
        return (name, bookmark)
    }

    static func touch(_ bookmark: Data) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        try? Data(Date().description.utf8).write(to: url.appendingPathComponent(fileName))
    }
}

/// Time spent awake per day, kept for the last 60 days.
struct Stats: Codable {
    private var seconds: [String: TimeInterval] = [:]
    private var sessions: [String: Int] = [:]
    private static let key = "stats.v1"

    static func load() -> Stats {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Stats.self, from: $0) } ?? Stats()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    mutating func add(_ dt: TimeInterval, at date: Date) { seconds[Self.day(date), default: 0] += dt }

    mutating func countSession(at date: Date) {
        sessions[Self.day(date), default: 0] += 1
        let keep = Set((0..<60).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: date) }.map(Self.day))
        seconds = seconds.filter { keep.contains($0.key) }
        sessions = sessions.filter { keep.contains($0.key) }
    }

    func today(_ now: Date = Date()) -> (time: TimeInterval, sessions: Int) {
        (seconds[Self.day(now)] ?? 0, sessions[Self.day(now)] ?? 0)
    }

    /// Since the start of this calendar week.
    func thisWeek(_ now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        let days = cal.dateComponents([.day], from: start, to: now).day ?? 0
        return (0...days).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
            .reduce(0) { $0 + (seconds[Self.day($1)] ?? 0) }
    }
}

struct StatsSnapshot: Equatable {
    var today: TimeInterval = 0
    var sessions = 0
    var week: TimeInterval = 0
}
