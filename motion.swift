// Motion, frame by frame. Apple's grammar, read from Spotlight and Quick Look (dev/2026-11-14 Clipboard rivals, his
// films read.md): every state change lands in one frame; only containers move, and they clip what they hold. So no
// implicit Core Animation here: a Ticker calls a step function with the elapsed time on every display frame and the
// step sets the frames itself, which makes every frame computable and the tests able to step it exactly at 60 fps
// (Ticker.manual) instead of filming the screen.
import AppKit

final class Ticker {
    /// Tests drive time by hand (Ticker.advance), so a frame at 1/60 s is exactly that frame.
    nonisolated(unsafe) static var manual = false
    nonisolated(unsafe) private static var live: [Ticker] = []
    /// Slows every motion by this factor, to watch it on a real screen (CLIP_SLOW=10).
    nonisolated(unsafe) static var slow = Double(ProcessInfo.processInfo.environment["CLIP_SLOW"] ?? "") ?? 1

    private var step: ((Double) -> Bool)?
    private var timer: Timer?
    private var t0 = 0.0, elapsed = 0.0

    var running: Bool { step != nil }

    /// Calls `s` with the seconds since the start, at once with 0 and then on every frame, until it returns false.
    func run(_ s: @escaping (Double) -> Bool) {
        stop()
        guard s(0) else { return }
        step = s
        elapsed = 0
        Ticker.live.append(self)
        guard !Ticker.manual else { return }
        t0 = CACurrentMediaTime()
        // 120 Hz: a ProMotion screen draws every one; a 60 Hz screen takes every other. .common keeps it running while
        // the mouse is tracked (a drag runs the event-tracking mode).
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fire((CACurrentMediaTime() - self.t0) / Ticker.slow)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire(_ t: Double) {
        guard let s = step else { return }
        if !s(t) { stop() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        step = nil
        Ticker.live.removeAll { $0 === self }
    }

    /// Manual time: every running ticker moves on by `dt` seconds.
    static func advance(_ dt: Double) {
        for k in live { k.elapsed += dt; k.fire(k.elapsed) }
    }
}

enum Curve {
    /// A CSS-style cubic Bézier from (0,0) to (1,1); x is time, the result is progress.
    static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func b(_ t: Double, _ p1: Double, _ p2: Double) -> Double { 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {   // bisection: always converges, 40 steps is far below a pixel
            let v = b(t, x1, x2)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return b(t, y1, y2)
    }

    /// The system's default ease (kCAMediaTimingFunctionDefault: 0.25, 0.1, 0.25, 1): Spotlight's box resizing.
    static func ease(_ x: Double) -> Double { bezier(x, 0.25, 0.1, 0.25, 1) }
    static func easeInOut(_ x: Double) -> Double { bezier(x, 0.42, 0, 0.58, 1) }

    /// Quick Look's opening: most of the way in the first ~85 ms, settled at `total` (250 ms). An exponential
    /// approach with τ = 50 ms reaches 82 % at 85 ms, normalised to arrive exactly at the end.
    static func quickLook(_ t: Double, total: Double = 0.25, tau: Double = 0.05) -> Double {
        if t >= total { return 1 }
        return (1 - exp(-t / tau)) / (1 - exp(-total / tau))
    }

    /// A damped spring's offset from its target at time t, from offset x0 and velocity v0 (units per second).
    /// ζ 0.75, ω 10.7: settles in about 0.5 s with a 3 % overshoot, as Spotlight's panel returning to its place
    /// (his film 02:56-03:30, read by the lead's helper).
    static func spring(_ x0: Double, _ v0: Double, _ t: Double, zeta: Double = 0.75, omega: Double = 10.7) -> Double {
        let a = zeta * omega, wd = omega * (1 - zeta * zeta).squareRoot()
        return exp(-a * t) * (x0 * cos(wd * t) + (v0 + a * x0) / wd * sin(wd * t))
    }

    static func springVelocity(_ x0: Double, _ v0: Double, _ t: Double, zeta: Double = 0.75, omega: Double = 10.7) -> Double {
        let h = 1e-4
        return (spring(x0, v0, t + h, zeta: zeta, omega: omega) - spring(x0, v0, t, zeta: zeta, omega: omega)) / h
    }
}

func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
func mix(_ a: NSRect, _ b: NSRect, _ p: Double) -> NSRect {
    NSRect(x: mix(a.minX, b.minX, p), y: mix(a.minY, b.minY, p), width: mix(a.width, b.width, p), height: mix(a.height, b.height, p))
}
