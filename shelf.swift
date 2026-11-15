// The shelf: what the paste queue shows while it is open (queue.swift). His looks at it (2026-11-15, card «His look at
// the 0.7 shelf variants»): a list, a capsule and a deck were shot; then the history's own panel was built as his idea
// for the list and tried by his hand (~10:00): «огромное… неудобное». The shelf is the small deck (deck.swift), as
// macOS's screenshot thumbnails. It never takes the keyboard, so the app copied from and pasted into stays in front;
// after the last paste it closes itself (his word: «сразу закрывается и всё»).
import AppKit

final class Shelf: NSObject {
    let queue: PasteQueue
    let deck: Deck

    init(queue: PasteQueue, store: Store) {
        self.queue = queue
        deck = Deck(queue: queue, store: store)
        super.init()
        queue.onChange = { [weak self] c in self?.deck.changed(c) }
        queue.onEmptied = { [weak self] in
            // The last card flies off; then the deck goes too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if self?.queue.left == 0 { self?.close() } }
        }
    }

    func toggle() { queue.isOpen ? close() : open() }

    func open() {
        queue.newestFirst = queue.store.newestFirst
        queue.open()
    }

    func close() { queue.close() }
}

/// The shelf's close button, round as Notification Center's (the queue's key is settable, so the tip names none).
/// His trial 2026-11-15 10:47: the first one (SF «xmark.circle.fill» in tertiaryLabelColor) was a translucent grey disc
/// with a dark cross: hard to see on a dark window, and the picture behind showed through it. Floating close buttons
/// that stay readable on any background (Notification Center's, iOS's screenshot editor, Safari's tab overview) are an
/// opaque disc in the window colour with the cross in the text colour, a hairline ring and a small shadow that parts it
/// from whatever is under it. So is this one, light and dark from the system.
final class CloseButton: NSButton {
    var onClick: () -> Void = {}
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        title = ""
        setAccessibilityLabel("Close")
        target = self; action = #selector(clicked)
        toolTip = "Close Paste Queue"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { onClick() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let pressed = isHighlighted
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.3)
        sh.shadowBlurRadius = 2; sh.shadowOffset = NSSize(width: 0, height: -0.5)
        sh.set()
        (dark ? NSColor(white: pressed ? 0.36 : 0.26, alpha: 1) : NSColor(white: pressed ? 0.86 : 1, alpha: 1)).setFill()
        disc.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 0, alpha: 0.2)).setStroke()
        disc.lineWidth = 0.5
        disc.stroke()
        // The cross: 6 pt arms, as Notification Center's, in the text colour.
        let c = NSPoint(x: bounds.midX, y: bounds.midY), a: CGFloat = 3.1
        let x = NSBezierPath()
        x.move(to: NSPoint(x: c.x - a, y: c.y - a)); x.line(to: NSPoint(x: c.x + a, y: c.y + a))
        x.move(to: NSPoint(x: c.x - a, y: c.y + a)); x.line(to: NSPoint(x: c.x + a, y: c.y - a))
        x.lineWidth = 1.6; x.lineCapStyle = .round
        (dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.2, alpha: 1)).setStroke()
        x.stroke()
    }
}
