// The panel (variant А, his pick 2026-11-14 10:13): a search field over the history, centred on the screen with the
// pointer, on real Liquid Glass (macOS 26+, following the person's Liquid Glass setting) or the system's popover
// material before 26. Motion as Apple's, read frame by frame from Spotlight: it appears in about three frames, leaves
// with blur and fade in about 85 ms, and every state change (search results, selection, deletion) lands in one frame;
// only the box moves. Its height follows what it holds, as Spotlight's: the field alone when nothing is listed, the
// rows up to 720 pt, then the list scrolls; a change of height is the box's bottom edge moving in 200 ms over rows
// already in place (motion.swift). Measurements of the approved mockup (round 3): 760 pt wide, at most 720, corner 22,
// field row 58, rows 60.
import AppKit

/// The width and the tallest the panel gets: Spotlight's own, measured on this Mac (its clipboard list, 2026-11-14:
/// 640 pt wide, 545 pt at most with nine rows, then the list scrolls). 0.4 was 760 × 720, the round-3 mockup's size;
/// his review: too wide, «like Spotlight's width»; his pick of 0.5's variants (~19:05): Spotlight's height, not the
/// screen's.
let panelSize = NSSize(width: 640, height: 546)
let panelCorner: CGFloat = 22
/// Room around the panel inside its window: the glass's own shadow and the 3 % growth of the leaving animation must
/// end inside the window. At 16 pt the window's edge cut the shadow where it was still 6 levels dark under the panel,
/// a faint straight-edged box on a light wallpaper (measured in a test machine, 2026-11-14); the shadow fades out by
/// about 45 pt below the glass.
let panelMargin: CGFloat = 64
/// Spotlight's measures: the field row and the result rows 56 pt (0.4: 58 and 60 with two lines of text per row).
let fieldH: CGFloat = 56, factsH: CGFloat = 36, rowH: CGFloat = 56, listInset: CGFloat = 8
/// The picture of a row: Spotlight's icons are 36 pt in its 56 pt rows.
let rowPicture: CGFloat = 36

final class Flipped: NSView { override var isFlipped: Bool { true } }

/// One undo for the whole app, as Finder's: a deletion made in the panel comes back with ⌘Z in the big window and the
/// other way round (his recording 2026-11-15 10:33: ⌘A ⌘⌫ in the panel, then ⌘, and ⌘Z in the big window brought
/// nothing back; until 0.7 each kept its own).
let appUndo = UndoManager()

func fold(_ s: String) -> ContiguousArray<UInt8> {
    ContiguousArray(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
}

enum Row {
    case head(String)
    case entry(Int)   // index into the shown entries
    case kind(Pane)   // a kind offered while «/…» is typed in the search
}

/// The kinds «/» offers in the search: the big window's sidebar panes that are kinds.
let kindPanes: [Pane] = [.text, .links, .images, .video, .audio, .files, .colors]

// MARK: the controller: data, selection, keys and the window

final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let store: Store
    let monitor: Monitor?
    let view: PanelView
    private(set) var window: Panel?
    private(set) var all: [Entry] = []
    private(set) var shown: [Entry] = []
    private(set) var rows: [Row] = []
    var sel = Selection()
    private var undo: [([Int64], Selection)] = []
    var pending: Int64?
    /// What a drag out of the list carries (drag.swift).
    var draggedIDs: [Int64] = []   // a plain click on a picked row among several: decided on mouse up (Finder)
    private var hiding = false
    /// The Space preview (preview.swift).
    lazy var preview: PreviewController = { let p = PreviewController(store: store); p.panel = self; return p }()
    /// The row the open context menu belongs to (the share sheet comes out of it).
    var menuRow: Int?
    /// Where ⌘C writes: the general pasteboard; a private one in tests.
    var pasteboard = NSPasteboard.general
    /// ⌘, : the big window at Settings (set by the app).
    var openBrowser: ((Pane) -> Void)?
    /// The keys of the list (keys.swift), read from Settings when the panel opens and when they change.
    var keys: Keys
    /// The app in front when the panel opened: where Return pastes (the panel never takes the front itself).
    private(set) var pasteTarget: NSRunningApplication?
    /// Set by the app: ⌘V into that app once the panel is gone (paste.swift); the tests leave it.
    var pasteInto: (NSRunningApplication?) -> Void = { _ in }
    /// Set by the app: the empty space's Clear History….
    var clearHistory: () -> Void = {}
    /// The kind picked with «/», shown as a token before the search; the kinds offered while «/…» is typed, and the one
    /// Return would pick.
    private(set) var kindToken: Pane?
    private(set) var suggestions: [Pane] = []
    private(set) var suggestion = 0
    var suggesting: Bool { !suggestions.isEmpty }
    /// Quick Pick's numbers are on the rows (its modifier held), and the footer names the row's app and time.
    private(set) var showsDigits = false
    private var digitTimer: Timer?
    /// Every modifier has been up since the panel opened: a press of Quick Pick's modifier now is the person's own.
    private(set) var pickArmed = false
    /// Off-screen renders draw the selection as in a focused window.
    var forceFocus = false
    /// Slows every animation by this factor, to step its frames in a test (COPIA_SLOW).
    var slow: Double { Ticker.slow }

    init(store: Store, monitor: Monitor?, onScreen: Bool = true) {
        self.store = store
        self.monitor = monitor
        view = PanelView(frame: NSRect(origin: .zero, size: panelSize), behindWindow: onScreen)
        keys = store.keys
        super.init()
        // Scrolled while the numbers show: they follow the rows in sight.
        view.scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view.scroll.contentView,
                                               queue: .main) { [weak self] _ in if self?.showsDigits == true { self?.refreshDigits() } }
        view.table.dataSource = self
        view.table.delegate = self
        view.table.owner = self
        view.field.delegate = self
        view.owner = self
        if onScreen {
            let w = Panel(view: view)
            w.delegate = self
            w.owner = self
            window = w
        }
        reload()
    }

    var query: String { view.field.stringValue }
    var isVisible: Bool { window?.isVisible == true && !hiding }

    // MARK: data

    /// Reads the history again (after a capture, a delete, an undo) and redraws in one frame.
    func reload() {
        all = store.entries()
        if foldCache.count > all.count { let ids = Set(all.map(\.id)); foldCache = foldCache.filter { ids.contains($0.key) } }
        warmSearch()
        let gone = Set(sel.order).subtracting(all.map(\.id))
        if !gone.isEmpty { sel.remove(gone) }
        filter()
    }

    /// Search: case- and diacritic-insensitive («ё» finds «е»), over what the row shows and the whole text, applied
    /// in the same frame. Foundation's insensitive search compares Unicode at every position: 2 s per key on 5 000
    /// entries of 1.8 KB, and still 55 ms as a literal NSString search on folded text (./test unit). So each entry is
    /// folded once into UTF-8 bytes and searched with memmem (UTF-8 never matches in the middle of a character).
    func filter() {
        // «/» starts a kind filter (his answer 2026-11-15 ~15:35, «круто»): the kinds whose name begins with what follows
        // are offered in place of the rows; with none («/usr/bin»), it is a search like any other.
        if query.hasPrefix("/") {
            let t = query.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
            suggestions = kindPanes.filter { t.isEmpty || $0.title.lowercased().hasPrefix(t) }
        } else { suggestions = [] }
        suggestion = min(suggestion, max(0, suggestions.count - 1))
        view.footerHidden = suggesting
        if suggesting {
            rows = suggestions.map { .kind($0) }
            rowKeys = suggestions.map { "k:" + $0.rawValue }
            view.table.reloadData()
            updateFacts()
            fitHeight(animated: isVisible || testVisible)
            return
        }
        let pool = kindToken.map { k in all.filter { inPane($0, k) } } ?? all
        let q = Array(fold(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        if q.isEmpty { shown = pool } else {
            // Split over the cores: one thread scans 9 MB in about 12 ms, twelve do it in one or two.
            let hay = pool.map(folded)
            let n = hay.count, chunks = max(1, min(n, ProcessInfo.processInfo.activeProcessorCount * 2))
            var hit = [Bool](repeating: false, count: n)
            hit.withUnsafeMutableBufferPointer { out in
                let o = out
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    for i in stride(from: c * n / chunks, to: (c + 1) * n / chunks, by: 1) {
                        o[i] = hay[i].withUnsafeBytes { h in q.withUnsafeBytes { nd in memmem(h.baseAddress, h.count, nd.baseAddress, nd.count) != nil } }
                    }
                }
            }
            shown = pool.indices.filter { hit[$0] }.map { pool[$0] }
        }
        var r: [Row] = []
        var day: Date?
        for (i, e) in shown.enumerated() {
            // Copies are newest first, so a new day starts only where the date falls below the current day's start.
            if let day, e.copied >= day { r.append(.entry(i)); continue }
            let d = Calendar.current.startOfDay(for: e.copied)
            if d != day { r.append(.head(dayText(d))); day = d }
            r.append(.entry(i))
        }
        let before = rowKeys
        rows = r
        rowKeys = r.map { row -> String in
            switch row { case .head(let t): "h:" + t; case .entry(let i): "e:\(shown[i].id)"; case .kind(let p): "k:" + p.rawValue }
        }
        // A deletion or its undo, on screen: the system's own list motion (Mail's: the rows fade while the ones below
        // slide up, or fade back in), the rows' only animation; every other change (a search, a copy arriving) lands
        // in one frame, as Spotlight's. 0.4 removed rows in one frame, so three deleted items vanished silently.
        // Overlapping removeRows animations in AppKit leave an empty gap and stall layout (recording 2026-11-22 10:50),
        // and animating to or from an empty list (where fitHeight already animates the box itself between fieldH and
        // panelSize.height) leaves NSTableView's frame one viewport too tall after ⌘A → ⌘⌫ → ⌘Z (recording 2026-11-23 10:03),
        // so both fall back to reloadData() + tile().
        if animateNext, !animatingRows, isVisible || testVisible, !before.isEmpty, !rowKeys.isEmpty, let change = listChange(before, rowKeys) {
            animateNext = false
            animatingRows = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                view.table.beginUpdates()
                switch change {
                case .removed(let ix): view.table.removeRows(at: ix, withAnimation: [.effectFade, .slideUp])
                case .inserted(let ix): view.table.insertRows(at: ix, withAnimation: [.effectFade, .slideDown])
                }
                view.table.endUpdates()
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.animatingRows = false
                if self.view.table.numberOfRows != self.rows.count { self.view.table.reloadData() }
                self.view.table.tile()
            })
        } else {
            animateNext = false
            animatingRows = false
            view.table.reloadData()
            view.table.tile()
        }
        updateFacts()
        fitHeight(animated: isVisible || testVisible)
    }

    /// The row identities last shown (a day's head by its title, an entry by its id), to tell a pure removal or
    /// insertion from any other change.
    private var rowKeys: [String] = []
    /// The next reload comes from a deletion or its undo.
    var animateNext = false
    /// An animated row removal/insertion is currently running in NSTableView.
    private var animatingRows = false

    enum ListChange: Equatable { case removed(IndexSet), inserted(IndexSet) }

    /// Rows only taken out (or only put back), the rest in the same order: which ones. Anything else: nil.
    func listChange(_ a: [String], _ b: [String]) -> ListChange? {
        func gone(_ long: [String], _ short: [String]) -> IndexSet? {
            guard long.count > short.count else { return nil }
            var ix = IndexSet(), j = 0
            for (i, k) in long.enumerated() {
                if j < short.count && short[j] == k { j += 1 } else { ix.insert(i) }
            }
            return j == short.count ? ix : nil
        }
        if let ix = gone(a, b) { return .removed(ix) }
        if let ix = gone(b, a) { return .inserted(ix) }
        return nil
    }

    // MARK: height and place

    /// Tests: the visible panel's path (filter, then an animated fit) without a window on the screen.
    func fitHeightAfterFilterForTest() { testVisible = true; filter(); testVisible = false }
    private var testVisible = false

    /// The panel's height for what it lists: the field alone with nothing to list (and no note to show), otherwise
    /// field, rows and footer, at most panelSize.height (then the list scrolls) and never taller than the screen.
    func contentHeight() -> CGFloat {
        let note = monitor?.denied == true
        if rows.isEmpty && !note { return fieldH }
        var list: CGFloat = 8   // the scroll view's bottom inset
        for r in rows.indices { list += tableView(view.table, heightOfRow: r) + view.table.intercellSpacing.height }
        if rows.isEmpty { list = 0 }
        var limit = panelSize.height
        if let s = screen { limit = min(limit, PlaceGrid(s).room(row)) }
        // The kinds of «/» stand alone, with no facts line under them (an empty strip there read as a missing word).
        return min(limit, fieldH + 1 + list + (suggesting ? 0 : 1 + factsH))
    }

    /// The height drawn now, and where the top edge is on the screen (screen points; AppKit's y grows upwards).
    private(set) var height: CGFloat = 0
    private(set) var top: CGFloat = 0
    var screen: NSScreen?
    private let sizeTicker = Ticker()

    /// Spotlight's way: the new rows are already in place (one frame), then one edge moves to the new height, 200 ms
    /// with the system's ease. Which edge holds is the place's row (PlaceGrid): the top and middle rows hold the top
    /// edge, where the field is; the bottom row holds the bottom edge, but while a search is typed there its top holds
    /// too, so the field never moves under the typing (it gives way upwards only if the rows need more room than is
    /// left below it), and the bottom edge comes back to its line when the search is cleared.
    func fitHeight(animated: Bool) {
        let h1 = contentHeight()
        var t1 = top
        if let s = screen {
            let g = PlaceGrid(s)
            if row == .bottom { t1 = typing ? max(top, g.bottomEdge + h1) : g.bottomEdge + h1 }
            if t1 - h1 < g.bottomEdge { t1 = g.bottomEdge + h1 }   // never past the lowest line (a panel let go between places)
        }
        guard h1 != height || t1 != top else { return }
        guard animated else { sizeTicker.stop(); setBox(height: h1, top: t1); return }
        let h0 = height, t0 = top, d = 0.2
        sizeTicker.run { [weak self] t in
            let p = Curve.ease(min(1, t / d))
            self?.setBox(height: mix(h0, h1, p).rounded(), top: mix(t0, t1, p).rounded())
            return t < d
        }
    }

    /// Puts the box at this height and top: the view, and the window around it with its margin.
    func setBox(height h: CGFloat, top t: CGFloat) {
        height = h; top = t
        view.setFrameSize(NSSize(width: panelSize.width, height: h))
        view.table.tile()
        guard let w = window, screen != nil else { return }
        let x = left
        w.setFrame(NSRect(x: x - panelMargin, y: t - h - panelMargin, width: panelSize.width + 2 * panelMargin,
                          height: h + 2 * panelMargin), display: true)
    }

    /// The panel's left edge (screen points): its place's column, or wherever a drag has it.
    var left: CGFloat = 0
    /// The row of the place it rests at (which edge holds when the height changes: fitHeight).
    var row = Place.standard.row
    /// A search is being typed: a query, a kind token or the kinds of «/».
    var typing: Bool { !query.isEmpty || kindToken != nil || suggesting }

    /// At the place chosen for this screen, by the place's own edges: the same at every opening whatever the list
    /// holds, nothing centred by height (0.1 centred the middle row anew at each opening: the jump he saw).
    func placeAtRest() {
        let p = screen.map(placeFor) ?? .standard
        row = p.row
        let h = contentHeight()
        guard let s = screen else { setBox(height: h, top: top); return }
        let g = PlaceGrid(s)
        left = g.left(p.column)
        setBox(height: h, top: g.top(p.row, height: h))
    }

    /// The place chosen for this screen (drag and snap, place.swift); top centre until the person moves it.
    func placeFor(_ s: NSScreen) -> Place { store.setting(placeKey + screenKey(s)).flatMap(Place.init) ?? .standard }
    var placeKey: String { "place." }

    /// The soft-magnet drag by the edge (place.swift).
    lazy var snap = SnapDrag(get: { [unowned self] in NSPoint(x: self.left, y: self.top) },
                             set: { [unowned self] p in self.left = p.x; self.setBox(height: self.height, top: p.y) })
    var settleTicker: Ticker { snap.ticker }

    func entry(_ id: Int64) -> Entry? { all.first { $0.id == id } }
    /// The entries of `ids` in that order, found by one pass (entry(_:) per id is quadratic under ⌘A).
    func entries(_ ids: [Int64]) -> [Entry] {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    /// Folded text by entry, with the digest it was folded from: a copy that replaces an entry's content (Store.add)
    /// or an edit keeps the id, and the old fold would go on matching the old text. Entries gone are let go at reload
    /// (the cache only grew before: memory growth in the stress runs of 2026-11-27).
    private var foldCache: [Int64: (digest: String, f: ContiguousArray<UInt8>)] = [:]
    private func folded(_ e: Entry) -> ContiguousArray<UInt8> {
        if let c = foldCache[e.id], c.digest == e.digest { return c.f }
        let f = fold(e.searchable(e.title))
        foldCache[e.id] = (e.digest, f)
        return f
    }

    /// Folds every entry not folded yet, off the main thread, so the first key typed after launch is as fast as the rest.
    func warmSearch(wait: Bool = false) {
        let todo = all.filter { foldCache[$0.id]?.digest != $0.digest }.map { ($0.id, $0.digest, $0.searchable($0.title)) }
        guard !todo.isEmpty else { return }
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global(qos: .utility).async {
            let done = todo.map { ($0.0, $0.1, fold($0.2)) }
            DispatchQueue.main.async { for (id, d, f) in done where self.foldCache[id]?.digest != d { self.foldCache[id] = (d, f) }; g.leave() }
        }
        if wait { while g.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
    }

    func updateFacts() {
        // Holding Quick Pick's modifier leaves the footer alone: the source line it once showed («Finder · Today, 2:40
        // PM») was taken out at his word 2026-11-21 («чтобы ничего не появлялось»); only the ⌘1… numbers show.
        if suggesting {
            view.setFacts(nil, note: "")
        } else if let m = monitor, m.denied {
            view.setFacts(nil, note: L("Reading the clipboard is off: Privacy & Security > Paste from Other Apps"))
        } else if !sel.isEmpty {
            let picked = entries(sel.order)
            let f = Facts(picked)
            view.setFacts(f, note: nil)
            if !f.complete { TextStats.shared.prepare(picked) { [weak self] in self?.updateFacts() } }
        } else {
            view.setFacts(nil, note: shown.isEmpty ? "" : counted(shown.count, "object|objects"))
        }
    }

    /// The selection changed: only the rows' colours, badges and the facts line change, in the same frame.
    func selectionChanged(scrollTo id: Int64? = nil) {
        noteShown = nil
        defer { if preview.isOpen, let c = sel.cursor ?? sel.order.last, c != preview.entry?.id, let e = entry(c) { openPreview(e) } }
        for r in 0..<rows.count {
            if let c = view.table.view(atColumn: 0, row: r, makeIfNecessary: false) as? EntryCell, case .entry(let i) = rows[r] {
                let (on, n) = rowLook(i)
                c.update(selected: on, badge: n, focused: focused)
            }
        }
        if let id, let r = rows.firstIndex(where: { if case .entry(let i) = $0 { return shown[i].id == id }; return false }) {
            let vis = view.scroll.contentView.documentVisibleRect
            if !vis.contains(view.table.rect(ofRow: r)) { view.table.scrollRowToVisible(r) }
        }
        updateFacts()
    }

    /// The rows' selection is drawn in the accent colour only while the list has the keys; with the caret in the
    /// search it turns grey, as any Mac list does when another control has the focus: one look tells where the keys go.
    var focused: Bool { forceFocus || (window?.isKeyWindow == true && !searching) }

    /// Whether row i is drawn picked, and its number in the order of picking.
    func rowLook(_ i: Int) -> (Bool, Int?) {
        return (sel.contains(shown[i].id), sel.badge(shown[i].id))
    }

    // MARK: actions

    /// ⌘C or a double click: the whole selection in one write, then the panel goes; the person pastes.
    func copySelection() {
        let picked = sel.order.compactMap(entry)
        guard !picked.isEmpty else { return }
        let r = Copia.write(picked.map { ($0, store.reps($0.id)) }, store: store, to: pasteboard)
        monitor?.ownCount = r.count
        used(picked.map(\.id))
        copied(picked.map(\.id), false)
        hide()
    }

    /// Return (his answer 2026-11-15 ~15:35, as Spotlight's clipboard): the picks, or with nothing picked the first row
    /// (Spotlight's top hit), on the clipboard in the one write, the panel goes, then ⌘V into the app that was in front
    /// (paste.swift). Plain: their plain text alone. A paste puts exactly the picks in, so it goes past an open paste
    /// queue, whose next item comes back on the clipboard after it (PasteQueue.resume).
    func pasteSelection(plain: Bool) {
        guard !hiding else { return }   // a second Return while the panel leaves pastes nothing twice (security pass 2026-11-15)
        if sel.isEmpty, let first = shown.first { sel.click(first.id); selectionChanged() }
        let picked = sel.order.compactMap(entry)
        guard !picked.isEmpty else { return }
        if plain {
            let t = Copia.plainText(picked)
            guard !t.isEmpty else { return }
            let own = Copia.writePlain(t, concealed: picked.contains(where: \.concealed), to: pasteboard); monitor?.ownCount = own
        } else {
            let own = Copia.write(picked.map { ($0, store.reps($0.id)) }, store: store, to: pasteboard).count; monitor?.ownCount = own
        }
        used(picked.map(\.id))
        let target = pasteTarget
        hide { [weak self] in self?.pasteInto(target) }
    }

    /// Quick Pick: the Nth row in sight (the numbers shown while its modifier is held), pasted as Return pastes.
    func quickPick(_ n: Int, plain: Bool) {
        guard !hiding else { return }
        let ids = visibleEntryIDs()
        guard n < ids.count else { return }
        sel.clear(); sel.click(ids[n]); selectionChanged()
        pasteSelection(plain: plain)
    }

    /// The first nine rows in sight, at least half shown, top down.
    func visibleEntryIDs() -> [Int64] {
        let vis = view.scroll.contentView.documentVisibleRect
        let range = view.table.rows(in: vis)
        var out: [Int64] = []
        for r in range.location..<(range.location + range.length) where r < rows.count {
            guard case .entry(let i) = rows[r] else { continue }
            if view.table.rect(ofRow: r).intersection(vis).height >= rowH / 2 { out.append(shown[i].id) }
            if out.count == 9 { break }
        }
        return out
    }

    /// The modifier keys changed: Quick Pick's alone shows the numbers, anything else hides them. Pressed fresh (every
    /// modifier was up at some moment since the panel opened) they show at once
    /// (his recording 2026-11-19: about a second late felt broken). Still held from the hot key (⌥⌘C, ⌥ let go first)
    /// they wait 0.2 s, so letting go of the hot key does not flash them.
    func flagsChanged(_ f: NSEvent.ModifierFlags) {
        digitTimer?.invalidate(); digitTimer = nil
        let m = f.intersection([.command, .option, .control, .shift])
        if m.isEmpty { pickArmed = true }
        guard m == keys.pick.flags else { setDigits(false); return }
        guard !showsDigits else { return }
        if pickArmed { setDigits(true); return }
        let t = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in self?.setDigits(true) }
        RunLoop.main.add(t, forMode: .common)
        digitTimer = t
    }

    func setDigits(_ on: Bool) {
        if !on { digitTimer?.invalidate(); digitTimer = nil }
        guard on != showsDigits else { return }
        showsDigits = on
        refreshDigits()
        updateFacts()
    }

    /// The numbers on the rows in sight, or none.
    func refreshDigits() {
        let ids = showsDigits ? visibleEntryIDs() : []
        for r in 0..<rows.count {
            guard let c = view.table.view(atColumn: 0, row: r, makeIfNecessary: false) as? EntryCell, case .entry(let i) = rows[r] else { continue }
            c.shortcut = ids.firstIndex(of: shown[i].id).map { keys.pick.symbol + String($0 + 1) }
            let (on, n) = rowLook(i)
            c.update(selected: on, badge: n, focused: focused)
        }
    }

    /// Copied back from here: the entries move to the top (Store.touch). The panel shows the new order the next time
    /// it opens (it is leaving now: rows moving under its fade would be frames nobody can explain); the big window, if
    /// open, at once.
    func used(_ ids: [Int64]) {
        store.touch(ids)
        afterChange()
    }

    /// Set by the app: picks copied out of the panel join the paste queue when it is open, as any copy does (true: as
    /// plain text).
    var copied: ([Int64], Bool) -> Void = { _, _ in }

    /// Set by the app: the big window reads the store again after a change made here.
    var afterChange: () -> Void = {}

    /// ⌘⌫: no question; into Recently Deleted; the row that takes the first deleted row's place becomes the selection.
    func deleteSelection() {
        let ids = sel.order
        guard !ids.isEmpty else { return }
        let list = shown.map(\.id)
        let first = list.firstIndex { ids.contains($0) } ?? 0
        undo.append((ids, sel))
        appUndo.registerUndo(withTarget: self) { _ = $0.undoDelete() }
        appUndo.setActionName(L("Delete"))
        store.delete(ids)
        animateNext = true
        reload()
        let left = shown.map(\.id)
        sel.clear()
        if !left.isEmpty { sel.click(left[min(first, left.count - 1)]) }
        selectionChanged(scrollTo: sel.order.first)
        // Where they went, said once in the facts line (Recently Deleted keeps them 30 days; ⌘Z brings them back),
        // until the selection changes or a few seconds pass.
        note(String(format: L("Moved to Recently Deleted: %@"), counted(ids.count, "object|objects")) + "  ·  ⌘Z")
        afterChange()
    }

    /// A short note in the facts line in place of the facts.
    func note(_ text: String) {
        noteShown = text
        view.setFacts(nil, note: text)
        let mine = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.noteShown == mine else { return }
            self.noteShown = nil
            self.updateFacts()
        }
    }
    private(set) var noteShown: String?

    /// ⌘Z: the last deletion comes back in place, picked as it was.
    func undoDelete() -> Bool {
        guard let (ids, before) = undo.popLast() else { return false }
        store.undelete(ids)
        sel = before
        animateNext = true
        reload()
        selectionChanged(scrollTo: before.order.first)
        afterChange()
        return true
    }

    func selectAll() {
        sel.all(shown.map(\.id))
        selectionChanged()
    }

    func move(_ step: Int, extending: Bool) {
        sel.move(step, in: shown.map(\.id), extending: extending)
        selectionChanged(scrollTo: sel.cursor)
    }

    // MARK: mouse (from ListTable)

    func mouseDown(row: Int, flags: NSEvent.ModifierFlags, clicks: Int) {
        if row >= 0, row < rows.count, case .kind(let p) = rows[row] { pickKind(p); return }
        guard row >= 0, row < rows.count, case .entry(let i) = rows[row] else { return }
        // A click in the list gives it the keys, the query staying (Finder's way): 0.6 picked the row in grey and left
        // the caret blinking in the search, with no way back to the list but ↓ (his recording 2026-11-15 09:27).
        if searching { window?.makeFirstResponder(view) }
        let id = shown[i].id
        if clicks >= 2 {
            pending = nil
            if !sel.contains(id) { sel.click(id) }
            selectionChanged()
            copySelection()
            return
        }
        if flags.contains(.command) { sel.toggle(id) }
        else if flags.contains(.shift) { sel.extend(to: id, in: shown.map(\.id)) }
        else if sel.contains(id) && sel.count > 1 { pending = id; return }   // may be the first click of a double click
        else { sel.click(id) }
        selectionChanged()
    }

    func mouseUp() {
        if let id = pending { pending = nil; sel.click(id); selectionChanged() }
    }

    // MARK: keys

    /// The settable keys (keys.swift) and the «/» kinds, before the field or the list sees the key. While the caret is in
    /// the search, a key that edits text stays the field's (⌫, ⌘C, letters); Return, ⌘Return, ⌘Y and Quick Pick work
    /// there too, as in Spotlight.
    func bindingKey(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown else { return false }
        if let k = NSApp.keyWindow, k !== window { return false }
        if suggesting {
            guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            switch Int(e.keyCode) {
            case 125: moveSuggestion(1)
            case 126: moveSuggestion(-1)
            case 36, 76, 48: pickKind(suggestions[suggestion])   // Return, Enter, Tab
            default: return false
            }
            return true
        }
        guard let a = keys.action(e) else { return false }
        if case .pick = a {} else if searching && isTextEditingKey(e) { return false }
        switch a {
        case .paste: pasteSelection(plain: false)
        case .pastePlain: pasteSelection(plain: true)
        case .copy: copySelection()
        case .delete: deleteSelection()
        case .preview:
            guard preview.isOpen || !sel.isEmpty else { return false }
            togglePreview()
        case .pick(let n, let plain): quickPick(n, plain: plain)
        }
        return true
    }

    // MARK: the kind filter

    /// Picks a kind: it shows as a token before the search, the «/…» typed goes, the caret stays for a query.
    func pickKind(_ p: Pane) {
        kindToken = p
        suggestions = []; suggestion = 0
        view.field.stringValue = ""
        view.setToken(p)
        if !searching { window?.makeFirstResponder(view.field) }
        filter()
        selectionChanged()
    }

    /// ⌫ on an empty search: the token goes.
    func dropKind() {
        kindToken = nil
        view.setToken(nil)
        filter()
        selectionChanged()
    }

    func moveSuggestion(_ d: Int) {
        guard suggesting else { return }
        suggestion = (suggestion + d + suggestions.count) % suggestions.count
        for r in 0..<rows.count { (view.table.view(atColumn: 0, row: r, makeIfNecessary: false) as? KindCell)?.highlighted = r == suggestion }
    }

    /// ⌘ keys of the panel. The search field keeps the typing focus while the panel is open, so ⌫ alone edits the
    /// search and ⌘⌫ deletes the selection (Finder's Move to Trash); with nothing picked the keys act on the field.
    /// ⌘ keys of the panel, by where the keys are (his second review of 0.4, 2026-11-14 17:59: in the search field
    /// ⌘A did nothing; «separate the search field from the list properly»):
    /// - the search field (a caret in it): every key of a macOS text field, ⌘A selects the query, ⌘X ⌘C ⌘V, ⌘Z, ⌥⌫ and
    ///   ⌘⌫ edit it; the list is not touched;
    /// - the list (no caret): ⌘A picks every row, ⌘Z brings deleted ones back, ⌘V starts a search with the pasted text,
    ///   ⌘R shows files in Finder, ⌥⇧⌘C copies plain text; Copy, Delete and the rest are the settable keys (bindingKey).
    /// ⌘F goes to the field from anywhere; ↓, ↑ or Tab from the field give the keys to the list.
    /// A query holds at most this many characters: a pasted 118 000 were laid out in the one-line field for 110 s
    /// (stress run 2026-11-27), and nobody searches by more than a paragraph.
    let queryLimit = 1_000

    func keyEquivalent(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard mods.contains(.command) else { return false }
        // AppKit offers a key equivalent to every window of the app, the key one first: while the preview's text has
        // the keys, ⌘A and ⌘C belong to that text, never to the list behind it (a test machine run, 2026-11-14: ⌘A ⌘C
        // in the preview copied the whole history and hid the panel).
        if let k = NSApp.keyWindow, k !== window { return false }
        let key = shortcutKey(e)
        switch (key, mods) {
        case ("f", [.command]): focusSearch(); return true
        case (",", [.command]): openBrowser?(.settings); return true
        default: break
        }
        if searching, let ed = window?.fieldEditor(false, for: view.field) as? NSTextView {
            // The panel has no Edit menu to carry these (a panel of an app with no menu bar), so they go to the field
            // editor here, as the Edit menu would send them.
            switch (key, mods) {
            case ("a", [.command]): ed.selectAll(nil)
            case ("c", [.command]): ed.copy(nil)
            case ("x", [.command]): ed.cut(nil)
            case ("v", [.command]): pasteText(into: ed, limit: queryLimit)
            case ("z", [.command]): ed.undoManager?.undo()
            case ("z", [.command, .shift]): ed.undoManager?.redo()
            case (_, [.command]) where e.keyCode == 51: ed.deleteToBeginningOfLine(nil)   // ⌘⌫, as in every text field
            default: return false
            }
            return true
        }
        switch (key, mods) {
        case ("a", [.command]): selectAll()
        case ("z", [.command]): if appUndo.canUndo { appUndo.undo() }
        case ("v", [.command]): focusSearch(); if let ed = window?.fieldEditor(false, for: view.field) as? NSTextView { pasteText(into: ed, limit: queryLimit) }
        case ("r", [.command]): menuShowInFinder()   // Spotlight's and Finder's Show in Finder
        case ("c", [.command, .option, .shift]): menuCopyPlain()   // the big window's Edit menu has the same
        default: return false   // ⌘C, ⌘⌫ and the rest are the settable keys (bindingKey)
        }
        return true
    }

    /// The search field's keys that are not text editing: ↓ ↑ and Tab hand the keys to the list (picking a row as
    /// they go), Return copies, Esc steps back.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy s: Selector) -> Bool {
        switch s {
        case #selector(NSResponder.moveUp(_:)): toList(); move(-1, extending: false)
        case #selector(NSResponder.moveDown(_:)): toList(); move(1, extending: false)
        case #selector(NSResponder.moveUpAndModifySelection(_:)), #selector(NSResponder.moveParagraphBackwardAndModifySelection(_:)):
            toList(); move(-1, extending: true)
        case #selector(NSResponder.moveDownAndModifySelection(_:)), #selector(NSResponder.moveParagraphForwardAndModifySelection(_:)):
            toList(); move(1, extending: true)
        case #selector(NSResponder.insertTab(_:)): toList(); if sel.isEmpty { move(1, extending: false) }
        case #selector(NSResponder.cancelOperation(_:)): escape()
        case #selector(NSResponder.insertNewline(_:)): if suggesting { pickKind(suggestions[suggestion]) }   // else Return is a setting's
        case #selector(NSResponder.deleteBackward(_:)) where query.isEmpty && kindToken != nil: dropKind()
        default: return false
        }
        return true
    }

    /// The keys to the list: the caret leaves the field, the query stays.
    func toList() {
        window?.makeFirstResponder(view)
        selectionChanged()
    }

    func controlTextDidChange(_ n: Notification) {
        filter()
    }

    // MARK: showing and hiding

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let w = window else { return }
        hiding = false
        view.field.stringValue = ""
        sel.clear(); pending = nil
        kindToken = nil; view.setToken(nil); suggestions = []
        keys = store.keys
        setDigits(false)
        pickArmed = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        // Where Return pastes: the app in front now. The panel never activates Copia, so it stays the front app.
        let front = NSWorkspace.shared.frontmostApplication
        pasteTarget = front?.processIdentifier == getpid() ? nil : front
        reload()
        view.table.scrollRowToVisible(0)
        // On the screen with the pointer, at the place the person chose for that screen (top centre until moved).
        let mouse = NSEvent.mouseLocation
        screen = trialScreen() ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        sizeTicker.stop(); settleTicker.stop()
        placeAtRest()
        view.resetMotion()
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        // Opening is for choosing (his review of 0.4): no caret and nothing typed into the search at once. The list has
        // the keys (arrows, Return, Space, ⌘C, ⌘⌫); ⌘F, or a click into the field, starts a search, as in Finder.
        w.makeFirstResponder(view)
        // Appears in about three frames (Spotlight: 0 → 40 % → 100 % at 60 fps).
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 2.0 / 60 * slow
            c.timingFunction = CAMediaTimingFunction(name: .linear)
            w.animator().alphaValue = 1
        }
        selectionChanged()
    }

    func hide(then done: (() -> Void)? = nil) {
        setDigits(false)
        guard let w = window, w.isVisible, !hiding else { done?(); return }
        hiding = true
        let d = 0.085 * slow
        // Leaves with blur and fade and a slight growth, about 85 ms, as Spotlight does; an open preview fades with it.
        view.animateOut(duration: d)
        let pw = preview.isOpen ? preview.window : nil
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = d
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
            pw?.animator().alphaValue = 0
        }, completionHandler: {
            self.preview.dismiss()
            guard self.hiding else { return }   // ⌥⌘C again while it was leaving: it stays (and pastes nothing)
            w.orderOut(nil)
            w.alphaValue = 1
            self.view.resetMotion()
            self.hiding = false
            done?()
        })
    }

    // A click outside: another window took the keyboard.
    func windowDidResignKey(_ n: Notification) {
        // The preview's text took the keys (editing): stay. Anything else: hide, as a click outside.
        DispatchQueue.main.async {
            guard NSApp.keyWindow !== self.preview.window || self.preview.window == nil else { self.redrawSelection(); return }
            self.redrawSelection()
            if NSApp.keyWindow !== self.window { self.setDigits(false); self.hide() }
        }
    }

    /// The rows' colours follow whether the panel has the keys.
    private func redrawSelection() {
        let open = preview.isOpen
        if !open { selectionChanged() } else {
            for r in 0..<rows.count {
                if let c = view.table.view(atColumn: 0, row: r, makeIfNecessary: false) as? EntryCell, case .entry(let i) = rows[r] {
                    c.update(selected: sel.contains(shown[i].id), badge: sel.badge(shown[i].id), focused: focused)
                }
            }
        }
    }

    // MARK: preview

    /// Space is the preview's while the list has the keys; in the search field it is a space.
    var spaceOpensPreview: Bool { !searching && (preview.isOpen || !sel.isEmpty) }

    func togglePreview() {
        if preview.isOpen { closePreview(); return }
        guard let c = sel.cursor ?? sel.order.last, let e = entry(c) else { return }
        openPreview(e)
    }

    func openPreview(_ e: Entry) {
        let from = rowPictureRect(e.id) ?? NSRect(x: panelScreenRect.midX - 20, y: panelScreenRect.midY - 20, width: 40, height: 40)
        let vis = screen?.visibleFrame ?? panelScreenRect.insetBy(dx: -400, dy: -400)
        preview.open(e, from: from, panelRect: panelScreenRect, screen: vis)
    }

    func closePreview() {
        guard let id = preview.entry?.id else { return }
        preview.close(to: rowPictureRect(id))
        window?.makeKey()
        window?.makeFirstResponder(searching || !query.isEmpty ? view.field : view)
    }

    /// The search field has the keys (a caret in it).
    var searching: Bool {
        guard let w = window, let ed = w.fieldEditor(false, for: view.field) else { return false }
        return w.firstResponder === ed && ed.delegate === view.field
    }

    /// ⌘F: into the search field, its text selected (Finder's ⌘F).
    func focusSearch() {
        window?.makeFirstResponder(view.field)
        (window?.fieldEditor(false, for: view.field) as? NSTextView)?.selectAll(nil)
        selectionChanged()
    }

    /// Esc, step by step back, as Spotlight's (his recording 2026-11-15 09:27: Spotlight's first Esc returns to its empty
    /// state, the second closes it; 0.6 closed at once with rows picked): the preview closes; then the search and the
    /// picks are cleared together and the list has the keys, as on opening; then the panel goes.
    func escape() {
        if preview.isOpen { closePreview(); return }
        if !query.isEmpty || searching || !sel.isEmpty || kindToken != nil {
            let had = !query.isEmpty || kindToken != nil
            view.field.stringValue = ""
            kindToken = nil; view.setToken(nil)
            sel.clear(); pending = nil
            window?.makeFirstResponder(view)
            if had { filter() }
            selectionChanged()
            return
        }
        hide()
    }

    /// Keys while the list has them (no caret): the arrows move, ⇧ stretches, Esc steps back; Return, ⌫ and the rest
    /// are the settable keys (bindingKey). Letters do nothing until ⌘F or Tab: opening is for choosing (his word
    /// 2026-11-15 ~15:35: typing must not start a search).
    func listKey(_ e: NSEvent) -> Bool {
        let shift = e.modifierFlags.contains(.shift)
        switch Int(e.keyCode) {
        case 125: move(1, extending: shift)
        case 126: move(-1, extending: shift)
        case 53: escape()
        case 48: focusSearch()   // Tab: back to the search field
        default: return false
        }
        return true
    }

    /// The panel's rectangle in screen points (or in its window, for the off-screen renders).
    var panelScreenRect: NSRect {
        let r = view.convert(view.bounds, to: nil)
        return view.window?.convertToScreen(r) ?? r
    }

    /// The row's picture in screen points, when the row is in sight.
    func rowPictureRect(_ id: Int64) -> NSRect? {
        guard let r = rows.firstIndex(where: { if case .entry(let i) = $0 { return shown[i].id == id }; return false }) else { return nil }
        let row = view.table.rect(ofRow: r)   // from the table's geometry: the cell may not exist yet
        let pic = NSRect(x: row.minX + listInset + 10, y: row.minY + (rowH - rowPicture) / 2, width: rowPicture, height: rowPicture)
        let inList = view.table.convert(pic, to: view.scroll)
        guard view.scroll.bounds.contains(NSPoint(x: inList.midX, y: inList.midY)) else { return nil }
        let r2 = view.table.convert(pic, to: nil)
        return view.window?.convertToScreen(r2) ?? r2
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] { case .head: 29; case .kind: kindRowH; case .entry: rowH }
    }

    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool { false }
    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PlainRow() }

    func tableView(_ t: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .head(let s):
            let c = t.makeView(withIdentifier: HeadCell.id, owner: nil) as? HeadCell ?? HeadCell()
            c.label.stringValue = s
            return c
        case .entry(let i):
            let c = t.makeView(withIdentifier: EntryCell.id, owner: nil) as? EntryCell ?? EntryCell()
            let e = shown[i]
            c.show(e, store: store)
            c.shortcut = showsDigits ? visibleEntryIDs().firstIndex(of: e.id).map { keys.pick.symbol + String($0 + 1) } : nil
            let (on, n) = rowLook(i)
            c.update(selected: on, badge: n, focused: focused)
            return c
        case .kind(let p):
            let c = t.makeView(withIdentifier: KindCell.id, owner: nil) as? KindCell ?? KindCell()
            c.show(p)
            c.highlighted = row == suggestion
            return c
        }
    }
}

// MARK: the window

final class Panel: NSPanel {
    weak var owner: PanelController?

    init(view: PanelView) {
        let size = NSSize(width: panelSize.width + 2 * panelMargin, height: panelSize.height + 2 * panelMargin)
        // A non-activating panel takes the keyboard without making the app active, so the app in front stays in front
        // and ⌘V after the copy goes where the person was (Spotlight's and Alfred's way).
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // No window shadow: Liquid Glass draws its own, and the window server's shadow of that soft shape drew a
        // dark hairline ring ~8 pt outside the glass (on-screen trial of v0.1, 2026-11-14).
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none   // the motion is our own, timed as Apple's
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let root = Margin(frame: NSRect(origin: .zero, size: size))
        root.owner = { [weak self] in self?.owner }
        view.frame.origin = NSPoint(x: panelMargin, y: panelMargin)
        root.addSubview(view)
        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The frame exactly as computed: AppKit otherwise pulls a window under the menu bar, and with the shadow's room
    /// above it the panel's top place came out 56 pt lower than Spotlight's (measured in the agents' session, 0.5).
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        owner?.bindingKey(e) == true || owner?.keyEquivalent(e) == true || super.performKeyEquivalent(with: e)
    }

    override func cancelOperation(_ sender: Any?) { owner?.escape() }

    /// Space: the preview, when something is picked and the person is not typing a search (then it is a space).
    override func sendEvent(_ e: NSEvent) {
        if traceEvents, [.keyDown, .leftMouseDown].contains(e.type) {
            FileHandle.standardError.write(Data("panel \(e.type.rawValue) key=\(isKeyWindow) code=\(e.type == .keyDown ? Int(e.keyCode) : -1)\n".utf8))
        }
        if e.type == .flagsChanged { owner?.flagsChanged(e.modifierFlags) }
        if e.type == .keyDown, owner?.bindingKey(e) == true { return }
        if e.type == .keyDown, e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let o = owner, o.spaceOpensPreview {
            o.togglePreview()
            return
        }
        super.sendEvent(e)
    }
}

/// The window's room around the glass, where its shadow lies: a click there is a click outside the panel.
final class Margin: NSView {
    var owner: () -> PanelController? = { nil }
    override var isFlipped: Bool { true }
    override func mouseDown(with e: NSEvent) { owner()?.hide() }
}

// MARK: the view

final class PanelView: NSView {
    let field = NSTextField()
    let token = KindToken()
    let table = ListTable()
    let scroll = NSScrollView()
    private(set) var facts = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let content = Flipped()
    private let footer = Flipped()
    private let topLine = Separator(), bottomLine = Separator()
    private var background: NSView!

    override var isFlipped: Bool { true }

    /// `behindWindow`: the glass or material shows what is behind the window (the real panel); false for renders,
    /// where a picture of a desktop sits in the same window.
    init(frame: NSRect, behindWindow: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        content.frame = bounds
        if #available(macOS 26.0, *) {
            // Real Liquid Glass, as Apple's own apps draw it; the system applies the person's Liquid Glass choice
            // (Clear or Tinted, Reduce Transparency) by itself.
            let g = NSGlassEffectView(frame: bounds)
            g.cornerRadius = panelCorner
            g.style = .regular
            g.contentView = content
            background = g
        } else {
            // Before macOS 26 the closest system material: the popover's, which follows light and dark.
            let v = NSVisualEffectView(frame: bounds)
            v.material = .popover
            v.blendingMode = behindWindow ? .behindWindow : .withinWindow
            v.state = .active
            v.maskImage = NSImage(size: bounds.size, flipped: false) { r in
                NSBezierPath(roundedRect: r, xRadius: panelCorner, yRadius: panelCorner).fill(); return true
            }
            v.maskImage?.capInsets = NSEdgeInsets(top: panelCorner, left: panelCorner, bottom: panelCorner, right: panelCorner)
            v.wantsLayer = true
            v.layer?.cornerRadius = panelCorner
            v.layer?.cornerCurve = .continuous
            v.layer?.borderWidth = 0.5
            v.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            v.addSubview(content)
            background = v
        }
        addSubview(background)

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 18, y: (fieldH - 24) / 2, width: 24, height: 24)
        content.addSubview(icon)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: L("Search"), attributes: [
            .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.tertiaryLabelColor])
        let fh = field.intrinsicContentSize.height
        field.frame = NSRect(x: 50, y: (fieldH - fh) / 2, width: panelSize.width - 50 - 20, height: fh)
        content.addSubview(field)
        token.isHidden = true
        content.addSubview(token)

        content.addSubview(topLine)

        scroll.frame = NSRect(x: 0, y: fieldH + 1, width: panelSize.width, height: panelSize.height - fieldH - 2 - factsH)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        let col = NSTableColumn(identifier: .init("c"))
        col.width = panelSize.width
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.refusesFirstResponder = true   // the search field keeps the keyboard, as in Spotlight
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.gridStyleMask = []
        scroll.documentView = table
        table.autoresizingMask = [.width]
        content.addSubview(scroll)

        facts.alignment = .center
        facts.lineBreakMode = .byTruncatingTail
        footer.addSubview(bottomLine)
        footer.addSubview(facts)
        content.addSubview(footer)
        // The box clips what it holds, with its own rounded shape: while its edge moves, a row or the footer line
        // shows only inside it, never past a corner.
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerRadius = panelCorner
        content.layer?.cornerCurve = .continuous
        layoutBox()
    }

    /// The footer (a hairline and the facts line) rides the bottom edge; when the box is shorter than field +
    /// footer it stays under the field and the edge cuts it, so it is never drawn over the field.
    /// No facts line (the kinds of «/»): the list reaches the bottom edge.
    var footerHidden = false { didSet { footer.isHidden = footerHidden; layoutBox() } }

    private func layoutBox() {
        let w = bounds.width, h = bounds.height
        background.frame = bounds
        content.frame = bounds
        topLine.frame = NSRect(x: 0, y: fieldH, width: w, height: 1)
        let fy = max(h - factsH - 1, fieldH + 1)
        footer.frame = NSRect(x: 0, y: fy, width: w, height: factsH + 1)
        bottomLine.frame = NSRect(x: 0, y: 0, width: w, height: 1)
        facts.frame = NSRect(x: 20, y: 1 + (factsH - 17) / 2, width: w - 40, height: 17)
        scroll.frame = NSRect(x: 0, y: fieldH + 1, width: w, height: max(0, (footerHidden ? h : fy) - fieldH - 1))
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        if background != nil { layoutBox() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: taken by its edge

    weak var owner: PanelController?

    /// Spotlight's panel is taken by its edges (SpotlightUIInternal's TouchWindowDragEdges): here everything that
    /// is not the search text or a row's body: the field row around the text, the footer, and the band at each side
    /// of the list outside the rows' highlight.
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let hit = super.hitTest(p) else { return nil }
        let q = convert(p, from: superview)
        if field.frame.contains(q) { return hit }
        let list = scroll.frame
        if list.contains(q) && q.x > list.minX + listInset && q.x < list.maxX - listInset { return hit }
        return self
    }

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { owner?.drag(from: e) }
    override func menu(for e: NSEvent) -> NSMenu? { owner?.emptyMenu() }

    /// The kind token before the search text (Mail's and Finder's search tokens), or none.
    func setToken(_ p: Pane?) {
        let fh = field.frame.height, y = (fieldH - fh) / 2
        guard let p else {
            token.isHidden = true
            field.frame = NSRect(x: 50, y: y, width: panelSize.width - 50 - 20, height: fh)
            return
        }
        token.show(p)
        let s = token.fittingSize
        token.frame = NSRect(x: 50, y: ((fieldH - s.height) / 2).rounded(), width: s.width, height: s.height)
        token.isHidden = false
        let x = token.frame.maxX + 6
        field.frame = NSRect(x: x, y: y, width: panelSize.width - x - 20, height: fh)
    }

    // The list's keys when the search field has none (no caret on opening).
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if owner?.listKey(e) == true { return }
        // Letters wait for ⌘F, silently (no beep for every key).
        if e.modifierFlags.intersection([.command, .control]).isEmpty { return }
        super.keyDown(with: e)
    }

    /// «4 объекта · 3 381 символ · 519 слов · ≈ 2 737 токенов · 6,2 МБ»: the count bold, the rest secondary.
    func setFacts(_ f: Facts?, note: String?) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        let s = NSMutableAttributedString()
        defer {
            let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail
            s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
            facts.attributedStringValue = s
        }
        if let f {
            s.append(NSAttributedString(string: f.head, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            if !f.parts.isEmpty {
                s.append(NSAttributedString(string: "  ·  " + f.parts.joined(separator: "  ·  "), attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        } else if let note {
            s.append(NSAttributedString(string: note, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
    }

    // MARK: motion

    /// Blur, fade (the window's) and 3 % growth from the centre, together, with the system's ease-in.
    func animateOut(duration d: Double) {
        guard let l = layer else { return }
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(0, forKey: kCIInputRadiusKey)
        blur.name = "blur"
        l.filters = [blur]
        let b = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        b.fromValue = 0; b.toValue = 10
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, 1.03, 1.03, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let s = CABasicAnimation(keyPath: "sublayerTransform")
        s.fromValue = CATransform3DIdentity; s.toValue = t
        for a in [b, s] {
            a.duration = d
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }
        l.add(b, forKey: "blur")
        l.add(s, forKey: "grow")
    }

    func resetMotion() {
        layer?.removeAllAnimations()
        layer?.filters = nil
        layer?.sublayerTransform = CATransform3DIdentity
    }
}

/// A hairline between the field, the list and the facts line.
final class Separator: NSView {
    override func draw(_ r: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        bounds.fill()
    }
}

/// The list: rows are picked by our own Selection (ordered, like Finder's but remembering the order), so the table's
/// own selection is off and clicks come here.
final class ListTable: NSTableView {
    weak var owner: PanelController?
    private var down: (row: Int, at: NSPoint)?
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let r = row(at: p)
        down = (r, p)
        owner?.mouseDown(row: r, flags: e.modifierFlags, clicks: e.clickCount)
    }
    /// A row dragged 3 pt or more goes out as files (drag.swift).
    override func mouseDragged(with e: NSEvent) {
        guard let d = down, d.row >= 0 else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(p.x - d.at.x, p.y - d.at.y) >= 3 else { return }
        down = nil
        owner?.pending = nil
        owner?.dragOut(row: d.row, event: e, at: p)
    }
    override func mouseUp(with e: NSEvent) { down = nil; owner?.mouseUp() }
    override func menu(for e: NSEvent) -> NSMenu? {
        owner?.contextMenu(row: row(at: convert(e.locationInWindow, from: nil)))
    }
    // Hook for later: drag out of the panel, several at once like Finder (clipboard.md, «Decided»).
}

final class PlainRow: NSTableRowView {
    override func drawSelection(in r: NSRect) {}
    override func drawBackground(in r: NSRect) {}
}

final class HeadCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("head")
    let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: panelSize.width, height: 29))
        identifier = Self.id
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: listInset + 12, y: 11, width: panelSize.width - 2 * listInset - 24, height: 15)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// ⌘V into a text view of Copia's own (the panel's search field, the preview's editor): the pasteboard's plain string
/// put in as typed text. AppKit's paste turns the bidi embedding and override characters of a plain string
/// (U+202A-U+202E) into nested NSWritingDirection attributes; on macOS 26, a run nested about 12 deep makes
/// CoreFoundation's bidi pass trap («Size of noLongerSeeControlChars has exceeded allowed control character limit») and
/// the app dies (stress runs 2026-11-26/27, four crashes; Merum met the same trap, its window.swift). Inserted as a
/// string, every character stays, the controls too; only those attributes are not made. A styled copy (RTF, HTML) into
/// a rich text view keeps AppKit's paste, which reads the styles and makes no such attributes from plain controls.
func pasteText(into tv: NSTextView, limit: Int? = nil) {
    let pb = NSPasteboard.general
    if tv.isRichText, limit == nil, pb.availableType(from: [.rtfd, .rtf, .html]) != nil { tv.paste(nil); return }
    guard tv.isEditable, var s = pb.string(forType: .string) else { tv.paste(nil); return }
    if let n = limit, s.utf8.count > n { s = String(s.prefix(n)) }
    tv.insertText(s, replacementRange: tv.selectedRange())
}
