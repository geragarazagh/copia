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
