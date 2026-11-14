// Where the panel rests: one of three places on each screen, chosen by the person (his pick 2026-11-14 10:13: top,
// middle and bottom are one interface, not variants; never at the pointer, a side or anywhere random). The middle is
// the default, his «посередине». Each is computed from the screen's visible frame (what the menu bar and the Dock
// leave), so a 13-inch Air and a 16-inch Pro each get their own middle.
import AppKit

enum Place: String, CaseIterable {
    // Raw values of 0.4's three places kept, so a place chosen then still holds.
    case topLeft, top, topRight, middle, bottomLeft, bottom, bottomRight

    enum Row: Int { case top, middle, bottom }
    enum Column: Int { case left, centre, right }
    var row: Row {
        switch self { case .topLeft, .top, .topRight: .top; case .middle: .middle; case .bottomLeft, .bottom, .bottomRight: .bottom }
    }
    var column: Column {
        switch self { case .topLeft, .bottomLeft: .left; case .topRight, .bottomRight: .right; default: .centre }
    }
    /// The middle row has the centre only: a panel half off to one side in the middle of the screen is no place (his
    /// list, 2026-11-14: top left, top centre, top right, centre, bottom left, bottom centre, bottom right).
    static func at(_ r: Row, _ c: Column) -> Place? {
        switch (r, c) {
        case (.top, .left): .topLeft; case (.top, .centre): .top; case (.top, .right): .topRight
        case (.middle, .centre): .middle
        case (.bottom, .left): .bottomLeft; case (.bottom, .centre): .bottom; case (.bottom, .right): .bottomRight
        default: nil
        }
    }
    /// Where a new person's panel opens: top centre, Spotlight's own place (his review of 0.4: «flush to the top as
    /// Spotlight does»; 0.4 opened in the middle).
    static let standard = Place.top

    var title: String {
        switch self {
        case .topLeft: L("Top Left"); case .top: L("Top Center"); case .topRight: L("Top Right"); case .middle: L("Center")
        case .bottomLeft: L("Bottom Left"); case .bottom: L("Bottom Center"); case .bottomRight: L("Bottom Right")
        }
    }
}

/// The panel's top edge (screen points, y upwards) when it rests in `p`'s row with height `h` on `s`.
/// - top: Spotlight's own place, 38 pt from the top of the screen (measured on this Mac: 6 pt under the menu bar);
/// - middle: the box's centre on the visible frame's centre;
/// - bottom: its bottom edge as far from the visible frame's bottom as the top place is from the menu bar.
func restingTop(_ p: Place, height h: CGFloat, on s: NSScreen) -> CGFloat {
    let v = s.visibleFrame
    switch p.row {
    case .top: return min(v.maxY - screenGap, s.frame.maxY - 38)
    case .middle: return (v.midY + h / 2).rounded()
    case .bottom: return v.minY + screenGap + h
    }
}

/// The panel's left edge in `p`'s column: centred on the visible frame, or as far from its side as the top place is
/// from the menu bar, so the corners keep one margin all round.
func restingLeft(_ p: Place, on s: NSScreen) -> CGFloat {
    let v = s.visibleFrame
    switch p.column {
    case .left: return v.minX + screenGap
    case .centre: return (v.midX - panelSize.width / 2).rounded()
    case .right: return v.maxX - screenGap - panelSize.width
    }
}

/// A screen's lasting identity (its display's UUID survives reconnecting and restarting, unlike its number), so the
/// place chosen on the 16-inch screen stays there and an external display keeps its own.
func screenKey(_ s: NSScreen) -> String {
    let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    guard let u = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() else { return "display-\(n)" }
    return CFUUIDCreateString(nil, u) as String
}

/// Dragging the panel (his pick 2026-11-14 10:13: by its edge, like Spotlight; widened in 0.5 to his seven places).
/// His second review of 0.4 (17:59): it must never drift, «не должна дрейфовать влево, вправо, вверх, вниз», and sits
/// only at exact, measured places. So the panel never follows the pointer freely: taken by its edge it stays where it
/// is until the pointer is clearly nearer another place, then it moves there whole, in one short eased step (150 ms,
/// no overshoot, the trackpad's alignment tap), and stays exact again. Every frame of a drag is a place or the step
/// between two; 0.4's free drag with rubber bands and a spring showed the hand's sideways drift and in-between spots.
struct Places {
    var tops: [CGFloat]    // rows: top, middle, bottom
    var lefts: [CGFloat]   // columns: left, centre, right

    func point(_ p: Place) -> NSPoint { NSPoint(x: lefts[p.column.rawValue], y: tops[p.row.rawValue]) }

    /// The place nearest to a point.
    func nearest(_ q: NSPoint) -> Place {
        Place.allCases.min { dist(point($0), q) < dist(point($1), q) }!
    }

    /// Where a drag goes from `current` when the panel would be at `raw`: another place only when it is nearer by
    /// more than `hysteresis`, so a hand resting between two places does not make the panel flicker.
    func next(from current: Place, raw: NSPoint, hysteresis: CGFloat = 40) -> Place {
        let n = nearest(raw)
        return dist(point(n), raw) + hysteresis < dist(point(current), raw) ? n : current
    }
}

func dist(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

extension PanelController {
    /// The seven places for the current height on the current screen.
    var places: Places? {
        screen.map { s in
            Places(tops: [Place.top, .middle, .bottom].map { restingTop($0, height: height, on: s) },
                   lefts: [Place.topLeft, .top, .topRight].map { restingLeft($0, on: s) })
        }
    }

    /// Follows the mouse from a mouse-down on the panel's edge until it goes up (a tracking loop, as AppKit's own
    /// window dragging does; the motion timer keeps running in the tracking mode).
    func drag(from down: NSEvent) {
        guard let w = window, let ps = places, let s = screen else { return }
        dragBegin(placeFor(s))
        let p0 = trialPointer ?? NSEvent.mouseLocation, start = ps.point(placeFor(s))
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let p = trialPointer ?? NSEvent.mouseLocation
            dragMove(raw: NSPoint(x: start.x + (p.x - p0.x), y: start.y + (p.y - p0.y)), places: ps)
            if e.type == .leftMouseUp { break }
        }
        dragEnd()
    }

    func dragBegin(_ p: Place) { dragPlace = p }

    /// One step of a drag: a new place when the pointer is clearly nearer to it, reached in one short step.
    func dragMove(raw: NSPoint, places ps: Places) {
        guard let cur = dragPlace else { return }
        let n = ps.next(from: cur, raw: raw)
        guard n != cur else { return }
        dragPlace = n
        haptic()
        let from = NSPoint(x: left, y: top), to = ps.point(n), d = 0.15
        settleTicker.run { [weak self] t in
            guard let self else { return false }
            let k = Curve.ease(min(1, t / d))
            self.left = (from.x + (to.x - from.x) * CGFloat(k)).rounded()
            self.setBox(height: self.height, top: (from.y + (to.y - from.y) * CGFloat(k)).rounded())
            if t >= d { self.left = to.x; self.setBox(height: self.height, top: to.y) }
            return t < d
        }
    }

    /// Let go: the place it is at is remembered for this screen.
    func dragEnd() {
        if let p = dragPlace, let sc = screen { store.setSetting("place." + screenKey(sc), p.rawValue) }
        dragPlace = nil
    }

    /// Settings' «Position on Screen»: the place for the screen the panel opens on (the main one when it is closed).
    func setPlace(_ p: Place, on s: NSScreen) {
        store.setSetting("place." + screenKey(s), p.rawValue)
        if isVisible, screen == s {
            left = restingLeft(p, on: s)
            setBox(height: height, top: restingTop(p, height: height, on: s))
        }
    }

    /// The trackpad's alignment tap (NSHapticFeedbackManager), as the system gives when something snaps into line.
    func haptic() {
        hapticTaps += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
