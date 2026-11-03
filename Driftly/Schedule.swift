import Foundation

/// Time rules for schedule triggers and "until" sessions. In Natural mode each time shifts by
/// a random 1–5 minutes per day; the shift is seeded by the date so it is stable within a day.
struct Schedule {
    let from: ClockTime
    let to: ClockTime
    let days: Set<Int>
    let natural: Bool
    var calendar = Calendar.current

    /// Effective minute-of-day for `time` on the day of `date`, with natural jitter applied.
    func effectiveMinutes(_ time: ClockTime, on date: Date, salt: Int) -> Int {
        Self.effectiveMinutes(time, on: date, salt: salt, natural: natural, calendar: calendar)
    }

    static func effectiveMinutes(_ time: ClockTime, on date: Date, salt: Int, natural: Bool,
                                 calendar: Calendar = .current) -> Int {
        guard natural else { return time.minutes }
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        var rng = SeededRandom(seed: UInt64(day) &* 31 &+ UInt64(salt))
        let shift = Int.random(in: 1...5, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
        return min(max(time.minutes + shift, 0), 24 * 60 - 1)
    }

    func isInWindow(_ now: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: now)
        let m = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let start = effectiveMinutes(from, on: now, salt: 1)
        let end = effectiveMinutes(to, on: now, salt: 2)
        if start <= end {
            return days.contains(weekday) && m >= start && m < end
        }
        // Overnight window (e.g. 22:00–06:00): the evening part belongs to today's weekday,
        // the morning part to yesterday's.
        let yesterday = weekday == 1 ? 7 : weekday - 1
        return (m >= start && days.contains(weekday)) || (m < end && days.contains(yesterday))
    }

    /// Next start of this window after `now`, within the coming week.
    func nextStart(after now: Date) -> Date? {
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  days.contains(calendar.component(.weekday, from: day)) else { continue }
            let start = day.addingTimeInterval(TimeInterval(effectiveMinutes(from, on: day, salt: 1) * 60))
            if start > now { return start }
        }
        return nil
    }

    /// Next time `time` occurs after `now` (today or tomorrow).
    static func next(_ time: ClockTime, after now: Date, natural: Bool, calendar: Calendar = .current) -> Date {
        for offset in 0...1 {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            let minutes = effectiveMinutes(time, on: day, salt: 3, natural: natural, calendar: calendar)
            let candidate = day.addingTimeInterval(TimeInterval(minutes * 60))
            if candidate > now { return candidate }
        }
        return now.addingTimeInterval(24 * 3600)
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
