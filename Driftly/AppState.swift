import AppKit
import ServiceManagement

/// The controller: owns config, runs keep-awake sessions (started by hand or by a trigger),
/// and while a session runs, decides whether to simulate activity.
@MainActor
final class AppState: ObservableObject {
    @Published var config = Config.load() {
        didSet {
            guard config != oldValue else { return }
            config.save()
            configChanged(from: oldValue)
        }
    }
    @Published private(set) var isActive = false
    /// Header subtitle: time left, what's keeping the session going, or "Off".
    @Published private(set) var status = "Off"
    /// Simulate activity row subtitle while a session runs: waiting, next move, or paused.
    @Published private(set) var activityStatus = ""
    /// 0…1 for the header ring: share of a timed session still to go; full otherwise.
    @Published private(set) var ringProgress = 0.0
    /// "1:24" for the menu bar while a timed session runs.
    @Published private(set) var timeLeft: String?
    @Published private(set) var canPost = InputPoster.canPost
    @Published private(set) var canListen = InputPoster.canListen
    /// Statistics rounded to the minute, so the panel redraws once a minute at most.
    @Published private(set) var statsSnapshot = StatsSnapshot()
    private var stats = Stats.load()

    enum Source: Equatable { case manual, trigger(UUID) }
    private enum EndReason { case manual, expired, battery, triggers }

    private let activity = ActivityMonitor()
    private let system = SystemPauses()
    private let power = PowerAssertion()
    private let probes = TriggerProbes()
    private lazy var mover = Mover(activity: activity)
    private var timer: Timer?
    private var hotKey: HotKey?

    private(set) var source: Source = .manual
    private var startedAt = Date()
    private var endsAt: Date?
    /// Triggers the user overrode by ending their session; cleared once they stop matching.
    private var suppressed: Set<UUID> = []
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
        registerHotKey()
        if config.wasActive { start(.manual) }

        // 4 Hz keeps moves within ~0.25s of the configured interval.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refreshStats()
        tick()
    }

    // MARK: - User actions

    /// Manual start/stop. Stopping a triggered session holds it off until its trigger stops matching.
    func toggle() { isActive ? end(.manual) : start(.manual) }

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
        let today = stats.today()
        update(\.statsSnapshot, StatsSnapshot(today: (today.time / 60).rounded(.down) * 60,
                                              sessions: today.sessions,
                                              week: (stats.thisWeek() / 60).rounded(.down) * 60))
    }

    private func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(config.shortcut) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.toggle() } }
        }
    }

    // MARK: - Sessions

    private func start(_ from: Source) {
        guard !isActive else { return }
        isActive = true
        source = from
        startedAt = Date()
        endsAt = from == .manual ? computeEnd(from: startedAt) : nil
        if from == .manual { config.wasActive = true }
        if config.simulateActivity, !InputPoster.canPost { InputPoster.requestAccess() }
        lastCycle = .distantPast
        rollTiming()
        stats.countSession(at: startedAt)
        refreshStats()
        tick()
    }

    private func end(_ reason: EndReason) {
        guard isActive else { return }
        let wasTriggered = source != .manual
        isActive = false
        endsAt = nil
        source = .manual
        config.wasActive = false
        // Ending by hand (or on low battery) overrides every trigger that's currently true.
        if reason != .triggers { suppressed = matched }
        stats.save()
        if config.notifyOnEnd, reason != .manual {
            let body = switch reason {
            case .expired: "Your Mac can sleep again."
            case .battery: "Battery dropped below \(config.batteryCutoff)%."
            default: wasTriggered ? "Its trigger no longer applies." : ""
            }
            Notifier.post("Driftly session ended", body)
        }
        tick()
    }

    private func computeEnd(from now: Date) -> Date? {
        switch config.length {
        case .indefinitely: nil
        case .minutes(let m): now.addingTimeInterval(TimeInterval(m * 60))
        case .untilTime: Schedule.next(config.untilTime, after: now, natural: config.naturalMode)
        }
    }

    private func configChanged(from old: Config) {
        // Picking a new length during a manual session restarts the countdown from now.
        if (config.length != old.length || config.untilTime != old.untilTime), isActive, source == .manual {
            startedAt = Date()
            endsAt = computeEnd(from: startedAt)
        }
        if config.triggers != old.triggers { lastTriggerCheck = .distantPast }
        if config.startAfterIdle != old.startAfterIdle || config.interval != old.interval { rollTiming() }
        if config.shortcut != old.shortcut { registerHotKey() }
        if config.notifyOnEnd && !old.notifyOnEnd { Notifier.requestAuthorization() }
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
        if isActive, let endsAt, now >= endsAt { end(.expired); return }
        if isActive, config.batteryCutoff > 0, !TriggerProbes.onACPower(),
           let level = TriggerProbes.batteryLevel(), level < config.batteryCutoff {
            end(.battery)
            return
        }

        let lockedPause = system.screenLocked && config.whenLocked == .pause
        power.hold(system: isActive, display: isActive && config.display == .stayOn && !lockedPause)

        guard isActive else {
            update(\.status, offStatus(now))
            update(\.activityStatus, "")
            update(\.ringProgress, 0)
            update(\.timeLeft, nil)
            return
        }

        stats.add(dt, at: now)
        refreshStats()
        if now.timeIntervalSince(lastStatsSave) > 30 { stats.save(); lastStatsSave = now }
        if let bookmark = config.keepDriveBookmark, now.timeIntervalSince(lastDriveTouch) >= DriveKeeper.interval {
            lastDriveTouch = now
            DispatchQueue.global(qos: .utility).async { DriveKeeper.touch(bookmark) }
        }
        lockIfIdle(now)
        updateSessionStatus(now)

        guard config.simulateActivity else { update(\.activityStatus, ""); return }
        simulateActivity(now)
    }

    private func evaluateTriggers(_ now: Date) {
        matched = probes.matching(config.triggers, natural: config.naturalMode, now: now)
        suppressed.formIntersection(matched)
        let live = config.triggers.map(\.id).filter { matched.contains($0) && !suppressed.contains($0) }
        if !isActive, let first = live.first {
            start(.trigger(first))
        } else if isActive, case .trigger(let id) = source, !live.contains(id) {
            // Hand over to another trigger that's still true, or end.
            if let next = live.first { source = .trigger(next) } else { end(.triggers) }
        }
    }

    private func lockIfIdle(_ now: Date) {
        guard config.lockAfterIdle > 0, !system.screenLocked, canPost,
              activity.idleSeconds >= config.lockAfterIdle,
              now.timeIntervalSince(lastLock) > 30 else { return }
        lastLock = now
        InputPoster.lockScreen()
    }

    private func updateSessionStatus(_ now: Date) {
        if let endsAt {
            let left = max(0, endsAt.timeIntervalSince(now))
            let total = max(1, endsAt.timeIntervalSince(startedAt))
            update(\.status, "\(Summary.clock(left, seconds: true)) left · until \(Summary.timeOfDay(endsAt))")
            update(\.ringProgress, left / total)
            update(\.timeLeft, config.showTimeLeft ? Summary.clock(left, seconds: false) : nil)
        } else {
            if case .trigger(let id) = source, let t = config.triggers.first(where: { $0.id == id }) {
                update(\.status, Summary.whileText(t))
            } else {
                update(\.status, "Until you turn it off")
            }
            update(\.ringProgress, 1)
            update(\.timeLeft, nil)
        }
    }

    private func simulateActivity(_ now: Date) {
        if let blocker = blockingReason() { update(\.activityStatus, blocker); return }

        let idle = activity.idleSeconds
        guard idle >= idleThreshold else {
            update(\.activityStatus, "Waiting for idle · \(Int((idleThreshold - idle).rounded(.up)))s")
            return
        }

        // First move as soon as the idle threshold is reached, then every `gap` seconds.
        let firstAfterActivity = lastCycle < activity.lastUserActivity
        let remaining = firstAfterActivity ? 0 : max(0, gap - now.timeIntervalSince(lastCycle))
        update(\.activityStatus, remaining >= 1 ? "Next move in \(Int(remaining.rounded(.up)))s" : "Moving")
        guard !cycling, remaining == 0 else { return }
        cycling = true
        let started = now   // interval runs start-to-start, so glide time doesn't stretch it
        Task {
            await mover.cycle(config)
            lastCycle = started
            rollTiming()
            cycling = false
        }
    }

    private func blockingReason() -> String? {
        if !InputPoster.canPost { return "Needs Accessibility permission" }
        if system.screenLocked && config.whenLocked == .pause { return "Paused · screen locked" }
        if system.sessionInactive { return "Paused · user switched" }
        if system.asleep || system.screensaver { return "Paused · display asleep" }
        if SystemPauses.transientUIOnScreen() { return "Paused · menu or screenshot" }
        return nil
    }

    /// "Off", or when the next scheduled trigger starts.
    private func offStatus(_ now: Date) -> String {
        let natural = config.naturalMode
        let next = config.triggers
            .filter { $0.enabled && $0.kind == .schedule }
            .compactMap { Schedule(from: $0.from, to: $0.to, days: $0.days, natural: natural).nextStart(after: now) }
            .min()
        guard let next else { return "Off" }
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
