import Foundation

/// Time rules for Schedule and Deactivate. In Natural Mode each time shifts by a random
/// 1–5 minutes per day; the shift is seeded by the date so it is stable within a day.
struct Schedule {
    let config: Config
    let natural: Bool
    var calendar = Calendar.current

    /// Effective minute-of-day for `time` on the day of `date`, with natural jitter applied.
    func effectiveMinutes(_ time: ClockTime, on date: Date, salt: Int) -> Int {
        guard natural else { return time.minutes }
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        var rng = SeededRandom(seed: UInt64(day) &* 31 &+ UInt64(salt))
        let shift = Int.random(in: 1...5, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
        return min(max(time.minutes + shift, 0), 24 * 60 - 1)
    }

    func isInWindow(_ now: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: now)
        let m = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let from = effectiveMinutes(config.scheduleFrom, on: now, salt: 1)
        let to = effectiveMinutes(config.scheduleTo, on: now, salt: 2)
        if from <= to {
            return config.scheduleDays.contains(weekday) && m >= from && m < to
        }
        // Overnight window (e.g. 22:00–06:00): the evening part belongs to today's weekday,
        // the morning part to yesterday's.
        let yesterday = weekday == 1 ? 7 : weekday - 1
        return (m >= from && config.scheduleDays.contains(weekday))
            || (m < to && config.scheduleDays.contains(yesterday))
    }

    /// Next moment the "Deactivate At" time occurs after `now`.
    func nextDeactivation(after now: Date) -> Date {
        for offset in 0...1 {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            let minutes = effectiveMinutes(config.deactivateAt, on: day, salt: 3)
            let candidate = day.addingTimeInterval(TimeInterval(minutes * 60))
            if candidate > now { return candidate }
        }
        return now.addingTimeInterval(24 * 3600)
    }

    static func format(minutes: Int, approximate: Bool) -> String {
        String(format: "%@%02d:%02d", approximate ? "≈" : "", minutes / 60, minutes % 60)
    }
}

/// SplitMix64 — tiny deterministic generator for the per-day jitter.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
