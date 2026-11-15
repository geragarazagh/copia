// The paste queue, his «полочка» (his idea 2026-11-15 ~05:10, decided ~08:50): a key opens it; everything copied while
// it is open joins it in order, and each ⌘V pastes the next item, text and files alike (copy many lines out of a chat
// or many tabs, then paste them one by one). Maccy, Copy and Whisk watch the keyboard for it, which takes Accessibility
// or Input Monitoring; Copia asks for no permission (clipboard.md, «Decided»), so it learns of a paste the way Clipbara
// does (code read 2026-11-14): the next item is on the clipboard as PROMISED data, and the app that pastes it has to ask
// Copia for the bytes. An ask while ⌘ is held (⌘V), or after a key or a click made since the item was put there (Edit >
// Paste, a Paste button), is a paste; reads with nothing behind them (another clipboard tool, a background check) only
// get the data. When the asks of one paste have stopped for a moment, the next item takes its place.
import AppKit
import Carbon.HIToolbox

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
    /// Places in `ids` copied as plain text (Copy as Plain Text in either window): pasted as their plain text alone.
    private(set) var plainAt: Set<Int> = []
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

    /// The asks of one paste: an app reads several types (plain, rich, HTML; file URL, PNG, TIFF) one after another, in
    /// one burst. The next item comes once they have stopped for this long. It must be shorter than the gap between
    /// two quick presses: until the next item is placed, a second ⌘V reads the bytes the pasteboard already holds and
    /// never asks, so it pastes the same item again (his trial 2026-11-15 10:00, 1-2-3-4-5-6 in about a second: the
    /// first 0.3 s, Clipbara's 350 ms, pasted one item many times). A fast hand presses every 90-150 ms; measured in
    /// `cs` (COPIA_TRACE), TextEdit and Notes ask for one type per paste, plain or RTF, so 25 ms covers the burst and
    /// keeps up with presses down to about 40 ms apart.
    static let settle = 0.025
    /// Counted for the tests and the trial: asks served, and how many of them were taken as pastes.
    private(set) var asks = 0, pastes = 0

    private var providers: [QueueItemData] = []
    private var placedAt = 0.0          // ProcessInfo uptime, the clock of CGEventSource's «seconds since»
    private var placedCount = -1
    private var pasting = false
    private var settleTimer: Timer?
    private var renewTimer: Timer?
    private var renewAfter = 0.05
    /// What the keyboard and mouse are doing, as the session tells any app without a permission; the tests set them.
    /// ⌘ held, and which keys are down, are read live. The «seconds since the last key / modifier / click» clocks are
    /// not: measured on his Mac 2026-11-15 (macOS 27.2, no Input Monitoring for anyone), ⌘C and two Space presses showed
    /// as down at once while the key clock still said 240, 8 and 76 s; a modifier came half a second late. So a ⌘V
    /// 0.25 s after the last one read as older than the item placed after that one: no paste, the same item promised
    /// again, and his 1-2-3-4-5 in Notes came out as twenty «1» (his recording 10:47, read at 4-10 fps; slower presses,
    /// 0.6 s apart, went in order). In `cs` keys came by pid and a stub stood in for the clock, so it was never seen
    /// there. The clocks stay for a paste with ⌘ already let go (a slow app, Edit > Paste by mouse).
    var cmdDown: () -> Bool = { CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) }
    var vDown: () -> Bool = { CGEventSource.keyState(.combinedSessionState, key: PasteQueue.vKey) }
    var sinceKey: () -> Double = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) }
    var sinceFlags: () -> Double = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged) }
    var sinceClick: () -> Double = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) }

    /// The key that types «v» with ⌘ in the person's layout (⌘ shortcuts use the ASCII-capable layout: Russian keeps
    /// the US key, Dvorak moves it); traced beside ⌘ to see whether ⌘ alone ever reads as a paste that was not one.
    /// Read at each use: the layout may change while Copia runs (security pass 2026-11-15).
    static var vKey: CGKeyCode {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return 9 }
            for code in 0..<UInt16(128) {
                var dead: UInt32 = 0, len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let r = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if r == noErr, len == 1, chars[0] == 0x76 { return CGKeyCode(code) }
            }
            return 9
        }
    }

    init(store: Store, pasteboard: NSPasteboard = .general) {
        self.store = store
        pb = pasteboard
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        ids = []; pending = []; last = nil; plainAt = []; asks = 0; pastes = 0
        onChange(.opened)
    }

    /// Closed with items still waiting: what is on the clipboard stays there as ordinary data, since the promise
    /// dies with the queue.
    func close() {
        guard isOpen else { return }
        settleTimer?.invalidate(); settleTimer = nil
        renewTimer?.invalidate(); renewTimer = nil
        renewAfter = 0.05
        if pb.changeCount == placedCount, let i = nextIndex ?? last, let e = store.entry(ids[i]) {
            if plainAt.contains(i) { let own = Copia.writePlain(Copia.plainText([e]), concealed: e.concealed, to: pb); monitor?.ownCount = own }
            else { let own = Copia.write([(e, store.reps(ids[i]))], store: store, to: pb).count; monitor?.ownCount = own }
        }
        isOpen = false
        ids = []; pending = []; last = nil; plainAt = []; providers = []; pasting = false
        onChange(.closed)
    }

    /// A copy seen while the queue is open (the monitor's, or picks copied out of either of Copia's windows), in order;
    /// `plain`: copied as plain text, and pasted so.
    func add(_ new: [Int64], plain: Bool = false) {
        guard isOpen, !new.isEmpty else { return }
        let was = ids.count
        ids += new
        let added = Array(was..<ids.count)
        if plain { plainAt.formUnion(added) }
        pending = newestFirst ? added.reversed() + pending : pending + added
        onChange(.added(was))
        // The copy itself is on the clipboard now; the queue's next item goes back on top of it.
        place()
    }

    /// A paste made by Copia itself (Return in the panel, Paste in a menu) put exactly the picks on the clipboard, past
    /// the queue, which never saw it; once it is over the queue's next item goes back on the clipboard.
    func resume() {
        guard isOpen, nextID != nil, pb.changeCount != placedCount else { return }
        place()
    }

    /// Puts the next item on the clipboard as promised data, in one write as any of Copia's copies.
    private func place() {
        renewTimer?.invalidate(); renewTimer = nil
        guard let i = nextIndex, let e = store.entry(ids[i]) else { return }
        var tiffs: [TIFFProvider] = []
        let items: [NSPasteboardItem]
        if plainAt.contains(i) {
            let it = NSPasteboardItem()
            it.setString(Copia.plainText([e]), forType: .string)
            if e.concealed { it.setString("", forType: .concealed) }
            items = [it]
        } else {
            items = Copia.items([(e, store.reps(ids[i]))], store: store, providers: &tiffs)
        }
        var out: [NSPasteboardItem] = []
        var keep: [QueueItemData] = []
        for it in items {
            let d = QueueItemData(queue: self)
            let hasPNG = it.types.contains(.png)
            for t in it.types where t != .own && t != .source && t != .concealed {
                if t == .tiff && hasPNG { d.tiffFromPNG = true; continue }   // made only when asked, as Copia.items does
                if let v = it.data(forType: t) { d.data[t] = v }
            }
            let n = NSPasteboardItem()
            n.setString("1", forType: .own)
            n.setString(Bundle.main.bundleIdentifier ?? "com.geragaraza.copia", forType: .source)
            // nspasteboard.org's transient marker: clipboard tools that follow it skip the item instead of reading it,
            // which would count as a paste while ⌘ is held (security pass 2026-11-15).
            n.setString("", forType: .transient)
            if it.types.contains(.concealed) { n.setString("", forType: .concealed) }
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
        let cmd = cmdDown(), key = sinceKey(), flags = sinceFlags(), click = sinceClick()
        // ⌘ is held (⌘V, ⇧⌘V, ⌥⇧⌘V); or a key or a modifier went down or up after the item was placed (⌘ already let go
        // when a slow app reads), or a click did (Edit > Paste, a Paste button), and not long ago.
        let paste = cmd || (key < since && key < 1.0) || (flags < since && flags < 1.0) || (click < since && click < 1.5)
        if traceEvents {
            FileHandle.standardError.write(Data(String(format: "  since %.3f cmd %d v %d key %.3f flags %.3f click %.3f -> %@\n",
                since, cmd ? 1 : 0, vDown() ? 1 : 0, key, flags, click, paste ? "paste" : (pasting ? "same paste" : "no")).utf8))
        }
        guard paste || pasting else {
            // Served, but no paste: the pasteboard now holds these bytes itself and would not ask at the real ⌘V
            // (measured in the tests: a second read never reaches the provider). So the same item is promised anew
            // once this reader is done; a reader that reads every change (another clipboard tool) gets it later and
            // later, 50 ms doubling to 5 s (Clipbara's backoff), so the two never spin. The first renewal is as quick as
            // the settle: a ⌘V soon after such a read must find the item promised again.
            if renewTimer == nil {
                let t = Timer(timeInterval: renewAfter, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.renewTimer = nil
                    // A copy made since (not yet read by the monitor) stays: it joins the queue at the next poll.
                    if self.pb.changeCount == self.placedCount { self.place() }
                }
                RunLoop.main.add(t, forMode: .common)
                renewTimer = t
                renewAfter = min(5, renewAfter * 2)
            }
            return
        }
        renewAfter = 0.05
        if !pasting { pasting = true; pastes += 1 }
        settleTimer?.invalidate()
        let t = Timer(timeInterval: PasteQueue.settle, repeats: false) { [weak self] _ in self?.advance() }
        RunLoop.main.add(t, forMode: .common)
        settleTimer = t
    }

    /// The next item was dragged out of the deck and dropped into an app: that is a paste too.
    func take() {
        guard isOpen, !pending.isEmpty else { return }
        settleTimer?.invalidate(); settleTimer = nil
        pasting = true
        advance()
    }

    /// The paste is over: the next item takes its place.
    func advance() {
        settleTimer?.invalidate(); settleTimer = nil
        guard pasting, isOpen else { return }
        pasting = false
        guard !pending.isEmpty else { return }
        let i = pending.removeFirst()
        last = i
        if traceEvents { FileHandle.standardError.write(Data(String(format: "advance %.3f %d\n", ProcessInfo.processInfo.systemUptime, i).utf8)) }
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
        if traceEvents {
            FileHandle.standardError.write(Data(String(format: "ask %.3f %@\n", ProcessInfo.processInfo.systemUptime, type.rawValue).utf8))
        }
        if Thread.isMainThread { queue?.asked() } else { DispatchQueue.main.async { self.queue?.asked() } }
    }
}
