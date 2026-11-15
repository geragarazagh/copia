// The shelf: what the paste queue shows while it is open (queue.swift). His look at three variants (2026-11-15
// ~09:30-09:55, card «His look at the 0.7 shelf variants»): a list, a capsule and a deck of cards were built and shot;
// the capsule and the deck are rejected («без колодки… как оригинальное окошко полноценной истории, без всяких
// усложнений»), and from the list came his own form: the history's own panel, empty, filled by copying (panel.swift,
// queue mode). It never takes the keyboard, so the app copied from and pasted into stays in front. After the last paste
// it closes itself (his word: «сразу закрывается и всё»).
import AppKit

final class Shelf: NSObject {
    let queue: PasteQueue
    let panel: PanelController

    init(queue: PasteQueue, store: Store) {
        self.queue = queue
        panel = PanelController(store: store, monitor: nil, queue: queue)
        super.init()
        panel.view.close.onClick = { [weak self] in self?.close() }
        queue.onChange = { [weak self] c in
            guard let p = self?.panel else { return }
            switch c {
            case .opened: p.show()
            case .closed: p.hide()
            default: p.animateNext = true; p.reload()   // a paste: the row leaves upwards; a copy: it comes in below
            }
        }
        queue.onEmptied = { [weak self] in
            // A moment to see the last row go, then the shelf goes too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self?.queue.left == 0 { self?.close() } }
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
final class CloseButton: NSButton {
    var onClick: () -> Void = {}
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        contentTintColor = .tertiaryLabelColor
        target = self; action = #selector(clicked)
        toolTip = "Close Paste Queue"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { onClick() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}
