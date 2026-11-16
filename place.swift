// Where the panel rests: fifteen places on each screen since 2026-11-16, five columns by three rows (his pick of the night
// variants, 2026-11-16 ~05:25: «15 мест… чтоб ничего не прыгало… с точки зрения математики… соотноситься с нашей
// сеткой», his Grids app), chosen by the person, never at the pointer or anywhere random (his pick 2026-11-14 10:13).
// 0.7-0.1 had nine (the corners, the middle of each edge, the centre), 0.5-0.6 seven, 0.4 three.
// Each is computed from the screen itself, so a 13-inch Air and a 16-inch Pro each get their own (geometry: PlaceGrid).
import AppKit

enum Place: String, CaseIterable {
    // Raw values of the nine places of 0.7-0.1 (and of 0.4's three) kept, so a place chosen then still holds.
    case topLeft, topInnerLeft, top, topInnerRight, topRight
    case middleLeft, middleInnerLeft, middle, middleInnerRight, middleRight
    case bottomLeft, bottomInnerLeft, bottom, bottomInnerRight, bottomRight

    enum Row: Int, CaseIterable { case top, middle, bottom }
    enum Column: Int, CaseIterable { case left, innerLeft, centre, innerRight, right }
    var row: Row { Row(rawValue: Place.allCases.firstIndex(of: self)! / 5)! }
    var column: Column { Column(rawValue: Place.allCases.firstIndex(of: self)! % 5)! }
    static func at(_ r: Row, _ c: Column) -> Place { Place.allCases[r.rawValue * 5 + c.rawValue] }
    /// Where a new person's panel opens: top centre, Spotlight's own place (his review of 0.4: «flush to the top as
    /// Spotlight does»; 0.4 opened in the middle).
    static let standard = Place.top

    var title: String {
        // Apple's Shortcuts names the nine of a 3 × 3 grid (WorkflowKit, WFPosition); the two columns between the side
        // and the centre are «left of center» and «right of center», as English says it.
        let r = [L("Top"), L("Middle"), L("Bottom")][row.rawValue]
        switch self {
        case .middle: return L("Center")
        case .top, .bottom: return r + " " + L("Center")
        default: break
        }
        switch column {
        case .left: return r + " " + L("Left")
        case .right: return r + " " + L("Right")
        case .innerLeft: return r + ", " + L("Left of Center")
        default: return r + ", " + L("Right of Center")
        }
    }
}

/// Grids' finest lines: every 8 pt from the screen's top left corner (Apple's layout step; Grids' blue grid). The
/// places' edges sit on them, so with Grids on the panel lies exactly on its lines (his word 2026-11-16).
let gridStep: CGFloat = 8
/// The least room left between the panel and the edge of the visible frame (the menu bar, the Dock, the screen's sides)
/// before the next grid line: on this Mac (32 pt menu bar, 1117 pt tall) the top edge comes 8 pt under the menu bar
/// (40; Spotlight's own is 38, off the grid), the sides 8 pt in and the bottom 5 pt up (1112, the last line).
let edgeRoom: CGFloat = 4

/// The fifteen places on one screen (variant А of 2026-11-15, his pick 2026-11-16). Worked out as Grids draws: from the
/// screen's whole frame, top left corner, y down; returned in AppKit's screen points (y up).
/// - Columns: the two sides on the first grid line inside the visible frame; the centre column centred on the screen
///   (Grids' red 1/2 line); the two between halfway from each side to the centre, on a grid line counted from the
///   centre, so the five stand even (on 1728 pt: 8, 272, 544, 816, 1080; steps 264 and 272) and mirror each other.
/// - Rows: the top row's top edge on the first grid line under the menu bar; the bottom row's bottom edge on the last
///   grid line above the bottom of the visible frame (the Dock, when shown); the middle row such that a full panel
///   (Spotlight's 546 pt) has its centre on the screen's half line (Grids' red line), its top on the nearest grid line.
/// - What holds when the list's height changes (the night variants: the jump he disliked was 0.1's middle row being
///   centred anew at each opening, 120 pt after five deletions, 239 at the bottom): the top and middle rows hold the
///   top edge, where the search field is, always; the bottom row holds the bottom edge, except that the field never
///   moves while a search is being typed (fitHeight). No place is ever centred by the panel's current height.
struct PlaceGrid {
    let lefts: [CGFloat]   // the five columns' left edges
    let topEdge: CGFloat   // the top row's top edge
    let middleEdge: CGFloat
    let bottomEdge: CGFloat   // the bottom row's bottom edge, and the lowest any panel goes

    init(frame f: NSRect, visible v: NSRect, width w: CGFloat = panelSize.width, tallest: CGFloat = panelSize.height) {
        func up(_ x: CGFloat) -> CGFloat { (x / gridStep).rounded(.up) * gridStep }
        func down(_ x: CGFloat) -> CGFloat { (x / gridStep).rounded(.down) * gridStep }
        func near(_ x: CGFloat) -> CGFloat { (x / gridStep).rounded() * gridStep }
        // The visible frame from the screen's top left corner, y down.
        let vx0 = v.minX - f.minX, vx1 = v.maxX - f.minX, vy0 = f.maxY - v.maxY, vy1 = f.maxY - v.minY
        var l0 = up(vx0 + edgeRoom), r0 = down(vx1 - edgeRoom) - w
        if r0 < l0 { l0 = ((vx0 + vx1 - w) / 2).rounded(); r0 = l0 }   // a screen narrower than the panel: one column
        let c = min(max(f.width / 2 - w / 2, l0), r0)
        let dl = near((c - l0) / 2), dr = near((r0 - c) / 2)
        lefts = [l0, c - dl, c, c + dr, r0].map { f.minX + $0 }
        let t0 = up(vy0 + edgeRoom)
        let b0 = max(down(vy1 - edgeRoom), t0 + fieldH)
        let full = min(tallest, b0 - t0)
        let m = min(max(near(f.height / 2 - full / 2), t0), b0 - full)
        topEdge = f.maxY - t0; middleEdge = f.maxY - m; bottomEdge = f.maxY - b0
    }

    init(_ s: NSScreen) { self.init(frame: s.frame, visible: s.visibleFrame) }

    /// The panel's top edge at row `r` with height `h`.
    func top(_ r: Place.Row, height h: CGFloat) -> CGFloat {
        switch r {
        case .top: topEdge
        case .middle: middleEdge
        case .bottom: bottomEdge + h
        }
    }

    /// The tallest the panel may be at row `r`: what is left between its held edge and the other end of the room.
    func room(_ r: Place.Row) -> CGFloat {
        r == .middle ? middleEdge - bottomEdge : topEdge - bottomEdge
    }

    func left(_ c: Place.Column) -> CGFloat { lefts[c.rawValue] }

    /// The fifteen places' top left points for a panel of height `h` (what the drag moves between).
    func places(height h: CGFloat) -> Places {
        Places(tops: Place.Row.allCases.map { top($0, height: h) }, lefts: lefts)
    }
}

/// The panel's top edge (screen points, y upwards) when it rests in `p`'s row with height `h` on `s`.
func restingTop(_ p: Place, height h: CGFloat, on s: NSScreen) -> CGFloat { PlaceGrid(s).top(p.row, height: h) }

/// The panel's left edge in `p`'s column.
func restingLeft(_ p: Place, on s: NSScreen) -> CGFloat { PlaceGrid(s).left(p.column) }

/// A screen's lasting identity (its display's UUID survives reconnecting and restarting, unlike its number), so the
/// place chosen on the 16-inch screen stays there and an external display keeps its own.
func screenKey(_ s: NSScreen) -> String {
    let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    guard let u = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() else { return "display-\(n)" }
    return CFUUIDCreateString(nil, u) as String
}

/// Dragging the panel (his pick 2026-11-14 10:13: by its edge, like Spotlight; widened in 0.5 to his seven places, in 0.7 to
/// nine, on 2026-11-16 to fifteen).
/// 0.5 and 0.6 never let the panel follow the hand: it stood still until the pointer was 40 pt nearer another place,
/// then leapt there whole in 150 ms. Measured in his recording of 2026-11-15 (120 fps): leaps of 260-540 pt with the
/// panel motionless in between, which he called «дёрганно… магнитится по-конченому очень сильно». Spotlight on 27.2,
/// dragged in the same recording, follows the hand point for point; its centre line holds it until the hand is 26-30 pt
/// past, then lets go; coming back it is caught with no jump at all («аккуратненько, раз, раз»).
/// So since 0.7 the panel follows the hand, and each place is a soft magnet: caught within `snapIn`,
/// held until the hand is `snapOut` away (a shake smaller than that does not move it: the part of 0.6 he liked,
/// «телепаешь в разные стороны, но она не телепается»), and both the catch and the letting go are a 120 ms eased
/// slide, not a jump. Let go between places, it slides to the nearest one: at rest it is always at a place, exact
/// (his 0.4 review: «не должна дрейфовать»).
let snapIn: CGFloat = 16, snapOut: CGFloat = 30, snapStep = 0.12

struct Places {
    var tops: [CGFloat]    // rows: top, middle, bottom
    var lefts: [CGFloat]   // columns: left, left of centre, centre, right of centre, right

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

/// The soft-magnet drag itself, shared by the history panel and the paste queue's deck: it moves a box whose top-left
/// point it reads and sets, between one set of places (the reasons for each number: the comment on `snapIn` above).
final class SnapDrag {
    let ticker = Ticker()
    /// The place holding the box (nil while it follows the hand), where the hand would put it, this drag's places.
    private(set) var place: Place?
    private(set) var raw = NSPoint.zero
    private(set) var places: Places?
    /// Counted for the tests (the trackpad's tap itself cannot be observed).
    private(set) var taps = 0
    private let get: () -> NSPoint
    private let set: (NSPoint) -> Void
    init(get: @escaping () -> NSPoint, set: @escaping (NSPoint) -> Void) { self.get = get; self.set = set }

    var running: Bool { places != nil }

    /// Follows the mouse from a mouse-down until it goes up (a tracking loop, as AppKit's own window dragging does; the
    /// motion timer keeps running in the tracking mode). Returns the place it ends at.
    @discardableResult
    func track(_ w: NSWindow, places ps: Places) -> Place? {
        begin(ps)
        let p0 = trialPointer ?? NSEvent.mouseLocation, start = get()
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let p = trialPointer ?? NSEvent.mouseLocation
            move(NSPoint(x: start.x + (p.x - p0.x), y: start.y + (p.y - p0.y)), ps)
            if e.type == .leftMouseUp { break }
        }
        return end()
    }

    /// Taken: held at its place, or, caught while still sliding to one, free from where it is.
    func begin(_ ps: Places) {
        ticker.stop()
        let here = get()
        places = ps
        place = ps.at(here)
        raw = here
    }

    /// One step of a drag: where the hand would put the box is `r`.
    func move(_ r: NSPoint, _ ps: Places) {
        guard places != nil else { return }
        raw = ps.clamp(r)
        if let held = place {
            if dist(ps.point(held), raw) > snapOut { place = nil; glide(snapStep) }
        } else {
            let n = ps.nearest(raw)
            if dist(ps.point(n), raw) <= snapIn { place = n; tap(); glide(snapStep) }
        }
        if !ticker.running { put(target) }
    }

    /// Where the box goes now: its place while held, else under the hand.
    private var target: NSPoint { place.flatMap { p in places?.point(p) } ?? raw }

    private func put(_ p: NSPoint) { set(NSPoint(x: p.x.rounded(), y: p.y.rounded())) }

    /// An eased slide from where the box is drawn to the target, which may keep moving with the hand meanwhile.
    private func glide(_ d: Double) {
        let from = get()
        ticker.run { [weak self] t in
            guard let self else { return false }
            let to = self.target, k = Curve.ease(min(1, t / d))
            self.put(t >= d ? to : NSPoint(x: mix(from.x, to.x, k), y: mix(from.y, to.y, k)))
            return t < d
        }
    }

    /// Let go: held, it stays; between places, it slides to the nearest one, longer for a longer way: 0.2 s plus 1 s per
    /// 1500 pt, at most 0.45 s (a first 0.3 s cap moved it 88 pt in one frame over 380 pt in the trial of 2026-11-15;
    /// this keeps the fastest frame near 30 pt). Returns the place, for the caller to remember.
    @discardableResult
    func end() -> Place? {
        guard let ps = places else { return nil }
        if place == nil {
            let n = ps.nearest(raw)
            place = n
            glide(min(0.45, 0.2 + Double(dist(ps.point(n), get())) / 1500))
        }
        if let p = place { raw = ps.point(p) }   // with no drag running, target is this: a slide still running ends there
        places = nil
        return place
    }

    /// The trackpad's alignment tap (NSHapticFeedbackManager), as the system gives when something snaps into line.
    func tap() {
        taps += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

extension PanelController {
    /// The fifteen places for the current height on the current screen.
    var places: Places? { screen.map { PlaceGrid($0).places(height: height) } }

    /// Taken by its edge (Spotlight's way): the shared soft-magnet drag; the place is remembered for this screen.
    func drag(from down: NSEvent) {
        guard let w = window, let ps = places else { return }
        landed(snap.track(w, places: ps))
    }

    // The drag's steps, for the tests.
    func dragBegin(places ps: Places) { snap.begin(ps) }
    func dragMove(raw r: NSPoint, places ps: Places) { snap.move(r, ps) }
    func dragEnd() { landed(snap.end()) }
    var hapticTaps: Int { snap.taps }

    /// The drag has put the panel at `p`: remembered for this screen, and from now its row's edge is the one that holds.
    private func landed(_ p: Place?) {
        guard let p, let sc = screen else { return }
        store.setSetting(placeKey + screenKey(sc), p.rawValue)
        row = p.row
    }

    /// Settings' «Position on Screen»: the place for the screen the panel opens on (the main one when it is closed).
    func setPlace(_ p: Place, on s: NSScreen) {
        store.setSetting(placeKey + screenKey(s), p.rawValue)
        if isVisible, screen == s {
            row = p.row
            let g = PlaceGrid(s), h = contentHeight()
            left = g.left(p.column)
            setBox(height: h, top: g.top(p.row, height: h))
        }
    }
}
