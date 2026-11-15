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
/// 0.5 and 0.6 never let the panel follow the hand: it stood still until the pointer was 40 pt nearer another place,
/// then leapt there whole in 150 ms. Measured in his recording of 2026-11-15 (120 fps): leaps of 260-540 pt with the
/// panel motionless in between, which he called «дёрганно… магнитится по-конченому очень сильно». Spotlight on 27.2,
/// dragged in the same recording, follows the hand point for point; its centre line holds it until the hand is 26-30 pt
/// past, then lets go; coming back it is caught with no jump at all («аккуратненько, раз, раз»).
/// So since 0.7 the panel follows the hand, and each of the seven places is a soft magnet: caught within `snapIn`,
/// held until the hand is `snapOut` away (a shake smaller than that does not move it: the part of 0.6 he liked,
/// «телепаешь в разные стороны, но она не телепается»), and both the catch and the letting go are a 120 ms eased
/// slide, not a jump. Let go between places, it slides to the nearest one: at rest it is always at a place, exact
/// (his 0.4 review: «не должна дрейфовать»).
let snapIn: CGFloat = 16, snapOut: CGFloat = 30, snapStep = 0.12

struct Places {
    var tops: [CGFloat]    // rows: top, middle, bottom
    var lefts: [CGFloat]   // columns: left, centre, right

    func point(_ p: Place) -> NSPoint { NSPoint(x: lefts[p.column.rawValue], y: tops[p.row.rawValue]) }

    /// The place nearest to a point.
    func nearest(_ q: NSPoint) -> Place {
        Place.allCases.min { dist(point($0), q) < dist(point($1), q) }!
    }

    /// The place at exactly this point, if any.
    func at(_ q: NSPoint) -> Place? { Place.allCases.first { point($0) == q } }

    /// The box the places span: the panel never goes past its outermost places, so pushing it against a side or a
    /// corner holds it there, as Spotlight's top holds it (one margin from the screen's edges all round).
    func clamp(_ q: NSPoint) -> NSPoint {
        NSPoint(x: min(max(q.x, lefts.min()!), lefts.max()!), y: min(max(q.y, tops.min()!), tops.max()!))
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
        guard let w = window, let ps = places else { return }
        dragBegin(places: ps)
        let p0 = trialPointer ?? NSEvent.mouseLocation, start = NSPoint(x: left, y: top)
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let p = trialPointer ?? NSEvent.mouseLocation
            dragMove(raw: NSPoint(x: start.x + (p.x - p0.x), y: start.y + (p.y - p0.y)), places: ps)
            if e.type == .leftMouseUp { break }
        }
        dragEnd()
    }

    /// Taken by the edge: held at its place, or, caught while still sliding to one, free from where it is.
    func dragBegin(places ps: Places) {
        settleTicker.stop()
        let here = NSPoint(x: left, y: top)
        dragPlaces = ps
        dragPlace = ps.at(here)
        dragRaw = here
    }

    /// One step of a drag: where the hand would put the panel is `raw`.
    func dragMove(raw r: NSPoint, places ps: Places) {
        guard dragPlaces != nil else { return }
        dragRaw = ps.clamp(r)
        if let held = dragPlace {
            if dist(ps.point(held), dragRaw) > snapOut { dragPlace = nil; glide(snapStep) }
        } else {
            let n = ps.nearest(dragRaw)
            if dist(ps.point(n), dragRaw) <= snapIn { dragPlace = n; haptic(); glide(snapStep) }
        }
        if !settleTicker.running { put(dragTarget) }
    }

    /// Where the panel goes now: its place while held, else under the hand.
    private var dragTarget: NSPoint { dragPlace.flatMap { p in dragPlaces?.point(p) } ?? dragRaw }

    private func put(_ p: NSPoint) { left = p.x.rounded(); setBox(height: height, top: p.y.rounded()) }

    /// An eased slide from where the panel is drawn to the target, which may keep moving with the hand meanwhile.
    private func glide(_ d: Double) {
        let from = NSPoint(x: left, y: top)
        settleTicker.run { [weak self] t in
            guard let self else { return false }
            let to = self.dragTarget, k = Curve.ease(min(1, t / d))
            self.put(t >= d ? to : NSPoint(x: mix(from.x, to.x, k), y: mix(from.y, to.y, k)))
            return t < d
        }
    }

    /// Let go: held, it stays; between places, it slides to the nearest one, longer for a longer way: 0.2 s plus 1 s per
    /// 1500 pt, at most 0.45 s (a first 0.3 s cap moved it 88 pt in one frame over 380 pt in the trial of 2026-11-15;
    /// this keeps the fastest frame near 30 pt). The place is remembered for this screen.
    func dragEnd() {
        guard let ps = dragPlaces else { return }
        if dragPlace == nil {
            let n = ps.nearest(dragRaw)
            dragPlace = n
            glide(min(0.45, 0.2 + Double(dist(ps.point(n), NSPoint(x: left, y: top))) / 1500))
        }
        if let p = dragPlace {
            dragRaw = ps.point(p)   // with no drag running, dragTarget is this: a slide still running ends there
            if let sc = screen { store.setSetting("place." + screenKey(sc), p.rawValue) }
        }
        dragPlaces = nil
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
