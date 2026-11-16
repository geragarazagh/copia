// The paste queue's deck (his trial of 0.7 by hand, 2026-11-15 ~10:00: the history panel as the shelf is «огромное…
// неудобное»; the shelf is small, «как карточки Apple Screenshot», at any of the nine places). A small stack of cards
// the size of macOS's floating screenshot thumbnail: the next item on the front card, readable (a text's first lines, a
// picture, a file's icon and name), the edges of the next two behind it, the number left in the person's accent colour.
// Motion read from macOS 27.2's own thumbnail, filmed frame by frame in the agents' session (a helper, 2026-11-15):
// it fades in where it sits, about 0.4 s with an ease-in-out (no slide, no scale), and leaves by sliding off the
// nearest screen edge at full size, accelerating, about 0.23 s for its first 100 pt, barely fading. So does a pasted
// card here. The deck is dragged by its edges to any of the nine places (the history panel's soft magnets,
// place.swift); the front card itself drags out into any app like a file, and that drop is a paste too.
import AppKit

/// The thumbnail's own size (180.5 × 119.5 pt measured) grown a little so two lines of text read: one card.
let deckCard = NSSize(width: 192, height: 128)
/// How far each card behind shows above the one in front of it, how much narrower it is per side, how many show.
let deckStep: CGFloat = 7, deckInset: CGFloat = 10, deckDepth = 2
/// The thumbnail sits 12.5 pt from the screen's right edge; the deck keeps that margin from every edge.
let deckGap: CGFloat = 12
/// Room around the box inside its window: the badge overhangs the front card's corner by half, and the shadow.
let deckMargin: CGFloat = 28
var deckBox: NSSize { NSSize(width: deckCard.width, height: deckCard.height + CGFloat(deckDepth) * deckStep) }

final class Deck: NSObject, NSDraggingSource {
    let queue: PasteQueue
    let store: Store
    let window: DeckWindow
    let view: DeckView
    var screen: NSScreen?
    private var cards: [(Int, DeckCard)] = []   // (place in the queue, or -1 for the empty card), front first
    private let motion = Ticker(), fade = Ticker(), cardFade = Ticker()
    /// Where the box's top-left corner is on the screen (screen points, y upwards), as the panel's left and top.
    private(set) var origin = NSPoint.zero
    /// Where the pointer is, in screen points (a trial's own pointer when there is one); the tests set it.
    var pointer: () -> NSPoint = { trialPointer ?? NSEvent.mouseLocation }
    init(queue: PasteQueue, store: Store) {
        self.queue = queue
        self.store = store
        view = DeckView(frame: NSRect(origin: .zero, size: deckBox))
        window = DeckWindow(view: view)
        super.init()
        view.owner = self
        view.close.onClick = { [weak self] in self?.queue.close() }
    }

    // MARK: its place

    /// The bottom right, always, where the screenshot thumbnail sits (his word 2026-11-15 11:25, his trial of f1be23d:
    /// «скриншоты тоже нельзя перетаскивать… пускай оно просто будет справа, снизу… в самом неприметном углу»). The
    /// drag to nine places that 0.7 had is gone: he could not make it move and does not want it.
    func placeFor(_ s: NSScreen) -> Place { .bottomRight }

    /// The box's top left point at the bottom right: one margin from the visible frame's edges.
    func restPoint(on s: NSScreen) -> NSPoint {
        let v = s.visibleFrame
        return NSPoint(x: v.maxX - deckGap - deckBox.width, y: v.minY + deckGap + deckBox.height)
    }

    func move(to p: NSPoint) {
        origin = p
        window.setFrame(NSRect(x: p.x - deckMargin, y: p.y - deckBox.height - deckMargin,
                               width: deckBox.width + 2 * deckMargin, height: deckBox.height + 2 * deckMargin), display: true)
    }

    /// The window's origin when the deck sits at its place.
    private var restOrigin: NSPoint { NSPoint(x: origin.x - deckMargin, y: origin.y - deckBox.height - deckMargin) }

    // MARK: the queue's changes

    func changed(_ c: PasteQueue.Change) {
        switch c {
        case .opened: appear()
        case .closed: disappear()
        case .added: rebuild(animated: true)
        case .pasted: cardLeaves()
        }
    }

    /// Fades in where it sits, as the thumbnail: 0.4 s, ease-in-out.
    private func appear() {
        let mouse = NSEvent.mouseLocation
        screen = trialScreen() ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        motion.stop(); endCapture(); flingTicker.stop(); fling = nil; scroll = nil; pendingLeave = nil
        for (_, c) in cards { c.removeFromSuperview() }
        cards = []
        rebuild(animated: false)
        if let s = screen { move(to: restPoint(on: s)) }
        window.alphaValue = 0
        window.orderFrontRegardless()
        fade.run { [weak self] t in
            self?.window.alphaValue = CGFloat(Curve.easeInOut(min(1, t / 0.4)))
            return t < 0.4
        }
    }

    private func disappear() {
        fade.run { [weak self] t in
            guard let self else { return false }
            self.window.alphaValue = CGFloat(1 - min(1, t / 0.15))
            if t >= 0.15 { self.window.orderOut(nil); self.window.alphaValue = 1 }
            return t < 0.15
        }
    }

    /// Card k from the front (0) to the back, in the box (flipped).
    func cardFrame(_ k: Int) -> NSRect {
        NSRect(x: CGFloat(k) * deckInset, y: CGFloat(deckDepth - k) * deckStep, width: deckCard.width - 2 * CGFloat(k) * deckInset,
               height: deckCard.height)
    }

    /// The cards for the queue now: the next items, front first, or one empty card. Cards already shown keep their
    /// view; a new one comes in at the back (it fades in over 0.2 s when `animated`).
    /// After the last paste (`emptyCard` false) no empty card comes in: the queue is closing, and the empty card
    /// faded in for 0.35 s before the deck left (the site block's frame-by-frame check against 0.8, 2026-11-15).
    private func rebuild(animated: Bool, emptyCard: Bool = true) {
        let want: [Int] = queue.pending.isEmpty ? (emptyCard ? [-1] : []) : Array(queue.pending.prefix(deckDepth + 1))
        var next: [(Int, DeckCard)] = []
        for i in want {
            if let have = cards.first(where: { $0.0 == i }) { next.append(have); continue }
            let c = DeckCard(i >= 0 ? store.entry(queue.ids[i]) : nil, store: store)
            if animated { c.alphaValue = 0 }
            next.append((i, c))
        }
        for (i, c) in cards where !next.contains(where: { $0.0 == i }) { c.removeFromSuperview() }
        cards = next
        layoutCards(from: nil)
        if animated {
            let fresh = cards.map(\.1).filter { $0.alphaValue == 0 }
            cardFade.run { t in
                for c in fresh { c.alphaValue = CGFloat(min(1, t / 0.2)) }
                return t < 0.2
            }
        }
        view.update(left: queue.left, front: cardFrame(0))
    }

    /// Puts the cards in their frames, back to front; with `from`, each moves there from its old frame in 0.2 s.
    private func layoutCards(from old: [DeckCard: NSRect]?) {
        for (k, (_, c)) in cards.enumerated().reversed() {
            view.addSubview(c, positioned: .below, relativeTo: view.badge)
            c.frame = old?[c] ?? cardFrame(k)
        }
        guard let old, !old.isEmpty else { return }
        let to = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($0.1.1, cardFrame($0.0)) })
        motion.run { t in
            let k = Curve.bezier(min(1, t / 0.2), 0, 0, 0.58, 1)   // ease-out: the next card comes forward
            for (c, f) in to { c.frame = mix(old[c] ?? f, f, k) }
            return t < 0.2
        }
    }

    /// A paste: the front card slides off the nearest screen edge, accelerating, at full size (the thumbnail's way),
    /// in a window of its own so nothing clips it; the cards behind come forward.
    private func cardLeaves() {
        if let p = pendingLeave { pendingLeave = nil; p() }   // a paste within the two frames: the last one's change first
        guard let (_, front) = cards.first, let s = screen else { rebuild(animated: false); return }
        let img = front.snapshot()
        let rect = view.convert(front.frame, to: nil), onScreen = window.convertToScreen(rect)
        let fly = NSPanel(contentRect: onScreen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        fly.isOpaque = false; fly.backgroundColor = .clear; fly.hasShadow = true; fly.level = window.level
        fly.ignoresMouseEvents = true; fly.collectionBehavior = window.collectionBehavior
        let iv = NSImageView(frame: NSRect(origin: .zero, size: onScreen.size)); iv.image = img; iv.imageScaling = .scaleNone
        fly.contentView = iv
        fly.orderFrontRegardless()
        fly.displayIfNeeded()
        // The front card stays two frames under its flying copy: a new window reaches the screen a frame after the
        // deck's own change, and that frame showed the deck without its front card and nothing flying (the site
        // block's 120 fps check against 0.8, 2026-11-15).
        pendingLeave = { [weak self] in
            guard let self, self.cards.first?.1 === front else { return }
            front.removeFromSuperview()
            let old = Dictionary(uniqueKeysWithValues: self.cards.dropFirst().enumerated().map { ($0.1.1, self.cardFrame($0.0 + 1)) })
            self.cards.removeFirst()
            self.rebuild(animated: true, emptyCard: false)
            self.layoutCards(from: old)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 / 60) { [weak self] in
            guard let self, let p = self.pendingLeave else { return }
            self.pendingLeave = nil; p()
        }
        // Off the nearest edge: sideways for the side columns, up or down for the centre column's top and bottom.
        let p = placeFor(s), f = s.frame
        var d = NSPoint.zero
        switch (p.column, p.row) {
        case (.left, _): d.x = -(onScreen.maxX - f.minX)
        case (.centre, .top): d.y = f.maxY - onScreen.minY
        case (.centre, .bottom): d.y = -(onScreen.maxY - f.minY)
        default: d.x = f.maxX - onScreen.minX
        }
        let dur = 0.23 * max(1, (Double(hypot(d.x, d.y)) / 200).squareRoot())
        let flyTicker = Ticker()
        flyTicker.run { t in
            let k = Curve.bezier(min(1, t / dur), 0.42, 0, 1, 1)   // ease-in, as the thumbnail accelerates away
            fly.setFrameOrigin(NSPoint(x: onScreen.minX + d.x * CGFloat(k), y: onScreen.minY + d.y * CGFloat(k)))
            fly.alphaValue = CGFloat(1 - 0.3 * k)
            if t >= dur { fly.orderOut(nil) }
            return t < dur
        }
        flying.append(flyTicker)
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.1) { [weak self] in self?.flying.removeAll { !$0.running } }
    }
    private var flying: [Ticker] = []
    private var pendingLeave: (() -> Void)?

    // MARK: flung off

    /// Sent off its edge, as the screenshot thumbnail: two fingers on the trackpad, or the mouse pressed on it and
    /// moved, to the right (his word 2026-11-15 10:47, and 11:25: «смахивалась не только трекпадом, а ещё и просто
    /// мышкой»). The deck follows the hand to the right, and a little (a quarter) to the left; let go far enough (40 pt)
    /// or fast enough (300 pt/s over the last 0.1 s), it slides off the right edge and the queue closes; otherwise it
    /// comes back in 0.2 s. His trial of f1be23d (11:25): it wandered left and right and rarely went, because the deck
    /// slid away from under the pointer and the rest of the gesture went to the window now under it; the rest of a
    /// trackpad gesture is now taken wherever it goes (an event monitor, scroll events need no permission), and the
    /// deck always comes back to its place, never to where it had been dragged.
    private var fling: (dx: CGFloat, samples: [(CGFloat, TimeInterval)])?
    private let flingTicker = Ticker()

    private func flingBegin() {
        flingTicker.stop()
        fling = (0, [])
    }

    private func flingTo(_ dx: CGFloat, at t: TimeInterval) {
        guard var f = fling else { return }
        f.dx = dx
        f.samples.append((dx, t))
        f.samples.removeAll { t - $0.1 > 0.1 }
        fling = f
        window.setFrameOrigin(NSPoint(x: restOrigin.x + (dx >= 0 ? dx : dx / 4), y: restOrigin.y))
    }

    private func flingEnd() {
        guard let f = fling else { return }
        fling = nil
        var speed: CGFloat = 0
        if let a = f.samples.first, let b = f.samples.last, b.1 - a.1 > 0.005 { speed = (b.0 - a.0) / CGFloat(b.1 - a.1) }
        if f.dx > 40 || (speed > 300 && f.dx > 8) { flingOff() } else { flingBack() }
    }

    private func flingBack() {
        let from = window.frame.origin, to = restOrigin
        flingTicker.run { [weak self] t in
            let k = CGFloat(Curve.bezier(min(1, t / 0.2), 0, 0, 0.58, 1))
            self?.window.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * k, y: to.y))
            return t < 0.2
        }
    }

    /// Off the right edge, accelerating as a pasted card leaves; then the queue closes.
    private func flingOff() {
        let f = window.frame, edge = (screen ?? window.screen)?.frame.maxX ?? f.maxX
        let start = f.minX, d = edge - f.minX
        let dur = 0.23 * max(1, (Double(d) / 200).squareRoot())
        flingTicker.run { [weak self] t in
            guard let self else { return false }
            let k = CGFloat(Curve.bezier(min(1, t / dur), 0.42, 0, 1, 1))
            self.window.setFrameOrigin(NSPoint(x: start + d * k, y: f.minY))
            if t >= dur {
                self.window.orderOut(nil)
                self.queue.close()
            }
            return t < dur
        }
    }

    // The trackpad: a scroll gesture that starts on the deck and goes sideways.
    private var scroll: (dx: CGFloat, horizontal: Bool?)?
    private var localMonitor: Any?, globalMonitor: Any?
    private var gesture = 0

    func scrolled(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase == [], queue.isOpen else { return }
        if e.phase == .began {
            scroll = (0, nil)
            beginCapture()
        }
        guard var s = scroll else { return }
        // The way the fingers moved: with natural scrolling the deltas follow them, without it they oppose them.
        let fx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        let fy = e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY
        if e.phase == .began || e.phase == .changed {
            if s.horizontal == nil, abs(fx) + abs(fy) > 0 {
                s.horizontal = abs(fx) > abs(fy)
                if s.horizontal == true { flingBegin() } else { endCapture() }
            }
            if s.horizontal == true { s.dx += fx; flingTo(s.dx, at: e.timestamp) }
            scroll = s
            return
        }
        scroll = nil
        endCapture()
        if s.horizontal == true {
            if e.phase == .ended { flingEnd() } else { fling = nil; flingBack() }
        }
    }

    /// The rest of the gesture, wherever the pointer is now: our own windows' events stop here (they would come twice),
    /// other apps' are watched; both end with the gesture, or after a second with none.
    private func beginCapture() {
        endCapture()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, self.scroll != nil else { return e }
            self.scrolled(e)
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.scrolled(e) }
        gesture += 1
        let g = gesture
        // A gesture whose end never came (the trackpad let go mid-way): after 3 s it is over and the deck goes back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.gesture == g, self.scroll != nil else { return }
            self.scroll = nil
            self.endCapture()
            if self.fling != nil { self.fling = nil; self.flingBack() }
        }
    }

    private func endCapture() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    // The mouse: pressed on the deck and moved to the right (from the front card, any other way drags the item out).
    private var press: (at: NSPoint, onCard: Bool, flinging: Bool)?

    func mouseDown(onCard: Bool) {
        flingTicker.stop()
        press = (pointer(), onCard, false)
    }

    /// Returns true when the press became a drag of the item out (the view starts it).
    func mouseDragged(_ e: NSEvent) -> Bool {
        guard var p = press else { return false }
        let now = pointer(), dx = now.x - p.at.x, dy = now.y - p.at.y
        if !p.flinging {
            guard hypot(dx, dy) >= 3 else { return false }
            if dx > 0 && dx >= abs(dy) || !p.onCard {
                p.flinging = true; press = p
                flingBegin()
            } else {
                press = nil
                return true
            }
        }
        flingTo(dx, at: e.timestamp)
        return false
    }

    func mouseUp() {
        guard let p = press else { return }
        press = nil
        if p.flinging { flingEnd() }
    }

    // MARK: the front card dragged out

    private var draggedIndex: Int?

    /// The front card dragged out like a file: the item's own files and text (drag.swift); a drop pastes it, so the
    /// queue moves on.
    func dragOut(event: NSEvent) {
        guard let (i, c) = cards.first, i >= 0, let e = store.entry(queue.ids[i]) else { return }
        let items = Drag.items([e], store: store)
        guard !items.isEmpty else { return }
        draggedIndex = i
        let img = c.snapshot()
        let dragging = items.enumerated().map { k, it -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: it)
            d.setDraggingFrame(c.frame.offsetBy(dx: CGFloat(k) * 4, dy: CGFloat(k) * 4), contents: img)
            return d
        }
        let s = view.beginDraggingSession(with: dragging, event: event, source: self)
        s.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation o: NSDragOperation) {
        defer { draggedIndex = nil }
        if o != [], let i = draggedIndex, queue.nextIndex == i { queue.take() }
    }
}

/// Never takes the keyboard: copying and pasting go on in the app in front.
final class DeckWindow: NSPanel {
    init(view: NSView) {
        let size = NSSize(width: deckBox.width + 2 * deckMargin, height: deckBox.height + 2 * deckMargin)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .floating; isFloatingPanel = true; hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true; isReleasedWhenClosed = false; animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = FlippedView(frame: NSRect(origin: .zero, size: size))
        view.frame.origin = NSPoint(x: deckMargin, y: deckMargin)
        root.addSubview(view)
        contentView = root
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The box: the cards, the count badge on the front card's corner, a close button that shows while the pointer is over
/// the deck. A press on the front card drags the item out; anywhere else moves the deck.
final class DeckView: NSView {
    weak var owner: Deck?
    let badge = Badge()
    let close = CloseButton()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        badge.isHidden = true
        close.isHidden = true
        addSubview(badge); addSubview(close)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The count of items left, as Apple's badges: the accent colour (Badge draws controlAccentColor), on the front
    /// card's top right corner; the close button on its top left.
    func update(left: Int, front: NSRect) {
        badge.number = left > 0 ? left : nil
        badge.isHidden = left == 0
        badge.frame = NSRect(x: front.maxX - 12, y: front.minY - 12, width: 24, height: 24)
        close.frame = NSRect(x: front.minX - 8, y: front.minY - 8, width: 20, height: 20)
        addSubview(close, positioned: .above, relativeTo: nil)
        addSubview(badge, positioned: .above, relativeTo: nil)
    }

    override func mouseEntered(with e: NSEvent) { close.isHidden = false }
    override func mouseExited(with e: NSEvent) { close.isHidden = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func hitTest(_ p: NSPoint) -> NSView? {
        let q = convert(p, from: superview)
        if !close.isHidden && close.frame.contains(q) { return close }
        return bounds.insetBy(dx: -deckMargin, dy: -deckMargin).contains(q) ? self : nil
    }

    override func mouseDown(with e: NSEvent) {
        guard let o = owner else { return }
        let q = convert(e.locationInWindow, from: nil)
        o.mouseDown(onCard: o.cardFrame(0).contains(q) && q.y > o.cardFrame(0).minY + 2)
    }
    override func mouseDragged(with e: NSEvent) {
        if owner?.mouseDragged(e) == true { owner?.dragOut(event: e) }
    }
    override func mouseUp(with e: NSEvent) { owner?.mouseUp() }
    override func scrollWheel(with e: NSEvent) { owner?.scrolled(e) }
}

/// One card: the item large, as Quick Look's first look shows it: a picture filling the card, a file's icon with its
/// name, a link's title and site, or a text's first lines; its facts small at the bottom. Opaque, as cards of paper:
/// glass on glass showed the card behind through the front one (first trial). Light and dark follow the system.
final class DeckCard: NSView {
    private let body = FlippedView()
    private let picture = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private let facts = NSTextField(labelWithString: "")
    private var fills = false
    override var isFlipped: Bool { true }

    init(_ e: Entry?, store: Store) {
        super.init(frame: NSRect(origin: .zero, size: deckCard))
        wantsLayer = true
        layer?.shadowOpacity = 0.22; layer?.shadowRadius = 6; layer?.shadowOffset = NSSize(width: 0, height: -2)
        body.wantsLayer = true
        body.layer?.cornerRadius = 10; body.layer?.cornerCurve = .continuous; body.layer?.masksToBounds = true
        body.layer?.borderWidth = 0.5
        addSubview(body)
        for v in [picture, text, facts] { body.addSubview(v) }
        text.font = .systemFont(ofSize: 12)
        text.maximumNumberOfLines = 6
        text.lineBreakMode = .byWordWrapping
        text.cell?.truncatesLastVisibleLine = true
        facts.font = .systemFont(ofSize: 10.5)
        facts.textColor = .secondaryLabelColor
        facts.lineBreakMode = .byTruncatingTail
        picture.imageScaling = .scaleProportionallyUpOrDown
        guard let e else {
            picture.isHidden = true; facts.isHidden = true
            text.stringValue = L("Copy to add to the queue")
            text.textColor = .secondaryLabelColor
            text.alignment = .center
            return
        }
        facts.stringValue = metaFacts(e)
        switch e.kind {
        case .image:
            if let f = e.thumb, let im = NSImage(contentsOf: store.dir.appendingPathComponent(f)) { picture.image = im }
            picture.imageScaling = .scaleAxesIndependently
            fills = true
            text.isHidden = true
        case .files:
            picture.image = Thumbs.shared.thumb(e, store: store, side: 48)
            text.stringValue = shownTitle(e)
            text.alignment = .center
            text.maximumNumberOfLines = 2
        case .link:
            picture.isHidden = true
            text.stringValue = e.title
            text.font = .systemFont(ofSize: 12, weight: .semibold)
        default:
            picture.isHidden = true
            text.stringValue = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        body.frame = bounds
        body.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        body.layer?.borderColor = NSColor.separatorColor.cgColor
        let w = bounds.width, h = bounds.height
        facts.frame = NSRect(x: 10, y: h - 8 - 13, width: w - 20, height: 13)
        if fills {
            // A picture fills the card above the facts, cropped to it.
            let room = NSSize(width: w, height: h - 26)
            var f = NSRect(origin: .zero, size: room)
            if let im = picture.image, im.size.width > 0, im.size.height > 0 {
                let a = im.size.width / im.size.height, r = room.width / room.height
                f = a > r ? NSRect(x: (room.width - room.height * a) / 2, y: 0, width: room.height * a, height: room.height)
                          : NSRect(x: 0, y: (room.height - room.width / a) / 2, width: room.width, height: room.width / a)
            }
            picture.frame = f
        } else if !picture.isHidden {
            picture.frame = NSRect(x: (w - 48) / 2, y: 12, width: 48, height: 48)
            text.frame = NSRect(x: 10, y: 66, width: w - 20, height: 32)
        } else if facts.isHidden {
            text.frame = NSRect(x: 10, y: (h - 16) / 2, width: w - 20, height: 16)
        } else {
            text.frame = NSRect(x: 10, y: 9, width: w - 20, height: h - 9 - 26)
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsLayout = true }

    /// The card as drawn, for its flight off the screen and for dragging.
    func snapshot() -> NSImage {
        layoutSubtreeIfNeeded()
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }
}
