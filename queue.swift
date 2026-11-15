// The paste queue, his «полочка» (his idea 2026-11-15 ~05:10, decided ~08:50): a key opens it; everything copied while
// it is open joins it in order, and each ⌘V pastes the next item, text and files alike (copy many lines out of a chat
// or many tabs, then paste them one by one). Maccy, Copy and Whisk watch the keyboard for it, which takes Accessibility
// or Input Monitoring; Copia asks for no permission (clipboard.md, «Decided»), so it learns of a paste the way Clipbara
// does (code read 2026-11-14): the next item is on the clipboard as PROMISED data, and the app that pastes it has to ask
// Copia for the bytes. An ask that follows a key press or a click made after the item was put there is a paste; reads
// with nothing behind them (another clipboard tool, a background check) only get the data. When the asks of one paste
// have stopped for a moment, the next item takes its place.
import AppKit

final class PasteQueue: NSObject {
    let store: Store
    let pb: NSPasteboard
    weak var monitor: Monitor?

    /// The entries in the order they were copied (an entry copied twice is in it twice), and the places in `ids` still
    /// waiting, in the order they will be pasted: the order of copying, or the newest first (his word 2026-11-15: a
    /// choice between 1, 2, 3, 4 and 4, 3, 2, 1; Settings, «Paste Order»).
    private(set) var ids: [Int64] = []
    private(set) var pending: [Int] = []
    private(set) var last: Int?
    private(set) var isOpen = false
    var newestFirst = false
    var left: Int { pending.count }
    var pasted: Int { ids.count - pending.count }
    var nextIndex: Int? { pending.first }
    var nextID: Int64? { nextIndex.map { ids[$0] } }

    enum Change { case opened, added(Int), pasted(Int), closed }
    var onChange: (Change) -> Void = { _ in }
    /// After the last item is pasted (the shelf decides what then).
    var onEmptied: () -> Void = {}

    /// The asks of one paste: an app reads several types (plain, rich, HTML; file URL, PNG, TIFF) one after another.
    /// The next item comes once they have stopped for this long (Clipbara settles for 350 ms; measured here: TextEdit
    /// asks for its last type ~40 ms after the first, Notes ~120 ms).
    static let settle = 0.3
    /// Counted for the tests and the trial: asks served, and how many of them were taken as pastes.
    private(set) var asks = 0, pastes = 0

    private var providers: [QueueItemData] = []
    private var placedAt = 0.0          // ProcessInfo uptime, the clock of CGEventSource's «seconds since»
    private var placedCount = -1
    private var pasting = false
    private var settleTimer: Timer?
    private var renewTimer: Timer?
    private var renewAfter = 0.3
    /// The tests set the times of the last key and click (CGEventSource gives the session's real ones).
    var sinceKey: () -> Double = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) }
    var sinceClick: () -> Double = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) }

    init(store: Store, pasteboard: NSPasteboard = .general) {
        self.store = store
        pb = pasteboard
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        ids = []; pending = []; last = nil; asks = 0; pastes = 0
        onChange(.opened)
    }

    /// Closed with items still waiting: what is on the clipboard stays there as ordinary data, since the promise
    /// dies with the queue.
    func close() {
        guard isOpen else { return }
        settleTimer?.invalidate(); settleTimer = nil
        renewTimer?.invalidate(); renewTimer = nil
        renewAfter = 0.3
        if pb.changeCount == placedCount, let id = nextID ?? last.map({ ids[$0] }), let e = store.entry(id) {
            let r = Copia.write([(e, store.reps(id))], store: store, to: pb)
            monitor?.ownCount = r.count
        }
        isOpen = false
        ids = []; pending = []; last = nil; providers = []; pasting = false
        onChange(.closed)
    }

    /// A copy seen while the queue is open (the monitor's, or picks copied out of Copia's own panel), in order.
    func add(_ new: [Int64]) {
        guard isOpen, !new.isEmpty else { return }
        let was = ids.count
        ids += new
        let added = Array(was..<ids.count)
        pending = newestFirst ? added.reversed() + pending : pending + added
        onChange(.added(was))
        // The copy itself is on the clipboard now; the queue's next item goes back on top of it.
        place()
    }

    /// Puts the next item on the clipboard as promised data, in one write as any of Copia's copies.
    private func place() {
        renewTimer?.invalidate(); renewTimer = nil
        guard let id = nextID, let e = store.entry(id) else { return }
        var tiffs: [TIFFProvider] = []
        let items = Copia.items([(e, store.reps(id))], store: store, providers: &tiffs)
        var out: [NSPasteboardItem] = []
        var keep: [QueueItemData] = []
        for it in items {
            let d = QueueItemData(queue: self)
            let hasPNG = it.types.contains(.png)
            for t in it.types where t != .own && t != .source {
                if t == .tiff && hasPNG { d.tiffFromPNG = true; continue }   // made only when asked, as Copia.items does
                if let v = it.data(forType: t) { d.data[t] = v }
            }
            let n = NSPasteboardItem()
            n.setString("1", forType: .own)
            n.setString(Bundle.main.bundleIdentifier ?? "com.geragaraza.copia", forType: .source)
            n.setDataProvider(d, forTypes: Array(d.data.keys) + (d.tiffFromPNG ? [.tiff] : []))
            out.append(n); keep.append(d)
        }
        // This Mac only: Universal Clipboard would fetch the promise at once and use up the paste.
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.writeObjects(out)
        providers = keep
        placedAt = ProcessInfo.processInfo.systemUptime
        placedCount = pb.changeCount
        monitor?.ownCount = placedCount
    }

    /// An app asked for the next item's bytes.
    func asked() {
        asks += 1
        let since = ProcessInfo.processInfo.systemUptime - placedAt
        let key = sinceKey(), click = sinceClick()
        // A key went down after the item was placed (⌘V; ⌘ may already be up when a slow app reads), or a click did
        // (Edit > Paste, a Paste button), and not long ago.
        let paste = (key < since && key < 1.0) || (click < since && click < 1.5)
        guard paste || pasting else {
            // Served, but no paste: the pasteboard now holds these bytes itself and would not ask at the real ⌘V
            // (measured in the tests: a second read never reaches the provider). So the same item is promised anew
            // once this reader is done; a reader that reads every change (another clipboard tool) gets it later and
            // later, 0.3 s doubling to 5 s (Clipbara's backoff), so the two never spin.
            if renewTimer == nil {
                let t = Timer(timeInterval: renewAfter, repeats: false) { [weak self] _ in self?.renewTimer = nil; self?.place() }
                RunLoop.main.add(t, forMode: .common)
                renewTimer = t
                renewAfter = min(5, renewAfter * 2)
            }
            return
        }
        renewAfter = 0.3
        if !pasting { pasting = true; pastes += 1 }
        settleTimer?.invalidate()
        let t = Timer(timeInterval: PasteQueue.settle, repeats: false) { [weak self] _ in self?.advance() }
        RunLoop.main.add(t, forMode: .common)
        settleTimer = t
    }

    /// The paste is over: the next item takes its place.
    func advance() {
        settleTimer?.invalidate(); settleTimer = nil
        guard pasting, isOpen else { return }
        pasting = false
        guard !pending.isEmpty else { return }
        let i = pending.removeFirst()
        last = i
        onChange(.pasted(i))
        if nextID != nil { place() } else { onEmptied() }
    }
}

/// The bytes of one item of the queue's next entry, given when an app asks.
final class QueueItemData: NSObject, NSPasteboardItemDataProvider {
    weak var queue: PasteQueue?
    var data: [NSPasteboard.PasteboardType: Data] = [:]
    var tiffFromPNG = false
    init(queue: PasteQueue) { self.queue = queue }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let d = data[type] {
            item.setData(d, forType: type)
        } else if type == .tiff, tiffFromPNG, let png = data[.png], let src = CGImageSourceCreateWithData(png as CFData, nil) {
            let out = NSMutableData()
            if let dst = CGImageDestinationCreateWithData(out, "public.tiff" as CFString, 1, nil) {
                CGImageDestinationAddImageFromSource(dst, src, 0, nil)
                if CGImageDestinationFinalize(dst) { item.setData(out as Data, forType: .tiff) }
            }
        }
        if Thread.isMainThread { queue?.asked() } else { DispatchQueue.main.async { self.queue?.asked() } }
    }
}
