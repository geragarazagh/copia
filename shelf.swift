// The shelf: what the paste queue shows while it is open (queue.swift). It floats over the work and never takes the
// keyboard, so the app being copied from and pasted into stays in front. His look at three variants (2026-11-15 ~09:30,
// card «His look at the 0.7 shelf variants»): a list, a capsule (rejected: «бред какой-то») and a deck of cards (the
// bold one, «логично»). From the list came his own idea, built as `panel`: the history's own panel, empty, filled by
// copying (panel.swift, queue mode). The deck stays here (COPIA_SHELF=deck) until he says which of the two stays.
import AppKit

enum ShelfLookKind: String { case panel, deck }
let shelfLook = ShelfLookKind(rawValue: ProcessInfo.processInfo.environment["COPIA_SHELF"] ?? "") ?? .panel

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
    /// The look he chose for А (2026-11-15 ~09:30): the history's own panel, empty, filled by copying.
    let panel: PanelController?

    init(queue: PasteQueue, store: Store, kind: ShelfLookKind = shelfLook) {
        self.queue = queue
        self.store = store
        look = DeckLook()
        window = ShelfPanel(look: look)
        panel = kind == .panel ? PanelController(store: store, monitor: nil, queue: queue) : nil
        super.init()
        look.onClose = { [weak self] in self?.close() }
        panel?.view.close.onClick = { [weak self] in self?.close() }
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
        queue.newestFirst = store.newestFirst
        queue.open()
    }

    func close() { queue.close() }

    private func changed(_ c: PasteQueue.Change) {
        if let p = panel {
            switch c {
            case .opened: p.show()
            case .closed: p.hide()
            default: p.animateNext = true; p.reload()   // a paste: the row leaves upwards; a copy: it comes in below
            }
            return
        }
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

    /// The deck's window, anchored at the bottom right corner.
    func place(animated: Bool) {
        guard let s = screen ?? NSScreen.main else { return }
        let v = s.visibleFrame, b = look.boxSize(queue)
        let w = b.width + 2 * shelfMargin, h = b.height + 2 * shelfMargin
        let o = NSPoint(x: v.maxX - 16 - b.width - shelfMargin, y: v.minY + 16 - shelfMargin)
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
        let range = Array(q.pending.prefix(DeckLook.depth + 1))
        let wanted: [Int] = range.isEmpty ? [-1] : range
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
