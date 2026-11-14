// Where the panel rests: one of three places on each screen, chosen by the person (his pick 2026-11-14 10:13: top,
// middle and bottom are one interface, not variants; never at the pointer, a side or anywhere random). The middle is
// the default, his «посередине». Each is computed from the screen's visible frame (what the menu bar and the Dock
// leave), so a 13-inch Air and a 16-inch Pro each get their own middle.
import AppKit

enum Place: String, CaseIterable {
    case top, middle, bottom
}

/// The panel's top edge (screen points, y upwards) when it rests at `p` with height `h` on `s`.
/// - top: Spotlight's own place, 38 pt from the top of the screen (measured on this Mac: 6 pt under the menu bar);
/// - middle: the box's centre on the visible frame's centre;
/// - bottom: its bottom edge as far from the visible frame's bottom as the top place is from the menu bar.
func restingTop(_ p: Place, height h: CGFloat, on s: NSScreen) -> CGFloat {
    let v = s.visibleFrame
    switch p {
    case .top: return min(v.maxY - screenGap, s.frame.maxY - 38)
    case .middle: return (v.midY + h / 2).rounded()
    case .bottom: return v.minY + screenGap + h
    }
}

/// A screen's lasting identity (its display's UUID survives reconnecting and restarting, unlike its number), so the
/// place chosen on the 16-inch screen stays there and an external display keeps its own.
func screenKey(_ s: NSScreen) -> String {
    let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    guard let u = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() else { return "display-\(n)" }
    return CFUUIDCreateString(nil, u) as String
}

/// Dragging the panel, as Spotlight's own (SpotlightUIInternal: FluidWindow, FluidWindowDragGestureRecognizer,
/// TouchWindowDragEdges, a «settle» phase; read from the system's code names, the behaviour from his film): taken by
/// its edge, it is locked to the centre across and moves up and down. Each of the three places pulls like a magnet:
/// near one the panel lags behind the pointer and catches there (a small pull springs back), with the trackpad's
/// alignment tap as it catches; let go, it settles on the place it was heading for in about half a second with a
/// small overshoot. Pure geometry here, so ./test can check it without a screen.
struct Snap {
    /// The three resting tops, in Place.allCases order (top, middle, bottom): y upwards, so decreasing.
    var detents: [CGFloat]
    /// How far a place's pull reaches (never past half the way to the next place, or the magnets would meet with a
    /// jump between them: on a 13-inch screen the three places of a tall panel are ~90 pt apart), and how weak the
    /// pointer is at a place's very centre (0 = held still, 1 = free).
    static let maxReach: CGFloat = 70, hold: CGFloat = 0.1
    var reach: CGFloat {
        let d = detents.sorted()
        let gap = zip(d, d.dropFirst()).map { $1 - $0 }.min() ?? 2 * Snap.maxReach
        return min(Snap.maxReach, gap / 2)
    }
    /// A place catches (and taps) within this distance.
    static let catchAt: CGFloat = 10
    /// The sideways pull gives at most this much (Spotlight: 5-8 % of its width, then back to the centre).
    static let sideways: CGFloat = panelSize.width * 0.07

    /// Where the panel is drawn for a pointer that would put it at `raw`: the nearest place's magnet, and past the
    /// outermost places a rubber band (the panel never leaves the top or bottom place by more than a short stretch).
    func shown(_ raw: CGFloat) -> CGFloat {
        guard let hi = detents.max(), let lo = detents.min() else { return raw }
        if raw > hi { return hi + band(raw - hi, limit: 30) }
        if raw < lo { return lo - band(lo - raw, limit: 30) }
        let d = detents.min { abs(raw - $0) < abs(raw - $1) }!
        let x = raw - d, a = abs(x), r = reach
        guard a < r, r > 0 else { return raw }
        // A quartic from slope `hold` at the place (flat: it holds) to slope 1 at the reach, meeting the free line
        // there with no jump and no kink; monotonic, so the panel never moves against the pointer.
        let s = Snap.hold, u = a / r
        let f = r * (s * u + 3 * (1 - s) * u * u * u - 2 * (1 - s) * u * u * u * u)
        return d + (x < 0 ? -f : f)
    }

    /// The place caught at `shown`, if any.
    func caught(_ shown: CGFloat) -> Int? {
        detents.indices.first { abs(detents[$0] - shown) <= Snap.catchAt }
    }

    /// Where it settles when let go: the place nearest to where its speed is taking it (0.15 s ahead).
    func target(_ shown: CGFloat, velocity v: CGFloat) -> Int {
        let ahead = shown + v * 0.15
        return detents.indices.min { abs(detents[$0] - ahead) < abs(detents[$1] - ahead) }!
    }

    /// A pull of `x` against a rubber band that gives at most `limit` (UIScrollView's curve).
    func band(_ x: CGFloat, limit c: CGFloat) -> CGFloat {
        let a = abs(x)
        let y = c * (1 - 1 / (a * 0.55 / c + 1))
        return x < 0 ? -y : y
    }
}

extension PanelController {
    /// The resting tops of the three places for the current height on the current screen.
    var snap: Snap? { screen.map { s in Snap(detents: Place.allCases.map { restingTop($0, height: height, on: s) }) } }

    /// Starts a drag at a mouse-down on the panel's edge and follows the mouse until it goes up (a tracking loop, as
    /// AppKit's own window dragging does; the motion timer keeps running in the tracking mode).
    func drag(from down: NSEvent) {
        guard let w = window, let s = snap else { return }
        dragBegin()
        let p0 = NSEvent.mouseLocation, top0 = top
        var samples: [(Double, CGFloat)] = [(down.timestamp, top)]
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let p = NSEvent.mouseLocation
            dragMove(raw: top0 + (p.y - p0.y), sideways: p.x - p0.x, snap: s)
            samples.append((e.timestamp, top))
            samples.removeAll { e.timestamp - $0.0 > 0.08 }   // the speed of the last 80 ms
            if e.type == .leftMouseUp { break }
        }
        let v: CGFloat = samples.count >= 2 && samples.last!.0 > samples.first!.0
            ? (samples.last!.1 - samples.first!.1) / CGFloat(samples.last!.0 - samples.first!.0) : 0
        dragEnd(velocity: v, snap: s)
    }

    func dragBegin() {
        settleTicker.stop()
        dragCaught = snap?.caught(top)
    }

    /// One step of a drag: the box drawn where the magnets put it, the tap when a place catches.
    func dragMove(raw: CGFloat, sideways dx: CGFloat, snap s: Snap) {
        let y = s.shown(raw)
        dragX = s.band(dx, limit: Snap.sideways)
        setBox(height: height, top: y)
        let c = s.caught(y)
        if let c, c != dragCaught { haptic() }
        dragCaught = c
    }

    /// Let go: it settles on the place it was heading for with a spring (about 0.5 s, ~3 % overshoot), the
    /// sideways pull returns to the centre with the same spring, and the place is remembered for this screen.
    func dragEnd(velocity v: CGFloat, snap s: Snap) {
        let i = s.target(top, velocity: v)
        let goal = s.detents[i]
        if let sc = screen { store.setSetting("place." + screenKey(sc), Place.allCases[i].rawValue) }
        let y0 = Double(top - goal), x0 = Double(dragX)
        settleTicker.run { [weak self] t in
            guard let self else { return false }
            let y = Curve.spring(y0, Double(v), t), x = Curve.spring(x0, 0, t)
            let done = t > 0.1 && abs(y) < 0.25 && abs(x) < 0.25 && abs(Curve.springVelocity(y0, Double(v), t)) < 4
            self.dragX = done ? 0 : CGFloat(x)
            self.setBox(height: self.height, top: done ? goal : goal + CGFloat(y))
            return !done
        }
    }

    /// The trackpad's alignment tap (NSHapticFeedbackManager), as the system gives when something snaps into line.
    func haptic() {
        hapticTaps += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
