import Foundation
import CoreGraphics

/// Performs one "jiggle": move (or silent nudge), then optional clicks, scroll and key press.
@MainActor
struct Mover {
    let activity: ActivityMonitor

    /// Alternates right/left for `ClickType.both`.
    private static var lastClickWasRight = false

    func cycle(_ c: Config) async {
        let started = Date()
        let interrupted = { activity.lastUserActivity > started }
        let silent = c.silentMode
        let natural = c.naturalMode

        if silent {
            // Zero-distance move: resets idle timers, cursor stays exactly where it is.
            // Silent Mode never clicks or scrolls; Key Press still applies.
            InputPoster.move(to: InputPoster.cursor)
            PowerAssertion.declareUserActivity()
            if c.keyPress { InputPoster.silentKeyPress() }
            return
        }

        // Clicks happen first, at each saved point in turn (or where the cursor is),
        // then the cursor moves away to a random location.
        if c.clickType != .none {
            for p in c.clickPoints.isEmpty ? [InputPoster.cursor] : c.clickPoints {
                if interrupted() { return }
                if InputPoster.cursor != p {
                    guard await glide(from: InputPoster.cursor, to: p, natural: natural, interrupted: interrupted) else { return }
                }
                let right: Bool
                switch c.clickType {
                case .right: right = true
                case .both: right = !Self.lastClickWasRight
                default: right = false
                }
                Self.lastClickWasRight = right
                InputPoster.click(at: p, right: right)
                await pause(natural ? .random(in: 0.08...0.3) : 0.12)
            }
        }

        let origin = InputPoster.cursor
        let target = Self.target(from: origin, range: c.range)
        guard await glide(from: origin, to: target, natural: natural, interrupted: interrupted) else { return }
        if c.range == .small && c.clickType == .none {
            // Small stays where you left it.
            guard await glide(from: target, to: origin, natural: natural, interrupted: interrupted) else { return }
        }

        if c.scroll != .none, !interrupted() {
            let amount: Int32 = natural ? .random(in: 2...6) : 3
            let dy = (c.scroll == .vertical || c.scroll == .both) ? amount : 0
            let dx = (c.scroll == .horizontal || c.scroll == .both) ? amount : 0
            InputPoster.scroll(dx: dx, dy: dy)
            await pause(0.15)
            InputPoster.scroll(dx: -dx, dy: -dy)   // pulse back so the page ends where it started
        }

        if c.keyPress, !interrupted() {
            InputPoster.silentKeyPress()
        }
    }

    // MARK: - Path generation

    private static func target(from p: CGPoint, range: MovementRange) -> CGPoint {
        let bounds = InputPoster.displayBounds(containing: p).insetBy(dx: 4, dy: 4)
        let raw: CGPoint
        switch range {
        case .small:
            raw = CGPoint(x: p.x + .random(in: -6...6), y: p.y + .random(in: -6...6))
        case .medium:
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let dist = CGFloat.random(in: 40...140)
            raw = CGPoint(x: p.x + cos(angle) * dist, y: p.y + sin(angle) * dist)
        case .full:
            raw = CGPoint(x: .random(in: bounds.minX...bounds.maxX), y: .random(in: bounds.minY...bounds.maxY))
        }
        return CGPoint(x: min(max(raw.x, bounds.minX), bounds.maxX),
                       y: min(max(raw.y, bounds.minY), bounds.maxY))
    }

    /// Animates the cursor at ~60 fps. Natural mode uses a curved Bézier path, variable speed and
    /// sub-pixel jitter; otherwise a straight eased line. Returns false if the user took over.
    private func glide(from a: CGPoint, to b: CGPoint, natural: Bool,
                       interrupted: () -> Bool) async -> Bool {
        let distance = hypot(b.x - a.x, b.y - a.y)
        let duration = natural ? Double.random(in: 0.25...0.7) : 0.3
        let steps = max(2, Int(duration * 60))

        // Control points pushed perpendicular to the line for a hand-like arc.
        let normal = distance > 0 ? CGPoint(x: -(b.y - a.y) / distance, y: (b.x - a.x) / distance) : .zero
        let bend = natural ? CGFloat.random(in: -0.3...0.3) * distance : 0
        let c1 = CGPoint(x: a.x + (b.x - a.x) / 3 + normal.x * bend, y: a.y + (b.y - a.y) / 3 + normal.y * bend)
        let c2 = CGPoint(x: a.x + 2 * (b.x - a.x) / 3 + normal.x * bend * 0.6,
                         y: a.y + 2 * (b.y - a.y) / 3 + normal.y * bend * 0.6)

        for i in 1...steps {
            if interrupted() { return false }
            let t = Self.ease(CGFloat(i) / CGFloat(steps))
            var p = Self.bezier(a, c1, c2, b, t)
            if natural && i < steps {
                p.x += .random(in: -0.6...0.6)
                p.y += .random(in: -0.6...0.6)
            }
            InputPoster.move(to: p)
            await pause(duration / Double(steps))
        }
        return true
    }

    private static func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    private static func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
