// The shelf: what the paste queue shows while it is open (queue.swift). It floats over the work and never takes the
// keyboard, so the app being copied from and pasted into stays in front. Three looks were built for his first look
// (2026-11-15; COPIA_SHELF=list|pill|deck until he picks, then the others go):
// - list: a small glass list in the bottom right corner (the screenshot thumbnail's corner; the top right is where
//   notifications come and would cover it, seen in the first trial); every item in order, the next one at the top in
//   the accent colour, a pasted one slides out of the top;
// - pill: one capsule under the menu bar in the middle, with only the next item and the count;
// - deck (the bold one): a stack of cards in the bottom right corner, the next item large on the front card; a paste
//   takes the front card away.
import AppKit

enum ShelfLookKind: String { case list, pill, deck }
let shelfLook = ShelfLookKind(rawValue: ProcessInfo.processInfo.environment["COPIA_SHELF"] ?? "") ?? .list

/// Room around the box inside the window for the glass's shadow.
let shelfMargin: CGFloat = 40

protocol ShelfLook: NSView {
    /// The box for the queue's state now.
    func boxSize(_ q: PasteQueue) -> NSSize
    /// Shows the state; `change` says what just happened, for the motion (nil: no motion).
    func show(_ q: PasteQueue, store: Store, change: PasteQueue.Change?)
    var onClose: () -> Void { get set }
}

final class Shelf: NSObject {
    let queue: PasteQueue
    let store: Store
    let look: ShelfLook
    let window: ShelfPanel
    var screen: NSScreen?

    init(queue: PasteQueue, store: Store, kind: ShelfLookKind = shelfLook) {
        self.queue = queue
        self.store = store
        switch kind {
        case .list: look = ListLook()
        case .pill: look = PillLook()
        case .deck: look = DeckLook()
        }
        window = ShelfPanel(look: look)
        super.init()
        look.onClose = { [weak self] in self?.close() }
        queue.onChange = { [weak self] c in self?.changed(c) }
        // The last item pasted: the job is done, the shelf goes (Claude's pick, asked of him 2026-11-15).
        queue.onEmptied = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self?.queue.left == 0 { self?.close() } }
        }
    }

    func toggle() { queue.isOpen ? close() : open() }

    func open() {
        let mouse = NSEvent.mouseLocation
        screen = trialScreen() ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        queue.open()
    }

    func close() { queue.close() }

    private func changed(_ c: PasteQueue.Change) {
        switch c {
        case .opened:
            look.show(queue, store: store, change: nil)
            place(animated: false)
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { x in
                x.duration = 2.0 / 60; x.timingFunction = CAMediaTimingFunction(name: .linear)
                window.animator().alphaValue = 1
            }
        case .closed:
            NSAnimationContext.runAnimationGroup({ x in
                x.duration = 0.085; x.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.queue.isOpen else { return }
                self.window.orderOut(nil); self.window.alphaValue = 1
            })
        default:
            look.show(queue, store: store, change: c)
            place(animated: true)
        }
    }

    /// The window around the box, anchored where the look lives: its top centre or bottom right corner stays put while
    /// the box grows or shrinks.
    func place(animated: Bool) {
        guard let s = screen ?? NSScreen.main else { return }
        let v = s.visibleFrame, b = look.boxSize(queue)
        let w = b.width + 2 * shelfMargin, h = b.height + 2 * shelfMargin
        var o = NSPoint.zero
        switch look {
        case is PillLook: o = NSPoint(x: (v.midX - w / 2).rounded(), y: s.frame.maxY - 38 - b.height - shelfMargin)
        default: o = NSPoint(x: v.maxX - 16 - b.width - shelfMargin, y: v.minY + 16 - shelfMargin)
        }
        let f = NSRect(x: o.x, y: o.y, width: w, height: h)
        if animated {
            NSAnimationContext.runAnimationGroup { x in
                x.duration = 0.2; x.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                window.animator().setFrame(f, display: true)
            }
        } else {
            window.setFrame(f, display: true)
        }
    }
}

/// A panel that never takes the keyboard and never activates the app: copying and pasting go on in the app in front.
final class ShelfPanel: NSPanel {
    init(look: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        look.frame = root.bounds.insetBy(dx: shelfMargin, dy: shelfMargin)
        look.autoresizingMask = [.width, .height]
        root.addSubview(look)
        contentView = root
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: parts

/// Liquid Glass on macOS 26+ (following the person's setting), the popover's material before.
final class GlassBox: NSView {
    let content = FlippedView()
    private var background: NSView!
    var corner: CGFloat { didSet { apply() } }
    override var isFlipped: Bool { true }

    init(corner: CGFloat) {
        self.corner = corner
        super.init(frame: .zero)
        wantsLayer = true
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.contentView = content
            background = g
        } else {
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.borderWidth = 0.5
            v.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            v.addSubview(content)
            background = v
        }
        addSubview(background)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        if #available(macOS 26.0, *), let g = background as? NSGlassEffectView { g.cornerRadius = corner }
        background.layer?.cornerRadius = corner
        background.layer?.cornerCurve = .continuous
        content.layer?.cornerRadius = corner
        content.layer?.cornerCurve = .continuous
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        content.frame = bounds
    }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); needsLayout = true }
}

func shelfLabel(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    return l
}

/// The small round close button of a floating card (Notification Center's, a widget's).
final class CloseButton: NSButton {
    var onClick: () -> Void = {}
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        contentTintColor = .tertiaryLabelColor
        target = self; action = #selector(clicked)
        toolTip = "Close Paste Queue (⌃⌥C)"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { onClick() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

/// «3 of 7»: the next item's place in the copy order and how many were copied.
func queueCount(_ q: PasteQueue) -> String { "\(q.next + 1) of \(q.ids.count)" }

// MARK: list

/// One row of the list: the picture, the text's start or the file's name, the copy order as a plain number at the
/// trailing end (his pick for the panel's rows, 0.5); the next item drawn in the accent colour, as a selected row.
final class ShelfRow: NSView {
    let picture = NSImageView()
    let title = shelfLabel("", size: 13)
    let number = shelfLabel("", size: 12)
    var isNext = false { didSet { needsDisplay = true; colours() } }
    override var isFlipped: Bool { true }

    init(_ e: Entry, order: Int, store: Store) {
        super.init(frame: .zero)
        wantsLayer = true
        picture.image = Thumbs.shared.thumb(e, store: store, side: 24)
        title.stringValue = e.title.replacingOccurrences(of: "\n", with: " ")
        number.stringValue = "\(order)"
        number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        number.alignment = .right
        for v in [picture, title, number] { addSubview(v) }
        colours()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func colours() {
        title.textColor = isNext ? .alternateSelectedControlTextColor : .labelColor
        number.textColor = isNext ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        picture.frame = NSRect(x: 10, y: (h - 24) / 2, width: 24, height: 24)
        number.frame = NSRect(x: bounds.width - 10 - 28, y: (h - 16) / 2, width: 28, height: 16)
        title.frame = NSRect(x: 44, y: (h - 17) / 2, width: bounds.width - 44 - 44, height: 17)
    }

    override func draw(_ r: NSRect) {
        guard isNext else { return }
        NSColor.controlAccentColor.setFill()   // the person's accent, never a fixed blue (rules.md)
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

final class ListLook: NSView, ShelfLook {
    static let width: CGFloat = 300, head: CGFloat = 40, rowH: CGFloat = 36, gap: CGFloat = 2, pad: CGFloat = 6, most = 8
    let glass = GlassBox(corner: 18)
    let title = shelfLabel("Paste Queue", size: 13, weight: .semibold)
    let count = shelfLabel("", size: 12, color: .secondaryLabelColor)
    let empty = shelfLabel("Copy to add to the queue", size: 12, color: .secondaryLabelColor)
    let more = shelfLabel("", size: 11, color: .tertiaryLabelColor)
    let close = CloseButton()
    var onClose: () -> Void = {} { didSet { close.onClick = onClose } }
    private var rows: [Int: ShelfRow] = [:]   // by place in the queue
    /// The rows' area under the header: it clips them, so a pasted row leaving upwards is never drawn over the title.
    private let list = FlippedView()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glass)
        list.wantsLayer = true
        list.layer?.masksToBounds = true
        glass.content.addSubview(list)
        for v in [title, count, close, empty, more] { glass.content.addSubview(v) }
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.alignment = .right
        empty.alignment = .center
        more.alignment = .center
    }
    required init?(coder: NSCoder) { fatalError() }

    private func shown(_ q: PasteQueue) -> Range<Int> { q.next..<min(q.ids.count, q.next + ListLook.most) }

    func boxSize(_ q: PasteQueue) -> NSSize {
        let n = shown(q).count
        let list = n == 0 ? 40 : CGFloat(n) * (ListLook.rowH + ListLook.gap) - ListLook.gap
        let extra: CGFloat = q.left > ListLook.most ? 22 : 0
        return NSSize(width: ListLook.width, height: ListLook.head + list + extra + ListLook.pad + 2)
    }

    private func rowFrame(_ k: Int) -> NSRect {
        NSRect(x: ListLook.pad, y: CGFloat(k) * (ListLook.rowH + ListLook.gap), width: ListLook.width - 2 * ListLook.pad,
               height: ListLook.rowH)
    }

    func show(_ q: PasteQueue, store: Store, change: PasteQueue.Change?) {
        let w = ListLook.width
        title.frame = NSRect(x: 16, y: 13, width: 160, height: 17)
        close.frame = NSRect(x: w - 10 - 20, y: 11, width: 20, height: 20)
        count.frame = NSRect(x: w - 36 - 90, y: 13, width: 90, height: 16)
        count.stringValue = q.ids.isEmpty ? "" : q.left == 0 ? "Done" : queueCount(q)
        empty.isHidden = q.left > 0
        empty.stringValue = q.ids.isEmpty ? "Copy to add to the queue" : "All pasted"
        empty.frame = NSRect(x: 12, y: ListLook.head + 10, width: w - 24, height: 16)
        let range = shown(q)
        list.frame = NSRect(x: 0, y: ListLook.head, width: w, height: 2000)
        // Pasted: the row slides up out of the top and fades, the others take their places (the system's table motion).
        for (i, r) in rows where !range.contains(i) {
            rows[i] = nil
            NSAnimationContext.runAnimationGroup({ x in
                x.duration = 0.2; x.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                r.animator().frame = r.frame.offsetBy(dx: 0, dy: -(ListLook.rowH + ListLook.gap))
                r.animator().alphaValue = 0
            }, completionHandler: { r.removeFromSuperview() })
        }
        for (k, i) in range.enumerated() {
            if let r = rows[i] {
                r.isNext = i == q.next
                if change == nil { r.frame = rowFrame(k) } else {
                    NSAnimationContext.runAnimationGroup { x in
                        x.duration = 0.2; x.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                        r.animator().frame = rowFrame(k)
                    }
                }
            } else if let e = store.entry(q.ids[i]) {
                // A new copy: in place at once; the box's bottom edge then grows to show it (Spotlight's grammar).
                let r = ShelfRow(e, order: i + 1, store: store)
                r.frame = rowFrame(k)
                r.isNext = i == q.next
                list.addSubview(r)
                rows[i] = r
            }
        }
        let hidden = q.left - range.count
        more.isHidden = hidden <= 0
        more.stringValue = "\(hidden) more"
        more.frame = NSRect(x: 12, y: ListLook.head + CGFloat(range.count) * (ListLook.rowH + ListLook.gap) + 2, width: w - 24, height: 14)
    }

    override func layout() { super.layout(); glass.frame = bounds }
}

// MARK: pill

final class PillLook: NSView, ShelfLook {
    static let h: CGFloat = 44
    let glass = GlassBox(corner: 22)
    let picture = NSImageView()
    let title = shelfLabel("", size: 13, weight: .medium)
    let count = shelfLabel("", size: 12, color: .secondaryLabelColor)
    let close = CloseButton()
    var onClose: () -> Void = {} { didSet { close.onClick = onClose } }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glass)
        for v in [picture, title, count, close] { glass.content.addSubview(v) }
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        title.wantsLayer = true
        picture.wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func width(_ l: NSTextField) -> CGFloat {
        ceil((l.stringValue as NSString).size(withAttributes: [.font: l.font!]).width) + 4
    }
    private func titleWidth() -> CGFloat { min(320, max(140, width(title))) }
    private func countWidth() -> CGFloat { count.stringValue.isEmpty ? 0 : width(count) }

    func boxSize(_ q: PasteQueue) -> NSSize {
        let pic: CGFloat = picture.isHidden ? 0 : 24 + 10
        let c = countWidth()
        return NSSize(width: 16 + pic + titleWidth() + (c > 0 ? 12 + c : 0) + 10 + 20 + 12, height: PillLook.h)
    }

    func show(_ q: PasteQueue, store: Store, change: PasteQueue.Change?) {
        let e = q.nextID.flatMap(store.entry)
        let before = title.stringValue
        if let e {
            picture.isHidden = false
            picture.image = Thumbs.shared.thumb(e, store: store, side: 24)
            title.stringValue = e.title.replacingOccurrences(of: "\n", with: " ")
            title.textColor = .labelColor
            count.stringValue = queueCount(q)
        } else {
            picture.isHidden = true
            title.stringValue = q.ids.isEmpty ? "Paste Queue: copy to add" : "All pasted"
            title.textColor = .secondaryLabelColor
            count.stringValue = ""
        }
        // The next item comes in from the trailing side as the pasted one leaves (a push, 200 ms).
        if case .pasted = change, before != title.stringValue {
            let t = CATransition()
            t.type = .push; t.subtype = .fromRight; t.duration = 0.2
            t.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            title.layer?.add(t, forKey: "push"); picture.layer?.add(t, forKey: "push")
        }
        let s = boxSize(q)
        var x: CGFloat = 16
        if !picture.isHidden { picture.frame = NSRect(x: x, y: (s.height - 24) / 2, width: 24, height: 24); x += 34 }
        title.frame = NSRect(x: x, y: (s.height - 17) / 2, width: titleWidth(), height: 17); x += titleWidth()
        let c = countWidth()
        if c > 0 { x += 12; count.frame = NSRect(x: x, y: (s.height - 16) / 2, width: c, height: 16); x += c }
        count.isHidden = c == 0
        close.frame = NSRect(x: s.width - 12 - 20, y: (s.height - 20) / 2, width: 20, height: 20)
    }

    override func layout() { super.layout(); glass.frame = bounds }
}

// MARK: deck

/// One card of the deck: the item large, as Quick Look's first look shows it: a picture filling the card, a file's
/// icon with its name, or the first lines of a text; its facts small under it.
final class DeckCard: NSView {
    /// Opaque, as cards of paper: glass on glass showed the card behind through the front one (first trial).
    let glass = FlippedView()
    let picture = NSImageView()
    let text = NSTextField(wrappingLabelWithString: "")
    let facts = shelfLabel("", size: 11, color: .secondaryLabelColor)
    override var isFlipped: Bool { true }

    init(_ e: Entry?, store: Store) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        addSubview(glass)
        for v in [picture, text, facts] { glass.addSubview(v) }
        text.font = .systemFont(ofSize: 13)
        text.maximumNumberOfLines = 5
        text.lineBreakMode = .byWordWrapping
        text.cell?.truncatesLastVisibleLine = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        if let e {
            switch e.kind {
            case .image:
                if let f = e.thumb, let im = NSImage(contentsOf: store.dir.appendingPathComponent(f)) { picture.image = im }
                picture.imageScaling = .scaleAxesIndependently
                text.isHidden = true
            case .files:
                picture.image = Thumbs.shared.thumb(e, store: store, side: 64)
                text.stringValue = e.title
                text.alignment = .center
                text.maximumNumberOfLines = 2
            default:
                picture.isHidden = true
                text.stringValue = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            facts.stringValue = metaFacts(e)
        } else {
            picture.isHidden = true
            text.stringValue = "Copy to add to the queue"
            text.textColor = .secondaryLabelColor
            text.alignment = .center
            facts.isHidden = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        glass.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        glass.layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        glass.frame = bounds
        updateLayer()
        let w = bounds.width, h = bounds.height
        facts.frame = NSRect(x: 14, y: h - 12 - 14, width: w - 28, height: 14)
        if !picture.isHidden && text.isHidden {
            // A picture: fills the card, cropped to it; the facts on a band of the card's glass at the bottom.
            picture.frame = NSRect(x: 0, y: 0, width: w, height: h - 34)
            if let im = picture.image, im.size.width > 0 {
                let a = im.size.width / im.size.height, r = w / (h - 34)
                picture.frame = a > r ? NSRect(x: (w - (h - 34) * a) / 2, y: 0, width: (h - 34) * a, height: h - 34)
                                      : NSRect(x: 0, y: (h - 34 - w / a) / 2, width: w, height: w / a)
            }
        } else if !picture.isHidden {
            picture.frame = NSRect(x: (w - 64) / 2, y: 16, width: 64, height: 64)
            text.frame = NSRect(x: 14, y: 86, width: w - 28, height: 34)
        } else if facts.isHidden {
            text.frame = NSRect(x: 14, y: (h - 17) / 2, width: w - 28, height: 17)
        } else {
            text.frame = NSRect(x: 14, y: 12, width: w - 28, height: h - 12 - 32)
        }
    }
}

final class DeckLook: NSView, ShelfLook {
    static let card = NSSize(width: 240, height: 156), step: CGFloat = 9, inset: CGFloat = 12, depth = 2, top: CGFloat = 10
    let badge = Badge()
    let close = CloseButton()
    var onClose: () -> Void = {} { didSet { close.onClick = onClose } }
    private var cards: [Int: DeckCard] = [:]   // by place in the queue; -1: the empty card
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(badge)
        addSubview(close)
        close.contentTintColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func boxSize(_ q: PasteQueue) -> NSSize {
        NSSize(width: DeckLook.card.width + 22, height: DeckLook.top + CGFloat(DeckLook.depth) * DeckLook.step + DeckLook.card.height)
    }

    /// Card k from the front (0) to the back.
    private func cardFrame(_ k: Int) -> NSRect {
        let y = DeckLook.top + CGFloat(DeckLook.depth - k) * DeckLook.step
        return NSRect(x: 10 + CGFloat(k) * DeckLook.inset, y: y, width: DeckLook.card.width - 2 * CGFloat(k) * DeckLook.inset,
                      height: DeckLook.card.height)
    }

    func show(_ q: PasteQueue, store: Store, change: PasteQueue.Change?) {
        let range = q.next..<min(q.ids.count, q.next + DeckLook.depth + 1)
        let wanted: [Int] = range.isEmpty ? [-1] : Array(range)
        for (i, c) in cards where !wanted.contains(i) {
            cards[i] = nil
            if case .pasted = change, i >= 0 {
                // The front card leaves upwards, growing a little and fading: taken off the deck.
                NSAnimationContext.runAnimationGroup({ x in
                    x.duration = 0.22; x.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                    c.animator().frame = c.frame.offsetBy(dx: -40, dy: -60)
                    c.animator().alphaValue = 0
                }, completionHandler: { c.removeFromSuperview() })
            } else { c.removeFromSuperview() }
        }
        for (k, i) in wanted.enumerated().reversed() {
            let c: DeckCard
            if let have = cards[i] { c = have } else {
                c = DeckCard(i >= 0 ? store.entry(q.ids[i]) : nil, store: store)
                c.frame = cardFrame(k)
                if change != nil, i >= 0, k > 0 { c.alphaValue = 0 }
                cards[i] = c
            }
            addSubview(c, positioned: .below, relativeTo: badge)
            NSAnimationContext.runAnimationGroup { x in
                x.duration = change == nil ? 0 : 0.22
                x.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                c.animator().frame = cardFrame(k)
                c.animator().alphaValue = 1
            }
        }
        // Front card on top: the deck was added back to front above.
        let f = cardFrame(0)
        badge.number = q.left > 0 ? q.left : nil
        badge.isHidden = q.left == 0
        badge.frame = NSRect(x: f.maxX - 14, y: f.minY - 10, width: 24, height: 24)
        close.frame = NSRect(x: f.minX - 8, y: f.minY - 8, width: 20, height: 20)
        addSubview(close, positioned: .above, relativeTo: nil)
        addSubview(badge, positioned: .above, relativeTo: nil)
    }
}
