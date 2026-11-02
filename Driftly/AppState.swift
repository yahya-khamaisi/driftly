import AppKit
import IOKit.ps
import ServiceManagement

/// The controller: owns config, decides every second whether to jiggle, and drives the Mover.
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
    @Published private(set) var status = "Off"
    /// 0…1 for the header ring: idle progress while waiting, countdown to the next move while active.
    @Published private(set) var ringProgress = 0.0
    @Published private(set) var canPost = InputPoster.canPost
    @Published private(set) var canListen = InputPoster.canListen
    private let activity = ActivityMonitor()
    private let system = SystemPauses()
    private let power = PowerAssertion()
    private lazy var mover = Mover(activity: activity)
    private var timer: Timer?
    private var hotKey: HotKey?

    private var cycling = false
    private var lastCycle = Date.distantPast
    private var idleThreshold: TimeInterval = 30
    private var gap: TimeInterval = 10
    private var deactivateDeadline: Date?
    private var lastInWindow: Bool?

    init() {
        activity.start()
        // Returning from lock/sleep counts as activity, so we wait the full idle time again.
        system.onResume = { [weak self] in self?.activity.markActive() }
        registerHotKey()
        if config.wasActive { setActive(true) }

        // 4 Hz keeps moves within ~0.25s of the configured interval.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: - User actions

    /// Manual toggle. With Schedule on, the choice holds until the next scheduled start/stop.
    func toggle() { setActive(!isActive) }

    func addClickPoint() {
        ClickPointPicker.pick { [weak self] point in
            guard let self, let point else { return }
            self.config.clickPoints.append(point)
        }
    }

    private func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(config.shortcut) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.toggle() } }
        }
    }

    // MARK: - State machine

    private func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        config.wasActive = on
        if on {
            if !InputPoster.canPost { InputPoster.requestAccess() }
            lastCycle = .distantPast
            rollTiming()
        }
        deactivateDeadline = on ? computeDeadline(from: Date()) : nil
        tick()
    }

    private func configChanged(from old: Config) {
        let deactivateChanged = config.deactivateEnabled != old.deactivateEnabled
            || config.deactivateKind != old.deactivateKind
            || config.deactivateAt != old.deactivateAt
            || config.deactivateAfter != old.deactivateAfter
        if deactivateChanged && isActive { deactivateDeadline = computeDeadline(from: Date()) }
        if config.scheduleEnabled != old.scheduleEnabled { lastInWindow = nil }
        if config.startAfterIdle != old.startAfterIdle || config.interval != old.interval { rollTiming() }
        if config.shortcut != old.shortcut { registerHotKey() }
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

    private func computeDeadline(from now: Date) -> Date? {
        guard config.deactivateEnabled else { return nil }
        switch config.deactivateKind {
        case .at: return schedule.nextDeactivation(after: now)
        case .after: return now.addingTimeInterval(config.deactivateAfter)   // "In" is always exact
        }
    }

    private var schedule: Schedule { Schedule(config: config, natural: config.naturalMode) }

    private func tick() {
        let now = Date()
        if canPost != InputPoster.canPost { canPost = InputPoster.canPost }
        if canListen != InputPoster.canListen { canListen = InputPoster.canListen }
        // Schedule acts only on boundaries, so a manual toggle holds until the next one.
        if config.scheduleEnabled {
            let inWindow = schedule.isInWindow(now)
            if inWindow != lastInWindow {
                if lastInWindow != nil || inWindow { setActive(inWindow) }
                lastInWindow = inWindow
            }
        }

        if let deadline = deactivateDeadline, now >= deadline {
            setActive(false)
            // "At" repeats daily; schedule the next one in case we're re-activated.
        }

        if isActive, config.batteryCutoff > 0, let level = Self.batteryLevelOnBattery(), level < config.batteryCutoff {
            setActive(false)
        }

        let blocker = blockingReason()
        power.hold(isActive && config.preventSleep && !(system.screenLocked && config.pauseWhenLocked))

        guard isActive else { status = offStatus(now); ringProgress = 0; return }
        if let blocker { status = blocker; ringProgress = 0; return }

        let idle = activity.idleSeconds
        guard idle >= idleThreshold else {
            status = "Waiting for idle · \(Int((idleThreshold - idle).rounded(.up)))s"
            ringProgress = idleThreshold > 0 ? idle / idleThreshold : 1
            return
        }

        // First move as soon as the idle threshold is reached, then every `gap` seconds.
        let firstAfterActivity = lastCycle < activity.lastUserActivity
        let remaining = firstAfterActivity ? 0 : max(0, gap - now.timeIntervalSince(lastCycle))
        status = remaining >= 1 ? "Active · next move in \(Int(remaining.rounded(.up)))s" : "Active · moving"
        ringProgress = gap > 0 ? 1 - remaining / gap : 1
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
        if config.pauseWhenLocked && system.screenLocked { return "Paused · screen locked" }
        if system.sessionInactive { return "Paused · user switched" }
        if system.asleep || system.screensaver { return "Paused · display asleep" }
        if SystemPauses.transientUIOnScreen() { return "Paused · menu or screenshot" }
        return appRuleBlocker()
    }

    /// Only While App. Still needs manual or scheduled activation; this only gates it.
    private func appRuleBlocker() -> String? {
        guard config.appRuleEnabled, !config.appBundleIDs.isEmpty else { return nil }
        let ids = Set(config.appBundleIDs)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        switch config.appRule {
        case .isRunning:
            let running = NSWorkspace.shared.runningApplications.contains { ids.contains($0.bundleIdentifier ?? "") }
            return running ? nil : "Waiting for app to open"
        case .inFront:
            return ids.contains(front) ? nil : "Waiting for app in front"
        case .notInFront:
            return ids.contains(front) ? "Paused · app in front" : nil
        }
    }

    /// "Off", or "Activates: Mon ≈09:03" when a schedule is set.
    private func offStatus(_ now: Date) -> String {
        guard config.scheduleEnabled, !config.scheduleDays.isEmpty else { return "Off" }
        let cal = Calendar.current
        let natural = config.naturalMode
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                  config.scheduleDays.contains(cal.component(.weekday, from: day)) else { continue }
            let minutes = schedule.effectiveMinutes(config.scheduleFrom, on: day, salt: 1)
            if day.addingTimeInterval(TimeInterval(minutes * 60)) <= now { continue }
            let name = offset == 0 ? "Today" : cal.shortWeekdaySymbols[cal.component(.weekday, from: day) - 1]
            return "Activates: \(name) \(Schedule.format(minutes: minutes, approximate: natural))"
        }
        return "Off"
    }

    /// Battery percentage when running on battery; nil on AC power or desktops.
    static func batteryLevelOnBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue else { continue }
            return d[kIOPSCurrentCapacityKey] as? Int
        }
        return nil
    }
}
