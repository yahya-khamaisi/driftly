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
        panel.message = "Choose the drive Driftly should keep awake while Awake is on."
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

/// Time each feature was on per day, kept for the last 60 days.
struct Stats: Codable {
    private var seconds: [String: TimeInterval] = [:]          // Awake
    private var driftSeconds: [String: TimeInterval] = [:]
    private static let key = "stats.v1"
    private enum CodingKeys: String, CodingKey { case seconds, driftSeconds }

    init() {}

    /// Tolerates older saves, which had only Awake time.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try c.decodeIfPresent([String: TimeInterval].self, forKey: .seconds) ?? [:]
        driftSeconds = try c.decodeIfPresent([String: TimeInterval].self, forKey: .driftSeconds) ?? [:]
    }

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

    private func days(_ f: Feature) -> [String: TimeInterval] { f == .awake ? seconds : driftSeconds }

    mutating func add(_ dt: TimeInterval, _ f: Feature, at date: Date) {
        if f == .awake { seconds[Self.day(date), default: 0] += dt } else { driftSeconds[Self.day(date), default: 0] += dt }
    }

    mutating func prune(at date: Date) {
        let keep = Set((0..<60).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: date) }.map(Self.day))
        seconds = seconds.filter { keep.contains($0.key) }
        driftSeconds = driftSeconds.filter { keep.contains($0.key) }
    }

    func today(_ f: Feature, _ now: Date = Date()) -> TimeInterval { days(f)[Self.day(now)] ?? 0 }

    /// Since the start of this calendar week.
    func thisWeek(_ f: Feature, _ now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        let count = cal.dateComponents([.day], from: start, to: now).day ?? 0
        let d = days(f)
        return (0...count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
            .reduce(0) { $0 + (d[Self.day($1)] ?? 0) }
    }
}

/// Statistics rounded to the minute.
struct StatsSnapshot: Equatable {
    var awakeToday: TimeInterval = 0
    var awakeWeek: TimeInterval = 0
    var driftToday: TimeInterval = 0
    var driftWeek: TimeInterval = 0
}
