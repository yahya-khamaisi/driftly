import AppKit
import ServiceManagement

/// The controller: owns config and runs Driftly's two features side by side. Awake holds off
/// sleep; Drift simulates activity. Each is turned on by hand or by a trigger, and each has
/// its own length, lock behavior and notification.
@MainActor
final class AppState: ObservableObject {
    @Published var config = Config.load() {
        didSet {
            guard config != oldValue else { return }
            config.save()
            configChanged(from: oldValue)
        }
    }

    /// What the panel shows for each feature.
    struct FeatureState: Equatable {
        var isOn = false
        /// Header subtitle: time left, what's keeping it on, the next move, or "Off".
        var status = "Off"
        /// 0…1 for the header ring: share of a timed run still to go; full otherwise.
        var progress = 0.0
    }

    @Published private(set) var awake = FeatureState()
    @Published private(set) var drift = FeatureState()
    /// "1:24" for the menu bar while a timed Awake runs.
    @Published private(set) var timeLeft: String?
    @Published private(set) var canPost = InputPoster.canPost
    @Published private(set) var canListen = InputPoster.canListen
    /// Statistics rounded to the minute, so the panel redraws once a minute at most.
    @Published private(set) var statsSnapshot = StatsSnapshot()
    private var stats = Stats.load()

    enum Source: Equatable { case manual, trigger(UUID) }
    private enum EndReason { case manual, expired, battery, triggers }

    private struct Run {
        var source: Source = .manual
        var startedAt = Date()
        var endsAt: Date?
        /// Triggers the user overrode by turning the feature off; cleared once they stop matching.
        var suppressed: Set<UUID> = []
    }

    private let activity = ActivityMonitor()
    private let system = SystemPauses()
    private let power = PowerAssertion()
    private let probes = TriggerProbes()
    private lazy var mover = Mover(activity: activity)
    private var timer: Timer?
    private var hotKeys: [HotKey] = []

    private var runs: [Feature: Run] = [.awake: Run(), .drift: Run()]
    private var matched: Set<UUID> = []
    private var lastTriggerCheck = Date.distantPast
    private var lastTick = Date()
    private var lastStatsSave = Date()
    private var lastDriveTouch = Date.distantPast
    private var lastLock = Date.distantPast

    private var cycling = false
    private var lastCycle = Date.distantPast
    private var idleThreshold: TimeInterval = 30
    private var gap: TimeInterval = 10

    init() {
        activity.start()
        // Returning from lock/sleep counts as activity, so we wait the full idle time again.
        system.onResume = { [weak self] in self?.activity.markActive() }
        registerHotKeys()
        for f in Feature.allCases where config[f].wasOn { start(f, .manual) }

        // 4 Hz keeps moves within ~0.25s of the configured interval.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        stats.prune(at: Date())
        refreshStats()
        tick()
    }

    subscript(f: Feature) -> FeatureState { f == .awake ? awake : drift }

    private static func published(_ f: Feature) -> ReferenceWritableKeyPath<AppState, FeatureState> {
        f == .awake ? \.awake : \.drift
    }

    /// Whether the menu-bar icon shows as on.
    var iconLit: Bool {
        switch config.iconFor {
        case .either: awake.isOn || drift.isOn
        case .awake: awake.isOn
        case .drift: drift.isOn
        }
    }

    // MARK: - User actions

    /// Turning a triggered feature off holds it off until its trigger stops matching.
    func toggle(_ f: Feature) { self[f].isOn ? end(f, .manual) : start(f, .manual) }

    func addClickPoint() {
        ClickPointPicker.pick { [weak self] point in
            guard let self, let point else { return }
            self.config.clickPoints.append(point)
        }
    }

    func resetStats() {
        stats = Stats()
        stats.save()
        refreshStats()
    }

    private func refreshStats() {
        let minute = { (t: TimeInterval) in (t / 60).rounded(.down) * 60 }
        update(\.statsSnapshot, StatsSnapshot(awakeToday: minute(stats.today(.awake)),
                                              awakeWeek: minute(stats.thisWeek(.awake)),
                                              driftToday: minute(stats.today(.drift)),
                                              driftWeek: minute(stats.thisWeek(.drift))))
    }

    private func registerHotKeys() {
        hotKeys = []
        hotKeys = Feature.allCases.enumerated().map { i, f in
            HotKey(config[f].shortcut, id: UInt32(i + 1)) { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.toggle(f) } }
            }
        }
    }

    // MARK: - Runs

    private func start(_ f: Feature, _ from: Source) {
        guard !self[f].isOn else { return }
        self[keyPath: Self.published(f)].isOn = true
        let now = Date()
        runs[f]?.source = from
        runs[f]?.startedAt = now
        runs[f]?.endsAt = from == .manual ? computeEnd(f, from: now) : nil
        if from == .manual { config[keyPath: Config.settings(f)].wasOn = true }
        if f == .drift {
            if !InputPoster.canPost { InputPoster.requestAccess() }
            lastCycle = .distantPast
            rollTiming()
        }
        tick()
    }

    private func end(_ f: Feature, _ reason: EndReason) {
        guard self[f].isOn else { return }
        let wasTriggered = runs[f]?.source != .manual
        self[keyPath: Self.published(f)].isOn = false
        runs[f]?.endsAt = nil
        runs[f]?.source = .manual
        config[keyPath: Config.settings(f)].wasOn = false
        // Turning off by hand (or on low battery) overrides every trigger for it that's currently true.
        if reason != .triggers { runs[f]?.suppressed = matched }
        stats.save()
        if config[f].notify, reason != .manual {
            let body = switch reason {
            case .expired: f == .awake ? "Your Mac can sleep again." : "Driftly stopped simulating activity."
            case .battery: "Battery dropped below \(config.batteryCutoff)%."
            default: wasTriggered ? "Its trigger no longer applies." : ""
            }
            Notifier.post("\(f.title) turned off", body)
        }
        tick()
    }

    private func computeEnd(_ f: Feature, from now: Date) -> Date? {
        switch config[f].length {
        case .indefinitely: nil
        case .minutes(let m): now.addingTimeInterval(TimeInterval(m * 60))
        case .untilTime: Schedule.next(config[f].untilTime, after: now, natural: config.naturalMode)
        }
    }

    private func configChanged(from old: Config) {
        for f in Feature.allCases {
            // Picking a new length while on by hand restarts the countdown from now.
            if config[f].length != old[f].length || config[f].untilTime != old[f].untilTime,
               self[f].isOn, runs[f]?.source == .manual {
                runs[f]?.startedAt = Date()
                runs[f]?.endsAt = computeEnd(f, from: Date())
            }
            if config[f].notify && !old[f].notify { Notifier.requestAuthorization() }
        }
        if config.triggers != old.triggers { lastTriggerCheck = .distantPast }
        if config.startAfterIdle != old.startAfterIdle || config.interval != old.interval { rollTiming() }
        if config.awake.shortcut != old.awake.shortcut || config.drift.shortcut != old.drift.shortcut { registerHotKeys() }
        if config.launchAtLogin != old.launchAtLogin {
            try? config.launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    /// Natural Mode adds ~±8% randomness to both intervals (e.g. 55–65 s instead of exactly 60).
    private func rollTiming() {
        let natural = config.naturalMode
        let jitter = { (v: TimeInterval) in natural ? v * .random(in: 0.92...1.08) : v }
        idleThreshold = jitter(config.startAfterIdle)
        gap = max(0.5, jitter(config.interval))
    }

    // MARK: - Engine

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 1)
        lastTick = now
        update(\.canPost, InputPoster.canPost)
        update(\.canListen, InputPoster.canListen)

        if now.timeIntervalSince(lastTriggerCheck) >= 2 {
            lastTriggerCheck = now
            evaluateTriggers(now)
        }
        for f in Feature.allCases where self[f].isOn {
            if let endsAt = runs[f]?.endsAt, now >= endsAt { end(f, .expired); return }
        }
        if awake.isOn, config.batteryCutoff > 0, !TriggerProbes.onACPower(),
           let level = TriggerProbes.batteryLevel(), level < config.batteryCutoff {
            end(.awake, .battery)
            return
        }

        let lockedPause = system.screenLocked && config.awake.whenLocked == .pause
        power.hold(system: awake.isOn, display: awake.isOn && config.display == .stayOn && !lockedPause)

        if awake.isOn {
            stats.add(dt, .awake, at: now)
            if let bookmark = config.keepDriveBookmark, now.timeIntervalSince(lastDriveTouch) >= DriveKeeper.interval {
                lastDriveTouch = now
                DispatchQueue.global(qos: .utility).async { DriveKeeper.touch(bookmark) }
            }
            lockIfIdle(now)
        }
        if drift.isOn { stats.add(dt, .drift, at: now) }
        if awake.isOn || drift.isOn {
            refreshStats()
            if now.timeIntervalSince(lastStatsSave) > 30 { stats.save(); lastStatsSave = now }
        }

        let activityStatus = drift.isOn ? simulateActivity(now) : ""
        updateStatus(.awake, now, detail: nil)
        updateStatus(.drift, now, detail: activityStatus)
    }

    private func evaluateTriggers(_ now: Date) {
        matched = probes.matching(config.triggers, natural: config.naturalMode, now: now)
        for f in Feature.allCases {
            runs[f]?.suppressed.formIntersection(matched)
            let suppressed = runs[f]?.suppressed ?? []
            let live = config.triggers
                .filter { $0.target.includes(f) && matched.contains($0.id) && !suppressed.contains($0.id) }
                .map(\.id)
            if !self[f].isOn, let first = live.first {
                start(f, .trigger(first))
            } else if self[f].isOn, case .trigger(let id) = runs[f]?.source, !live.contains(id) {
                // Hand over to another trigger that's still true, or turn off.
                if let next = live.first { runs[f]?.source = .trigger(next) } else { end(f, .triggers) }
            }
        }
    }

    private func lockIfIdle(_ now: Date) {
        guard config.lockAfterIdle > 0, !system.screenLocked, canPost,
              activity.idleSeconds >= config.lockAfterIdle,
              now.timeIntervalSince(lastLock) > 30 else { return }
        lastLock = now
        InputPoster.lockScreen()
    }

    /// `detail` is Drift's live activity line.
    private func updateStatus(_ f: Feature, _ now: Date, detail: String?) {
        let path = Self.published(f)
        guard self[f].isOn, let run = runs[f] else {
            update(path.appending(path: \.status), offStatus(f, now))
            update(path.appending(path: \.progress), 0)
            if f == .awake { update(\.timeLeft, nil) }
            return
        }
        if let endsAt = run.endsAt {
            let left = max(0, endsAt.timeIntervalSince(now))
            let total = max(1, endsAt.timeIntervalSince(run.startedAt))
            let status = if let detail { "\(Summary.clock(left, seconds: false)) left · \(detail)" }
                         else { "\(Summary.clock(left, seconds: true)) left · until \(Summary.timeOfDay(endsAt))" }
            update(path.appending(path: \.status), status)
            update(path.appending(path: \.progress), left / total)
            if f == .awake { update(\.timeLeft, config.showTimeLeft ? Summary.clock(left, seconds: false) : nil) }
        } else {
            let status: String
            if let detail {
                status = detail
            } else if case .trigger(let id) = run.source, let t = config.triggers.first(where: { $0.id == id }) {
                status = Summary.whileText(t)
            } else {
                status = "Until you turn it off"
            }
            update(path.appending(path: \.status), status)
            update(path.appending(path: \.progress), 1)
            if f == .awake { update(\.timeLeft, nil) }
        }
    }

    /// Moves when due; returns what Drift is doing right now.
    private func simulateActivity(_ now: Date) -> String {
        if let blocker = blockingReason() { return blocker }

        let idle = activity.idleSeconds
        guard idle >= idleThreshold else {
            return "Waiting for idle · \(Int((idleThreshold - idle).rounded(.up)))s"
        }

        // First move as soon as the idle threshold is reached, then every `gap` seconds.
        let firstAfterActivity = lastCycle < activity.lastUserActivity
        let remaining = firstAfterActivity ? 0 : max(0, gap - now.timeIntervalSince(lastCycle))
        let status = remaining >= 1 ? "Next move in \(Int(remaining.rounded(.up)))s" : "Moving"
        guard !cycling, remaining == 0 else { return status }
        cycling = true
        let started = now   // interval runs start-to-start, so glide time doesn't stretch it
        Task {
            await mover.cycle(config)
            lastCycle = started
            rollTiming()
            cycling = false
        }
        return status
    }

    private func blockingReason() -> String? {
        if !InputPoster.canPost { return "Needs Accessibility permission" }
        if system.screenLocked && config.drift.whenLocked == .pause { return "Paused · screen locked" }
        if system.sessionInactive { return "Paused · user switched" }
        if system.asleep || system.screensaver { return "Paused · display asleep" }
        if SystemPauses.transientUIOnScreen() { return "Paused · menu or screenshot" }
        return nil
    }

    /// "Off", or when the feature's next scheduled trigger starts.
    private func offStatus(_ f: Feature, _ now: Date) -> String {
        let natural = config.naturalMode
        let next = config.triggers
            .filter { $0.enabled && $0.kind == .schedule && $0.target.includes(f) }
            .compactMap { Schedule(from: $0.from, to: $0.to, days: $0.days, natural: natural).nextStart(after: now) }
            .min()
        guard let next else { return f == .awake ? "Off · your Mac sleeps as usual" : "Off · keeps chat apps active" }
        let cal = Calendar.current
        let day = cal.isDateInToday(next) ? "today" : cal.isDateInTomorrow(next) ? "tomorrow"
            : cal.weekdaySymbols[cal.component(.weekday, from: next) - 1]
        return "Off · starts \(day) at \(natural ? "≈" : "")\(Summary.timeOfDay(next))"
    }

    /// Publishes only real changes, so the 4 Hz tick doesn't redraw the panel needlessly.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
