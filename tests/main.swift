// Off-screen tests of Copia, built by ./test from the app's own sources (all but main.swift).
//   copia-tests unit                 selection, facts, store, delete/undo, search speed, the paste folder
//   clip-tests capture              the monitor on a private named pasteboard
//   clip-tests links                link titles and pictures from real Safari copies (tests/links), network denied
//   clip-tests copy                 the one-write copy on a private named pasteboard: items and types, order, files
//   clip-tests general              capture and copy on the GENERAL pasteboard, his content saved before and put back
//                                   after (run outside Claude's command sandbox: inside it, file URLs after the first
//                                   are dropped by sandbox extensions)
//   clip-tests render APP THEME OUT [motion]   the panel drawn in a window under the desktop (never on the screen),
//                                   captured with screencapture -l; «motion» steps the leaving animation 20 × slower
import AppKit
import AVKit
import SQLite3
import UniformTypeIdentifiers

let argv = CommandLine.arguments
var failures = 0, passed = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if ok { passed += 1 } else { failures += 1; print("FAIL \(what())") }
}
func finish(_ name: String) -> Never {
    print(failures == 0 ? "\(name): \(passed) ok" : "\(name): \(failures) failed, \(passed) ok")
    exit(failures == 0 ? 0 : 1)
}
func tmpDir(_ tag: String) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("clip-test-\(tag)-\(UUID().uuidString.prefix(8))")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
/// Runs the main run loop until `done` or the timeout; true when done.
func wait(_ timeout: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return done()
}
func testImage(_ text: String, _ rgb: (CGFloat, CGFloat, CGFloat), w: Int = 400, h: Int = 250) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(deviceRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 80), .foregroundColor: NSColor.white])
        .draw(at: NSPoint(x: 30, y: 60))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
func item(_ pairs: [(String, Data)]) -> NSPasteboardItem {
    let it = NSPasteboardItem()
    for (t, d) in pairs { it.setData(d, forType: .init(t)) }
    return it
}
func types(_ pb: NSPasteboard) -> [[String]] { (pb.pasteboardItems ?? []).map { $0.types.map(\.rawValue) } }
let png = NSPasteboard.PasteboardType.png.rawValue, tiff = NSPasteboard.PasteboardType.tiff.rawValue
let furl = NSPasteboard.PasteboardType.fileURL.rawValue, str = NSPasteboard.PasteboardType.string.rawValue
let rtf = NSPasteboard.PasteboardType.rtf.rawValue, html = NSPasteboard.PasteboardType.html.rawValue

/// A store with entries made through the real path (prepare + add), newest last in `specs`.
func seeded(_ dir: URL, _ specs: [(Snapshot, Date)]) -> (Store, [Int64]) {
    let s = try! Store(dir: dir)
    var ids: [Int64] = []
    for (snap, d) in specs { let (e, it) = prepare(snap, dir: dir, at: d)!; ids.append(s.add(e, it)) }
    return (s, ids)
}
func textSnap(_ t: String, app: String? = "com.apple.Safari") -> Snapshot {
    Snapshot(items: [[Rep(type: str, data: Data(t.utf8))]], source: app)
}
func imageSnap(_ d: Data, app: String? = "com.geragaraza.pixlift") -> Snapshot {
    Snapshot(items: [[Rep(type: png, data: d)]], source: app)
}

// MARK: unit

func unit() {
    // Titles the app makes up are made when shown, in the interface language, whatever the store holds.
    do {
        let e = Entry(copied: Date(), app: nil, kind: .image, title: "3 objects", text: "", bytes: 1, count: 3, digest: "x")
        check(shownTitle(e) == counted(3, "object|objects"), "a several-image title is made when shown")
        var f = e; f.kind = .text; f.title = "hello"
        check(shownTitle(f) == "hello", "a text's title is its own")
    }
    // Selection, Finder's way plus the order.
    var s = Selection()
    let list: [Int64] = [10, 9, 8, 7, 6, 5]   // newest first, as shown
    s.click(9); check(s.order == [9], "click")
    s.toggle(7); s.toggle(10); check(s.order == [9, 7, 10] && s.badge(10) == 3 && s.badge(9) == 1, "⌘-click order \(s.order)")
    s.toggle(7); check(s.order == [9, 10] && s.badge(7) == nil, "⌘-click off")
    s.click(9); s.extend(to: 6, in: list); check(s.order == [9, 8, 7, 6], "⇧-click down \(s.order)")
    s.extend(to: 10, in: list); check(s.order == [9, 10], "⇧-click replaces the range \(s.order)")
    s.click(8); s.toggle(5); s.extend(to: 7, in: list); check(s.order == [8, 5, 6, 7], "⌘ then ⇧ keeps what was picked \(s.order)")
    s.all(list); check(s.order == [8, 5, 6, 7, 9, 10], "⌘A: the picks keep their numbers, the rest in copy order \(s.order)")
    s.clear(); s.all(list); check(s.order == [5, 6, 7, 8, 9, 10], "⌘A with nothing picked = copy order, oldest first")
    s.clear(); s.click(10); s.toggle(9); s.toggle(8); s.all(list)
    check(Array(s.order.prefix(3)) == [10, 9, 8], "⌘A after 1, 2, 3 from the top: still 1, 2, 3 (0.4 flipped them) \(s.order)")
    s.clear(); s.move(1, in: list, extending: false); check(s.order == [10], "↓ from nothing = first row")
    s.move(1, in: list, extending: false); s.move(1, in: list, extending: true); s.move(1, in: list, extending: true)
    check(s.order == [9, 8, 7], "⇧↓ stretches \(s.order)")
    s.move(-1, in: list, extending: false); check(s.order == [8], "↑ from the cursor \(s.order)")
    s.click(10); s.move(-1, in: list, extending: false); check(s.order == [10], "↑ stops at the top")
    s.click(9); s.toggle(7); s.remove([9]); check(s.order == [7], "delete leaves the order")
    var one = Selection(); one.click(5); check(one.badge(5) == nil, "no badge for one")

    // Plurals, sizes, facts.
    strings = Bundle.main
    check(counted(1, "object|objects") == "1\u{00A0}object" && counted(4, "object|objects") == "4\u{00A0}objects", "en plurals")
    check(wordCount("Слушай, мне нужен пауэрбанк — для поездок; it's fine") == 8, "words \(wordCount("Слушай, мне нужен пауэрбанк — для поездок; it's fine"))")
    check(Int(imageTokens(3456, 2234).rounded()) == 1533, "image tokens \(imageTokens(3456, 2234))")
    check(isColor("#0A84FF") && !isColor("#0A84FG") && rgb("#0A84FF")! == (10, 132, 255), "colour")

    // Store: WAL, permissions, dedupe, Recently Deleted, retention, orphan files.
    let dir = tmpDir("store")
    let img = testImage("1", (0.1, 0.4, 0.9))
    let now = Date()
    let (st, ids) = seeded(dir, [(textSnap("alpha"), now.addingTimeInterval(-40 * 86400)), (imageSnap(img), now.addingTimeInterval(-60)),
                                 (textSnap("beta"), now)])
    check(st.entries().map(\.title) == ["beta", L("Image"), "alpha"], "newest first \(st.entries().map(\.title))")
    let mode = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) ?? 0
    check(mode == 0o700, "store folder 0700 (\(String(mode, radix: 8)))")
    let jm = Process(); jm.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    jm.arguments = [dir.appendingPathComponent("copia.sqlite").path, "PRAGMA journal_mode;"]
    let pipe = Pipe(); jm.standardOutput = pipe; try? jm.run(); jm.waitUntilExit()
    check(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.contains("wal") == true, "WAL")
    let imgEntry = st.entries().first { $0.kind == .image }!
    check(imgEntry.thumb == "images/" + sha(img) + ".png" && FileManager.default.fileExists(atPath: dir.appendingPathComponent(imgEntry.thumb!).path),
          "image stored as PNG named by its SHA-256")
    check(imgEntry.width == 400 && imgEntry.height == 250, "image size")
    // The same image as TIFF only (as Safari copies) is the same picture once converted: one file, one entry.
    let tiffData = NSBitmapImageRep(data: img)!.tiffRepresentation!
    let (e2, it2) = prepare(Snapshot(items: [[Rep(type: tiff, data: tiffData)]], source: nil), dir: dir)!
    check(it2[0].map(\.type) == [png], "TIFF alone kept as PNG")
    let again = st.add(e2, it2)
    let pngFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("images").path))?.count ?? 0
    check(pngFiles <= 2, "image files deduped (\(pngFiles))")
    let n0 = st.entries().count
    let id3 = st.add(prepare(textSnap("alpha"), dir: dir)!.0, prepare(textSnap("alpha"), dir: dir)!.1)
    check(st.entries().count == n0 && id3 == ids[0] && st.entries().first?.id == ids[0], "same copy again = moved to the top, no twin")
    st.delete([ids[2]])
    check(!st.entries().contains { $0.id == ids[2] } && st.entries(deleted: true).map(\.id) == [ids[2]], "delete into Recently Deleted")
    st.undelete([ids[2]]); check(st.entries().contains { $0.id == ids[2] }, "undelete")
    st.delete([ids[1]], at: now.addingTimeInterval(-31 * 86400))
    if again != ids[1] { st.delete([again], at: now.addingTimeInterval(-31 * 86400)) }
    check(st.keep == .days30, "keep history: 30 days by default")
    st.keep = .forever
    let reopened = try! Store(dir: dir)
    check(reopened.keep == .forever, "keep setting stored")
    do {   // a shorter period asks first when it would remove copies (settings.swift, keepChanged): how many
        let kdir = tmpDir("keep")
        let (ks, _) = seeded(kdir, [(textSnap("old"), Date().addingTimeInterval(-3 * 86400)), (textSnap("new"), Date())])
        check(ks.olderThan(.day1) == 1 && ks.olderThan(.days7) == 0 && ks.olderThan(.forever) == 0, "copies a shorter period would remove")
        try? FileManager.default.removeItem(at: kdir)
    }
    reopened.keep = .days30
    // 0.6: STT's scale without «Don't Keep», short to long, Forever last; 0.5's stored «30d», «1y», «forever» read as before.
    check(Keep.allCases == [.day1, .days7, .days30, .year1, .forever] && Keep.allCases.map(\.rawValue).suffix(3) == ["30d", "1y", "forever"],
          "keep scale: 1 Day, 7 Days, 30 Days, 1 Year, Forever; old values kept")
    check(Keep.allCases.map(\.title) == ["1 Day", "7 Days", "30 Days", "1 Year", "Forever"].map(L), "keep titles are STT's words")
    check(Keep.day1.seconds == 86400 && Keep.days7.seconds == 7 * 86400, "1 day and 7 days")
    reopened.setSetting("keep", "1y"); check(reopened.keep == .year1, "a stored 1 Year stays 1 Year")
    reopened.setSetting("keep", "forever"); check(reopened.keep == .forever, "a stored Forever stays Forever")
    reopened.keep = .days30
    reopened.purge(now: now.addingTimeInterval(3600))
    check(reopened.entries(deleted: true).isEmpty, "Recently Deleted emptied after 30 days")
    reopened.purge(now: now.addingTimeInterval(31 * 86400))
    let leftImages = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("images").path)) ?? []
    check(leftImages.isEmpty, "orphan image files removed \(leftImages)")
    check(reopened.entries().isEmpty, "30-day history purged \(reopened.entries().map(\.title))")

    // Facts of a selection (en).
    let fdir = tmpDir("facts")
    let (fs, fids) = seeded(fdir, [(textSnap("Привет, мир"), now), (textSnap("hello world again"), now), (imageSnap(testImage("2", (1, 0, 0), w: 3456, h: 2234)), now)])
    let f = Facts(fids.compactMap { id in fs.entries().first { $0.id == id } })
    check(f.head == "3\u{00A0}objects", "facts head \(f.head)")
    check(f.parts.count == 4 && f.parts[1] == "28\u{00A0}characters" && f.parts[2] == "5\u{00A0}words", "facts parts \(f.parts)")
    check(f.parts[3].hasPrefix("≈"), "tokens last \(f.parts)")
    check(roundTokensUp(2416) == 2450 && roundTokensUp(19941) == 20000 && roundTokensUp(7.2) == 8 && roundTokensUp(82) == 85 && roundTokensUp(415) == 420, "roundTokensUp")

    // Delete and undo through the panel's controller (no window).
    let ddir = tmpDir("delete")
    let base = now.addingTimeInterval(-600)
    let (ds, did) = seeded(ddir, (0..<6).map { (textSnap("item \($0)"), base.addingTimeInterval(Double($0))) })
    let pc = PanelController(store: ds, monitor: nil, onScreen: false)
    let shown0 = pc.shown.map(\.id)
    check(shown0 == did.reversed(), "panel lists newest first")
    pc.mouseDown(row: 2, flags: [], clicks: 1); pc.mouseDown(row: 4, flags: .command, clicks: 1)   // row 0 is the «Today» head
    let picked = pc.sel.order
    check(picked == [shown0[1], shown0[3]], "click + ⌘-click \(picked)")
    pc.deleteSelection()
    check(pc.shown.count == 4 && pc.sel.order == [shown0[2]], "⌘⌫: gone, the next row takes the selection \(pc.sel.order)")
    check(ds.entries(deleted: true).count == 2, "⌘⌫ goes to Recently Deleted")
    appUndo.removeAllActions()
    check(pc.undoDelete() && pc.shown.map(\.id) == shown0 && pc.sel.order == picked, "⌘Z: back in place, picked as before")
    // One undo for the app (appUndo): a panel deletion comes back through the undo the big window's Edit menu uses.
    pc.sel.clear(); pc.mouseDown(row: 2, flags: [], clicks: 1)
    pc.deleteSelection()
    _ = wait(0.05) { false }   // the undo group closes at the end of the run loop's turn, as after a key press
    check(appUndo.canUndo && ds.entries(deleted: true).count == 1, "a panel deletion is on the app's undo (\(appUndo.canUndo), \(ds.entries(deleted: true).count), picks \(pc.sel.order.count))")
    appUndo.undo()
    check(ds.entries(deleted: true).isEmpty && pc.shown.map(\.id) == shown0, "undone from the app's undo: back")
    pc.sel.clear(); pc.selectAll(); check(pc.sel.order == did, "⌘A in copy order")
    check(pc.listChange(["h", "a", "b", "c"], ["h", "c"]) == .removed([1, 2]) && pc.listChange(["h", "c"], ["h", "a", "b", "c"]) == .inserted([1, 2])
          && pc.listChange(["a", "b"], ["b", "a"]) == nil, "a deletion and its undo are told apart from any other change (animated)")
    pc.mouseDown(row: 1, flags: [], clicks: 1)
    check(pc.sel.order == did, "a plain click on a picked row keeps the set until the mouse goes up")
    pc.mouseUp(); check(pc.sel.order == [shown0[0]], "…then picks the one row")

    // Keys through the real panel window (made, never shown): ⌘A, ⌘⌫, ⌘Z, arrows, ⌘C with one write, Esc.
    let kpb = NSPasteboard(name: .init("com.geragaraza.copia.test.keys.\(getpid())"))
    let kc = PanelController(store: ds, monitor: nil, onScreen: true)
    kc.pasteboard = kpb
    func key(_ ch: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = .command) -> Bool {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: kc.window!.windowNumber,
                                 context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        return kc.window!.performKeyEquivalent(with: e)
    }
    func cmd(_ s: Selector) { _ = kc.control(kc.view.field, textView: NSTextView(), doCommandBy: s) }
    check(key("a", 0) && kc.sel.order == did, "⌘A through the window")
    check(key("\u{7f}", 51) && kc.shown.isEmpty && ds.entries(deleted: true).count == 6, "⌘⌫ through the window")
    check(key("z", 6) && kc.shown.count == 6 && kc.sel.order == did, "⌘Z through the window")
    cmd(#selector(NSResponder.moveDown(_:))); cmd(#selector(NSResponder.moveDown(_:)))
    cmd(#selector(NSResponder.moveDownAndModifySelection(_:)))
    check(kc.sel.order == [shown0[2], shown0[3]], "↓ ↓ from the top, then ⇧↓ \(kc.sel.order)")
    check(key("c", 8) && kpb.string(forType: .string) == "item 3\nitem 2", "⌘C writes the picked rows in one item: \(kpb.string(forType: .string) ?? "nil")")
    check(!key("c", 8, [.command, .shift]), "⇧⌘C is not ours")
    // Real key events through the window (never shown): ↓ from the field picks the first row, Space previews it.
    func press(_ ch: String, _ code: UInt16) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: kc.window!.windowNumber,
                                 context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        kc.window!.sendEvent(e)
    }
    kc.sel.clear(); kc.selectionChanged()
    let firstResponder = kc.window!.makeFirstResponder(kc.view.field)
    kc.preview.host = Flipped(frame: NSRect(x: 0, y: 0, width: 1728, height: 1117))
    press("\u{F701}", 125)
    check(kc.sel.order == [shown0[0]], "↓ as a real key event picks the first row \(kc.sel.order)")
    press(" ", 49)
    check(kc.preview.isOpen, "Space as a real key event opens the preview")
    press(" ", 49)
    kc.preview.dismiss()
    kpb.releaseGlobally()

    // ⌥⌘C registers (Carbon, no permission), and is let go at once.
    let hk = App(store: ds)
    check(hk.registerHotKey() == noErr, "⌥⌘C registered")
    hk.unregisterHotKey()

    // Height follows the content (Spotlight's): the field alone with nothing listed, rows + footer, at most 720.
    let hdir = tmpDir("height")
    let hs = try! Store(dir: hdir)
    let hc = PanelController(store: hs, monitor: nil, onScreen: false)
    check(hc.contentHeight() == fieldH && hc.view.frame.height == fieldH, "empty history: the field alone (\(hc.contentHeight()))")
    for i in 0..<3 { let (e, it) = prepare(textSnap("row \(i)"), dir: hdir, at: now.addingTimeInterval(Double(i)))!; hs.add(e, it) }
    hc.reload()
    let three = fieldH + 1 + (29 + 2) + 3 * (rowH + 2) + 8 + 1 + factsH
    check(hc.contentHeight() == three && hc.view.frame.height == three, "three rows: \(hc.contentHeight()) = \(three)")
    for i in 3..<40 { let (e, it) = prepare(textSnap("row \(i)"), dir: hdir, at: now.addingTimeInterval(Double(i)))!; hs.add(e, it) }
    hc.reload()
    check(hc.contentHeight() == panelSize.height, "many rows: capped at \(panelSize.height), then the list scrolls (\(hc.contentHeight()))")
    hc.view.field.stringValue = "nothing like this"; hc.filter()
    check(hc.view.frame.height == fieldH, "no match: the field alone")
    // Animated: only the bottom edge moves, 200 ms eased, top fixed, every 60 fps frame between the two heights.
    Ticker.manual = true
    hc.view.field.stringValue = ""; hc.filter()   // not visible: no animation
    check(hc.view.frame.height == panelSize.height, "not shown: the height changes at once")
    hc.setBox(height: panelSize.height, top: 900)
    hc.view.field.stringValue = "row 7"; hc.fitHeightAfterFilterForTest()
    var hs60: [CGFloat] = [hc.height]
    for _ in 0..<20 { Ticker.advance(1.0 / 60); hs60.append(hc.height) }
    let target = hc.contentHeight()
    let settled = hs60.firstIndex(of: target) ?? 99
    check(zip(hs60, hs60.dropFirst()).allSatisfy { $0 >= $1 } && settled >= 10 && settled <= 13 && hc.top == 900,
          "shrinking: monotonic, settled on frame \(settled) (12 = 200 ms), top fixed: \(hs60.map { Int($0) })")
    Ticker.manual = false
    try? FileManager.default.removeItem(at: hdir)

    // The fifteen places (place.swift, PlaceGrid; his pick 2026-11-16): on Grids' lines on every kind of screen.
    // Screens as (frame, visible frame) in AppKit points: the 16-inch Pro (his), the 14-inch Pro, the 13-inch Air, an
    // old 13-inch with a 24 pt menu bar and the Dock at the bottom, a 1280 × 800 with the Dock on the left, a 27-inch
    // external to the right and above, a screen barely wider and taller than the panel, and the real screens here.
    var screens: [(String, NSRect, NSRect)] = [
        ("16-inch", NSRect(x: 0, y: 0, width: 1728, height: 1117), NSRect(x: 0, y: 0, width: 1728, height: 1085)),
        ("14-inch", NSRect(x: 0, y: 0, width: 1512, height: 982), NSRect(x: 0, y: 0, width: 1512, height: 950)),
        ("Air 13", NSRect(x: 0, y: 0, width: 1470, height: 956), NSRect(x: 0, y: 0, width: 1470, height: 919)),
        ("Dock bottom", NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: 0, y: 76, width: 1440, height: 800)),
        ("Dock left", NSRect(x: 0, y: 0, width: 1280, height: 800), NSRect(x: 64, y: 0, width: 1216, height: 776)),
        ("external", NSRect(x: 1728, y: -323, width: 2560, height: 1440), NSRect(x: 1728, y: -323, width: 2560, height: 1415)),
        ("tiny", NSRect(x: 0, y: 0, width: 660, height: 600), NSRect(x: 0, y: 0, width: 660, height: 576)),
    ]
    for sc in NSScreen.screens { screens.append((sc.localizedName, sc.frame, sc.visibleFrame)) }
    for (name, f, v) in screens {
        let g = PlaceGrid(frame: f, visible: v)
        func onGrid(_ x: CGFloat) -> Bool { abs(x / gridStep - (x / gridStep).rounded()) < 0.001 }
        let ls = g.lefts.map { $0 - f.minX }   // from the screen's left, as Grids counts
        let t0 = f.maxY - g.topEdge, m = f.maxY - g.middleEdge, b0 = f.maxY - g.bottomEdge
        check(zip(ls, ls.dropFirst()).allSatisfy { $0 <= $1 }, "\(name): columns left to right \(ls)")
        check(onGrid(ls[0]) && onGrid(ls[4] + panelSize.width) && onGrid(t0) && onGrid(m) && onGrid(b0),
              "\(name): sides, top, middle and bottom on Grids' 8 pt lines: \(ls) \(t0) \(m) \(b0)")
        // The centre column on Grids' red 1/2 line; the two between on the centre's own lattice, so on the 8 pt lines too
        // wherever the centre is (a screen whose half is a whole multiple of 8 beyond the panel's: all but the 14-inch).
        check(ls[2] + panelSize.width / 2 == f.width / 2 || ls[0] == ls[4], "\(name): centre column on the half line")
        check(onGrid(ls[2] - ls[1]) && onGrid(ls[3] - ls[2]) && (!onGrid(ls[2]) || (onGrid(ls[1]) && onGrid(ls[3]))),
              "\(name): the columns between on the grid")
        let steps = zip(ls, ls.dropFirst()).map { $1 - $0 }
        check(ls[0] == ls[4] || steps.max()! - steps.min()! <= 2 * gridStep + abs(ls[2] - (ls[0] + ls[4]) / 2) * 2,
              "\(name): the five even, \(steps)")
        // Inside the visible frame, at least edgeRoom from its edges and less than a grid step more.
        let vx0 = v.minX - f.minX, vx1 = v.maxX - f.minX, vy0 = f.maxY - v.maxY, vy1 = f.maxY - v.minY
        check(ls[0] >= vx0 + edgeRoom && ls[0] < vx0 + edgeRoom + gridStep || ls[0] == ls[4], "\(name): left side \(ls[0] - vx0) in")
        check(ls[4] + panelSize.width <= vx1 - edgeRoom && ls[4] + panelSize.width > vx1 - edgeRoom - gridStep || ls[0] == ls[4],
              "\(name): right side \(vx1 - ls[4] - panelSize.width) in")
        check(t0 >= vy0 + edgeRoom && t0 < vy0 + edgeRoom + gridStep && b0 <= vy1 - edgeRoom && b0 > vy1 - edgeRoom - gridStep,
              "\(name): top \(t0 - vy0) under the menu bar, bottom \(vy1 - b0) over the visible frame's bottom")
        // The middle row: a full panel's centre on the screen's half line, within half a grid step; it never leaves
        // the room between the top and bottom rows.
        let full = min(panelSize.height, b0 - t0)
        check(m >= t0 && m + full <= b0 && (abs(m + full / 2 - f.height / 2) <= gridStep / 2 || m == t0 || m + full == b0),
              "\(name): middle row \(m), a full panel's centre \(m + full / 2) on the half line \(f.height / 2)")
        check(g.room(.top) == b0 - t0 && g.room(.middle) == b0 - m && g.room(.bottom) == b0 - t0, "\(name): the room at each row")
        // Fifteen distinct places for a full panel (one column or one row only when the screen leaves no room).
        let pts = Set(Place.allCases.map { "\(g.places(height: full).point($0))" })
        check(pts.count == 15 || ls[0] == ls[4] || t0 == m, "\(name): \(pts.count) distinct places")
    }
    // His screen, by the numbers: 8, 272, 544, 816, 1080 across (the panel's left edge); 40, 288 and 1112 down.
    let his = PlaceGrid(frame: NSRect(x: 0, y: 0, width: 1728, height: 1117), visible: NSRect(x: 0, y: 0, width: 1728, height: 1085))
    check(his.lefts == [8, 272, 544, 816, 1080] && 1117 - his.topEdge == 40 && 1117 - his.middleEdge == 288 && 1117 - his.bottomEdge == 1112,
          "his 16-inch: \(his.lefts), \(1117 - his.topEdge), \(1117 - his.middleEdge), \(1117 - his.bottomEdge)")
    check(Place.allCases.count == 15 && Place.at(.middle, .left) == .middleLeft && Place.at(.bottom, .innerRight) == .bottomInnerRight
          && ["top", "middle", "bottom", "topLeft", "topRight", "middleLeft", "middleRight", "bottomLeft", "bottomRight"].allSatisfy { Place(rawValue: $0) != nil }
          && Place(rawValue: "top")!.column == .centre && Place(rawValue: "bottomRight")!.column == .right,
          "fifteen places; the nine stored by 0.7-0.1 and 0.4's three still read as the same places")
    check(Set(Place.allCases.map(\.title)).count == 15 && Place.top.title == "Top Center" && Place.middle.title == "Center"
          && Place.bottomInnerLeft.title == "Bottom, Left of Center", "fifteen names: \(Place.allCases.map(\.title))")

    // What holds when the list changes (his word: nothing jumps): the top and middle rows keep the top edge, the bottom
    // row its bottom edge; an opening puts the panel by the same edge whatever the list holds; at the bottom the field
    // holds while a search is typed.
    if let main = NSScreen.main {
        let adir = tmpDir("anchor")
        let st = try! Store(dir: adir)
        for i in 0..<8 { let (e, it) = prepare(textSnap("anchor \(i)"), dir: adir, at: now.addingTimeInterval(Double(i)))!; st.add(e, it) }
        let ac = PanelController(store: st, monitor: nil, onScreen: false)
        ac.screen = main
        let g = PlaceGrid(main)
        for p in Place.allCases {
            ac.setPlace(p, on: main)   // remembered; not shown, so nothing moves yet
            ac.reload(); ac.placeAtRest()
            let h8 = ac.height, top8 = ac.top
            check(ac.left == g.left(p.column) && (p.row == .bottom ? top8 - h8 == g.bottomEdge : top8 == g.top(p.row, height: h8)),
                  "\(p.rawValue): opened at its place")
            // Five of the eight deleted (the night variants' case), then opened again.
            ac.sel.clear(); for id in ac.shown.prefix(5).map(\.id) { ac.sel.toggle(id) }
            ac.deleteSelection()
            let held = p.row == .bottom ? ac.top - ac.height == g.bottomEdge : ac.top == top8
            check(ac.height < h8 && held, "\(p.rawValue): five deleted, the \(p.row == .bottom ? "bottom" : "top") edge stays")
            let top3 = ac.top
            ac.placeAtRest()
            check(ac.top == top3 && ac.left == g.left(p.column), "\(p.rawValue): opened again, not a point moved")
            _ = ac.undoDelete(); ac.reload(); ac.placeAtRest()
            check(ac.top == top8 && ac.height == h8, "\(p.rawValue): undone, back as it was")
        }
        // At the bottom, typing: the field holds; cleared, the bottom edge is back on its line.
        ac.setPlace(.bottom, on: main); ac.reload(); ac.placeAtRest()
        let topB = ac.top
        ac.view.field.stringValue = "anchor 3"; ac.filter()
        check(ac.top == topB && ac.height < topB - g.bottomEdge, "bottom row, a search typed: the field stays, the bottom comes up")
        ac.view.field.stringValue = "/"; ac.filter()
        check(ac.top >= topB && ac.top - ac.height >= g.bottomEdge, "bottom row, «/»: the kinds fit above the bottom line")
        ac.view.field.stringValue = ""; ac.filter()
        check(ac.top == topB && ac.top - ac.height == g.bottomEdge, "bottom row, search cleared: back on the bottom line")
        // A copy arriving while open: the held edge stays (top row: the top; bottom row: the bottom).
        for p in [Place.top, .middleInnerLeft, .bottomRight] {
            ac.setPlace(p, on: main); ac.reload(); ac.placeAtRest()
            let t = ac.top, b = ac.top - ac.height
            let (e, it) = prepare(textSnap("arrived \(p)"), dir: adir, at: Date())!; st.add(e, it); ac.reload()
            check(p.row == .bottom ? ac.top - ac.height == b : ac.top == t, "\(p.rawValue): a new copy, the held edge stays")
        }
        // Many items: never taller than Spotlight's 546 or than the room at the row.
        for i in 0..<120 { let (e, it) = prepare(textSnap("many \(i)"), dir: adir, at: now.addingTimeInterval(100 + Double(i)))!; st.add(e, it) }
        for p in Place.allCases {
            ac.setPlace(p, on: main); ac.reload(); ac.placeAtRest()
            check(ac.height == min(panelSize.height, g.room(p.row)) && ac.top - ac.height >= g.bottomEdge && ac.top <= g.topEdge,
                  "\(p.rawValue), 129 items: \(ac.height) tall, inside the room")
        }
        try? FileManager.default.removeItem(at: adir)
    }

    // Drag (place.swift, 0.7): the panel follows the hand; each place is a soft magnet (caught within 16 pt, held until
    // 30 pt, both by a 120 ms slide); let go between places, it slides to the nearest; at rest always exact.
    if let main = NSScreen.main {
        let gdir = tmpDir("snap")
        let gs = try! Store(dir: gdir)
        for i in 0..<4 { let (e, it) = prepare(textSnap("snap \(i)"), dir: gdir, at: now.addingTimeInterval(Double(i)))!; gs.add(e, it) }
        let dc = PanelController(store: gs, monitor: nil, onScreen: false)
        dc.screen = main
        check(dc.placeFor(main) == .top, "top centre until moved (Spotlight's place)")
        dc.setBox(height: dc.contentHeight(), top: 0)
        let ps = dc.places!
        func at(_ p: Place) { dc.left = ps.point(p).x; dc.setBox(height: dc.height, top: ps.point(p).y) }
        func isPlace() -> Bool { Place.allCases.contains { ps.point($0) == NSPoint(x: dc.left, y: dc.top) } }
        func frames(_ n: Int) { for _ in 0..<n { Ticker.advance(1.0 / 60) } }
        at(.top)
        Ticker.manual = true
        let start = ps.point(.top)
        // A shake of up to 18 pt sideways and 20 pt down around the top centre (27 pt at most): it does not move a point.
        dc.dragBegin(places: ps)
        for k in 0..<40 {
            dc.dragMove(raw: NSPoint(x: start.x + CGFloat((k % 7) - 3) * 6, y: start.y - CGFloat(k % 5) * 5), places: ps)
            Ticker.advance(1.0 / 60)
        }
        check(dc.left == start.x && dc.top == start.y && dc.hapticTaps == 0, "a shake inside the magnet does not move it")
        // Down to the middle at 6 pt a frame: it lets go at 30 pt, follows the hand, is caught at the middle with one tap,
        // and no frame moves it more than 16 pt (0.6 leapt 264 pt in 150 ms).
        var seen: [NSPoint] = [NSPoint(x: dc.left, y: dc.top)]
        var hand = start
        for y in stride(from: start.y, through: ps.point(.middle).y, by: -6) {
            hand = NSPoint(x: start.x + 5, y: y)
            dc.dragMove(raw: hand, places: ps)
            Ticker.advance(1.0 / 60); seen.append(NSPoint(x: dc.left, y: dc.top))
        }
        let steps = zip(seen, seen.dropFirst()).map { dist($0, $1) }
        check(steps.max()! <= 16, "smooth: the largest step in one frame is \(steps.max()!) pt")
        check(seen.contains { $0.y < start.y - 40 && $0.y > ps.point(.middle).y + 40 }, "it follows the hand between the places")
        check(zip(seen, seen.dropFirst()).allSatisfy { $1.y <= $0.y }, "down only, never back up")
        frames(12)
        dc.dragEnd()
        frames(30)
        check(isPlace() && dc.placeFor(main) == .middle && dc.hapticTaps == 1, "dragged to the centre: there exactly, remembered, one tap")
        // Let go between places: it slides to the nearest one, exact.
        dc.dragBegin(places: ps)
        let mid = ps.point(.middle), br = ps.point(.bottomRight)
        dc.dragMove(raw: NSPoint(x: mid.x + (br.x - mid.x) * 0.85, y: mid.y + (br.y - mid.y) * 0.85), places: ps)
        frames(10)
        check(!isPlace(), "between the places while the hand holds it there")
        dc.dragEnd()
        var slide = [NSPoint(x: dc.left, y: dc.top)]
        for _ in 0..<30 { Ticker.advance(1.0 / 60); slide.append(NSPoint(x: dc.left, y: dc.top)) }
        let fastest = zip(slide, slide.dropFirst()).map { dist($0, $1) }.max()!
        check(fastest <= 40, "the slide to the place: at most \(Int(fastest)) pt in a frame")
        check(dc.placeFor(main) == .bottomRight && NSPoint(x: dc.left, y: dc.top) == br, "let go nearer the bottom right: slides there, exact")
        dc.dragBegin(places: ps)
        dc.dragMove(raw: NSPoint(x: ps.point(.topLeft).x + 30, y: ps.point(.topLeft).y - 20), places: ps)
        frames(12)
        dc.dragEnd()
        frames(30)
        check(dc.placeFor(main) == .topLeft && NSPoint(x: dc.left, y: dc.top) == ps.point(.topLeft), "top left, exact")
        // Pushed past the screen's corner it stays at the corner place.
        dc.dragBegin(places: ps)
        dc.dragMove(raw: NSPoint(x: ps.point(.topLeft).x - 200, y: ps.point(.topLeft).y + 200), places: ps)
        frames(12)
        check(NSPoint(x: dc.left, y: dc.top) == ps.point(.topLeft), "never past the outermost places")
        dc.dragEnd()
        // The middle row has all three places since 0.7.
        check(ps.at(NSPoint(x: ps.lefts[0], y: ps.tops[1])) == .middleLeft && ps.at(NSPoint(x: ps.lefts[4], y: ps.tops[1])) == .middleRight
              && ps.at(NSPoint(x: ps.lefts[1], y: ps.tops[2])) == .bottomInnerLeft, "the middle row has its sides, the rows their inner columns")
        // Settings' Position on Screen sets the same place.
        dc.setPlace(.bottom, on: main)
        check(dc.placeFor(main) == .bottom, "Position on Screen sets the place")
        Ticker.manual = false
        try? FileManager.default.removeItem(at: gdir)
    }

    // Editing a text (the Space preview): saved in place, the original kept once, reverted on demand.
    let edir = tmpDir("edit")
    let (es, eids) = seeded(edir, [(textSnap("first copy"), now), (Snapshot(items: [[Rep(type: rtf, data: Data("{\\rtf1 {\\b bold} text}".utf8)),
                                   Rep(type: str, data: Data("bold text".utf8))]], source: "com.apple.TextEdit"), now.addingTimeInterval(1))])
    es.edit(eids[0], plain: "edited copy", rtf: nil)
    var ee = es.entries().first { $0.id == eids[0] }!
    check(ee.title == "edited copy" && es.hasOriginal(eids[0]) && es.reps(eids[0]).first?.map(\.type) == [str], "edit: new text, original kept \(ee.title)")
    es.edit(eids[0], plain: "edited twice", rtf: nil)
    es.revert(eids[0])
    ee = es.entries().first { $0.id == eids[0] }!
    check(ee.title == "first copy" && !es.hasOriginal(eids[0]) && es.entries().map(\.id) == eids.reversed(), "revert: the first original back, the list order kept")

    // The preview controller, off-screen: Space's rule, live facts, bold, save, revert, the menu.
    let pv = PanelController(store: es, monitor: nil, onScreen: false)
    check(!pv.spaceOpensPreview, "Space with nothing picked: a space for the search")
    pv.mouseDown(row: 1, flags: [], clicks: 1)
    check(pv.spaceOpensPreview, "Space with a row picked: the preview")
    pv.view.field.stringValue = "bo"; pv.controlTextDidChange(Notification(name: .init("x")))
    // Space while the search has the caret is a space: checked on a real window (copia-tests screen).
    pv.view.field.stringValue = ""; pv.filter()
    let host = Flipped(frame: NSRect(x: 0, y: 0, width: 1728, height: 1117))
    pv.preview.host = host
    Ticker.manual = true
    pv.mouseDown(row: 2, flags: [], clicks: 1)   // «first copy» (plain)
    pv.togglePreview()
    check(pv.preview.isOpen && pv.preview.entry?.id == eids[0], "Space opens the picked row")
    var grow: [NSRect] = [pv.preview.boxFrame]
    for _ in 0..<18 { Ticker.advance(1.0 / 60); grow.append(pv.preview.boxFrame) }
    let fin = pv.preview.finalRect
    let aspect = grow.allSatisfy { abs($0.width / $0.height - fin.width / fin.height) < 0.02 }
    let w5 = (grow[5].width - grow[0].width) / (fin.width - grow[0].width)
    let at = grow.firstIndex { $0 == fin } ?? 99
    check(aspect && grow[0].width <= 40.5 && w5 > 0.75 && at == 15, "opens from the row's picture as one picture: \(Int(grow[0].width)) pt, \(Int(w5 * 100)) % at 83 ms, full at frame \(at) (250 ms)")
    let tv = pv.preview.textForTest!
    tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
    tv.insertText(" and more", replacementRange: tv.selectedRange())
    check(pv.preview.factsText.hasPrefix("19\u{00A0}bytes") && pv.preview.factsText.contains(counted(19, "character|characters")) && pv.preview.factsText.contains(counted(1, "line|lines")),
          "facts count live: \(pv.preview.factsText)")
    tv.setSelectedRange(NSRange(location: 0, length: 5))
    pv.preview.toggle(.boldFontMask)
    pv.preview.save()
    let saved = es.reps(eids[0]).first?.map(\.type) ?? []
    check(es.entries().first { $0.id == eids[0] }?.title == "first copy and more" && saved.contains(rtf) && pv.preview.revertShown,
          "⌘B then save: rich text stored, title follows, Revert shown \(saved)")
    pv.preview.revertToOriginal()
    check(es.entries().first { $0.id == eids[0] }?.title == "first copy" && tv.string == "first copy" && !pv.preview.revertShown, "Revert to Original")
    pv.closePreview()
    var shut: [NSRect] = []
    for _ in 0..<10 { Ticker.advance(1.0 / 60); shut.append(pv.preview.boxFrame) }
    let closedAt = (shut.firstIndex { $0.width <= 40.5 } ?? 99) + 1
    check(!pv.preview.isOpen && closedAt >= 7 && closedAt <= 9, "closes back into the row in \(closedAt) frames (Quick Look: ~8, 130 ms)")
    Ticker.manual = false

    let menu = pv.contextMenu(row: 1)!
    check(menu.items.map(\.title) == ["Paste", "Paste as Plain Text", "", "Copy", "Copy as Plain Text", "", "Share…", "Open With", "", "Delete"],
          "menu, one order: \(menu.items.map(\.title))")
    check(menu.items[9].keyEquivalent == "\u{8}" && menu.items[9].keyEquivalentModifierMask == .command, "Delete shows ⌘⌫")
    check(menu.items[0].keyEquivalent == "\r" && menu.items[0].keyEquivalentModifierMask == [] && menu.items[1].keyEquivalentModifierMask == .command,
          "Paste shows ↩, Paste as Plain Text ⌘↩")
    check(menu.items[7].submenu?.items.contains { $0.title == "TextEdit" } == true, "Open With lists TextEdit for a text")
    check(pv.contextMenu(row: -1)?.items.map(\.title) == ["Open Copia Window", "Clear History…", "Settings…"], "empty space: window, clear, settings")
    let mpb = NSPasteboard(name: .init("com.geragaraza.copia.test.menu.\(getpid())"))
    pv.pasteboard = mpb
    pv.menuCopyPlain()
    check(mpb.string(forType: .string) == "bold text" && mpb.pasteboardItems?.first?.types.contains(.rtf) == false, "Copy as Plain Text: the text without its style")
    mpb.releaseGlobally()
    try? FileManager.default.removeItem(at: edir)

    // Search speed: «search filtering in one frame» on a big history (5 000 entries of ~1.5 KB text).
    let sdir = tmpDir("search")
    let ss = try! Store(dir: sdir)
    let words = ["пауэрбанк", "самолёт", "аккумулятор", "ноутбук", "Telegram", "screenshot", "power", "bank", "заряд", "порт"]
    for i in 0..<5000 {
        var t = ""; for k in 0..<180 { t += words[(i * 7 + k * 3) % words.count] + " " }
        t += "уникум\(i)"
        let (e, it) = prepare(textSnap(t), dir: sdir, at: now.addingTimeInterval(Double(-i)))!
        ss.add(e, it)
    }
    let sc = PanelController(store: ss, monitor: nil, onScreen: false)
    let w0 = CFAbsoluteTimeGetCurrent(); sc.warmSearch(wait: true)
    print(String(format: "search: folding 5 000 entries once (background, at launch): %.0f ms", (CFAbsoluteTimeGetCurrent() - w0) * 1000))
    var times: [Double] = []
    for q in ["у", "ун", "уни", "уникум4999", "самолёт", ""] {
        sc.view.field.stringValue = q
        let t0 = CFAbsoluteTimeGetCurrent(); sc.filter(); times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    sc.view.field.stringValue = "уникум4999"; sc.filter()
    check(sc.shown.count == 1, "search finds one in 5 000")
    sc.view.field.stringValue = "САМОЛЕТ"; sc.filter()
    check(sc.shown.count == 5000, "search ignores case and ё/е (\(sc.shown.count))")
    check(times[1...4].allSatisfy { $0 < 16 }, "a key filters within one frame at 60 Hz (\(times))")
    print(String(format: "search over 5 000 entries: %@ ms per keystroke", times.map { String(format: "%.1f", $0) }.joined(separator: " / ")))

    // The paste folder: older than a day goes, the rest stays; at launch everything goes.
    let pdir = tmpDir("paste")
    let ps = try! Store(dir: pdir)
    let old = pdir.appendingPathComponent("paste/old"), fresh = pdir.appendingPathComponent("paste/new")
    for d in [old, fresh] { try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    try! FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-25 * 3600)], ofItemAtPath: old.path)
    Copia.cleanPasteFolder(ps, all: false)
    check(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path), "paste files: 24 h")
    Copia.cleanPasteFolder(ps, all: true)
    check(!FileManager.default.fileExists(atPath: fresh.path), "paste files: all at launch")

    for d in [dir, fdir, ddir, sdir, pdir] { try? FileManager.default.removeItem(at: d) }
    browserTests()
    keysTests()
    orderTests()
    dragTests()
    queueTests()
    // ⌘ shortcuts whatever the layout: a Cyrillic «ф» on the A key is read as «a» (macOS 27.2: ⌘A did nothing).
    do {
        func cmd(_ ch: String, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                             characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        }
        check(shortcutKey(cmd("ф", 0)) == "a", "⌘ф reads as ⌘A (\(shortcutKey(cmd("ф", 0))))")
        check(shortcutKey(cmd("с", 8)) == "c", "⌘с reads as ⌘C")
        check(shortcutKey(cmd("a", 0)) == "a" && shortcutKey(cmd(",", 43)) == ",", "Latin keys stay as they are")
    }
    // Order badges: a circle up to 9, a capsule from 10, the left edge and the height kept.
    do {
        let b = Badge(frame: NSRect(x: 5, y: 5, width: 20, height: 20))
        b.number = 7; check(b.frame.width == 20, "badge 7 is a circle")
        b.number = 22; check(b.frame.width > 20 && b.frame.minX == 5 && b.frame.height == 20, "badge 22 is a capsule (\(b.frame))")
        b.frame = NSRect(x: 5, y: 5, width: 20, height: 20); check(b.frame.width > 20, "a capsule stays one after a layout")
    }
    finish("unit")
}

/// The paste queue (queue.swift) on a private pasteboard: the next item is promised, an ask after a key is a paste and
/// moves the queue on once the asks stop, an ask with no key behind it only gets the data, several asks of one paste
/// count once, and closing leaves the item on the clipboard as ordinary data.
func queueTests() {
    let dir = tmpDir("queue")
    let now = Date()
    let (st, ids) = seeded(dir, [(textSnap("first line"), now), (textSnap("second line"), now.addingTimeInterval(1)),
                                 (imageSnap(testImage("q", (0, 0.5, 1))), now.addingTimeInterval(2)), (textSnap("last"), now.addingTimeInterval(3))])
    let pb = NSPasteboard(name: .init("com.geragaraza.copia.queue.\(getpid())"))
    let q = PasteQueue(store: st, pasteboard: pb)
    var key = 100.0   // seconds since the last key press, as CGEventSource would say
    q.sinceKey = { key }
    q.sinceClick = { 100 }
    q.sinceFlags = { 100 }
    var cmd = false   // ⌘ held now
    q.cmdDown = { cmd }
    var events: [String] = []
    q.onChange = { c in
        switch c { case .opened: events.append("open"); case .added(let i): events.append("add\(i)"); case .pasted(let i): events.append("paste\(i)"); case .closed: events.append("close") }
    }
    var emptied = 0
    q.onEmptied = { emptied += 1 }
    func settle() { _ = wait(PasteQueue.settle + 0.25) { false } }
    q.add([ids[0]])
    check(q.ids.isEmpty && events.isEmpty, "closed: copies do not join")
    q.open()
    q.add([ids[0], ids[1]])
    check(q.left == 2 && pb.pasteboardItems?.first?.types.contains(.own) == true, "two in the queue, the first on the clipboard, marked as ours")
    // A read with no key behind it (another clipboard tool, a background check): the data, but no paste.
    _ = wait(0.05) { false }
    check(pb.string(forType: .string) == "first line" && q.asks >= 1 && q.pastes == 0, "a read with no key: served, not a paste")
    settle()
    check(q.pasted == 0, "the queue stays on the first item")
    // ⌘V: a key after the item was placed; the app reads plain text and then RTF and HTML: one paste.
    key = 0.01
    _ = pb.string(forType: .string); _ = pb.data(forType: .rtf); _ = pb.string(forType: .string)
    check(q.pastes == 1 && q.pasted == 0, "one paste counted for several reads, the next item waits for them to stop")
    settle()
    check(q.pasted == 1 && pb.string(forType: .string) == "second line" && events.contains("paste0"), "then the second item takes its place")
    // A copy while it waits joins the end; the clipboard still gives the queue's next item.
    key = 100
    q.add([ids[2]])
    check(q.ids.count == 3 && pb.string(forType: .string) == "second line", "a new copy joins the end; the next item stays on top")
    key = 0.01
    _ = pb.string(forType: .string)
    settle()
    // The picture: promised as a file, a PNG and a TIFF made only when asked.
    let tiff = pb.data(forType: .tiff), png = pb.data(forType: .png)
    check(q.pasted == 2 && png != nil && tiff.flatMap { NSImage(data: $0) }?.size.width ?? 0 > 0 && pb.pasteboardItems?.first?.types.contains(.fileURL) == true,
          "the picture: file, PNG and a TIFF made from it")
    settle()
    check(q.pasted == 3 && emptied == 1 && q.left == 0, "the last one pasted: the queue is empty (\(q.pasted), \(emptied))")
    // Closing: what was last on the clipboard stays as ordinary data, no longer promised.
    let count = pb.changeCount
    q.close()
    check(!q.isOpen && pb.changeCount != count && pb.pasteboardItems?.first?.types.contains(.fileURL) == true, "closed: the last item written out for real")
    // Closed with items left: the next one stays on the clipboard.
    q.open(); key = 100
    q.add([ids[3], ids[0]])
    q.close()
    check(pb.string(forType: .string) == "last" && q.asks == 0, "closed early: the next item stays, as ordinary data (no ask)")
    // Fast ⌘V in a row (his trial 2026-11-15 10:00: «быстро вставляю раз, два, три… она поломалась»): a press every
    // 90 ms, each read right after its key; every press gets the next item, none twice, none skipped. (On real apps in
    // `cs`: six ⌘V into Notes with rich text, 30-100 ms apart, pasted one to six in order.)
    q.open()
    let four = [ids[0], ids[1], ids[3], ids[0]]
    q.add(four)
    var got: [String] = []
    for _ in 0..<4 {
        _ = wait(0.09) { false }
        key = 0.003
        got.append(pb.string(forType: .string) ?? "-")
    }
    check(got == ["first line", "second line", "last", "first line"], "four presses 90 ms apart paste the four items in order: \(got)")
    _ = wait(0.3) { false }
    check(q.left == 0, "all four used (\(q.left) left)")
    q.close()
    // The same with the clocks half a second late, as on his Mac (his trial 2026-11-15 10:47: twenty «1» in Notes): the
    // key clock never shows a press after the item was placed, but ⌘ is held at every read.
    q.open()
    q.add(four)
    key = 100; cmd = true
    got = []
    for _ in 0..<4 {
        _ = wait(0.25) { false }
        got.append(pb.string(forType: .string) ?? "-")
    }
    check(got == ["first line", "second line", "last", "first line"], "⌘ held, late clocks: four presses paste the four in order: \(got)")
    // And with ⌘ let go and the clocks late, a read is no paste (another tool reading the clipboard).
    cmd = false
    _ = wait(0.3) { false }
    check(q.left == 0, "all four used (\(q.left) left)")
    q.close()
    q.open(); q.add([ids[0], ids[1]])
    _ = pb.string(forType: .string); _ = wait(0.3) { false }
    check(q.left == 2, "no ⌘, no fresh key or click: a read is not a paste (\(q.left) left)")
    q.close()
    // Newest first (Settings, «Paste Order»): 4, 3, 2, 1; a copy made while it waits goes first.
    q.newestFirst = true
    q.open(); key = 100
    q.add([ids[0]]); q.add([ids[1]])
    check(pb.string(forType: .string) == "second line" && q.pending == [1, 0], "newest first: the last copy is next")
    settle()   // that read had no key behind it: the item is promised anew before the real paste
    key = 0.01
    _ = pb.string(forType: .string)
    settle()
    key = 100
    q.add([ids[3]])
    let top = pb.string(forType: .string)
    check(q.pasted == 1 && top == "last" && q.pending == [2, 0], "a new copy goes first; the older one waits (\(q.pasted), \(top ?? "-"), \(q.pending))")
    q.close()
    // Copy as Plain Text joins as plain text (0.8: it never reached the queue before); the next item is its text alone.
    q.newestFirst = false
    q.open(); key = 100
    q.add([ids[0]], plain: true)
    check(pb.pasteboardItems?.first?.types.contains(.string) == true && pb.pasteboardItems?.first?.types.contains(.rtf) == false
          && pb.string(forType: .string) == "first line", "a plain copy in the queue is its plain text alone")
    // Copia's own paste writes the picks past the queue; resume() puts the queue's next item back.
    settle()
    pb.clearContents(); pb.setString("picked", forType: .string)
    q.resume()
    check(pb.string(forType: .string) == "first line", "after Copia's own paste the queue's next item is back")
    q.close()
    pb.releaseGlobally()
    try? FileManager.default.removeItem(at: dir)
}

/// The settable keys (keys.swift), the clash check, and the panel's paste, Quick Pick and «/» kinds without a screen.
func keysTests() {
    func ev(_ code: Int, _ mods: NSEvent.ModifierFlags = [], _ ch: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: UInt16(code))!
    }
    var k = Keys.standard
    check(k.action(ev(36, [], "\r")) == .paste && k.action(ev(76, [], "\u{3}")) == .paste, "Return and Enter paste")
    check(k.action(ev(36, .command, "\r")) == .pastePlain, "⌘Return pastes plain text")
    check(k.action(ev(36, .shift, "\r")) == nil, "⇧Return is nothing by default")
    check(k.action(ev(8, .command, "c")) == .copy && k.action(ev(51, .command)) == .delete && k.action(ev(51)) == .delete
          && k.action(ev(117)) == .delete && k.action(ev(16, .command, "y")) == .preview, "⌘C copies, ⌘⌫ ⌫ ⌦ delete, ⌘Y previews")
    check(k.action(ev(18, .command, "1")) == .pick(0, plain: false) && k.action(ev(25, .command, "9")) == .pick(8, plain: false)
          && k.action(ev(18, .option, "1")) == nil, "⌘1 … ⌘9 pick, ⌥1 does not")
    check(k.action(ev(19, [.command, .option], "2")) == nil, "⌥⌘2 is not a pick")
    k.plain = .shift
    check(k.action(ev(36, .shift, "\r")) == .pastePlain && k.action(ev(36, .command, "\r")) == nil && k.action(ev(19, [.command, .shift])) == .pick(1, plain: true),
          "plain modifier ⇧: ⇧Return plain, ⇧⌘2 picks the second as plain text")
    k.plain = .fn
    check(k.action(ev(76, [.function])) == .pastePlain && k.action(ev(36, [.function])) == .pastePlain && k.action(ev(36)) == .paste,
          "plain modifier Fn: Fn-Return (Enter) plain, Return pastes")
    k = .standard; k.pick = .option
    check(k.action(ev(20, .option, "£")) == .pick(2, plain: false) && k.action(ev(20, .command, "3")) == nil, "Quick Pick with ⌥")
    k = .standard; k.paste = HotKey(code: 35, mods: 256); k.copy = .returnKey   // ⌘P pastes, Return copies
    check(k.action(ev(35, .command, "p")) == .paste && k.action(ev(36, [], "\r")) == .copy && k.action(ev(35, [.command, .command])) == .paste,
          "keys swapped: ⌘P pastes, Return copies")
    check(isTextEditingKey(ev(0, [], "a")) && isTextEditingKey(ev(51)) && isTextEditingKey(ev(8, .command, "c")) && isTextEditingKey(ev(49, [], " "))
          && !isTextEditingKey(ev(36, [], "\r")) && !isTextEditingKey(ev(18, .command, "1")) && !isTextEditingKey(ev(16, .command, "y")),
          "text editing keys stay the search field's; Return, ⌘1, ⌘Y do not")
    // Stored, read back.
    let dir = tmpDir("keys")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (st, _) = seeded(dir, mockSpecs())
    check(st.keys == .standard, "no setting: the defaults")
    var nk = Keys.standard; nk.plain = .option; nk.pick = .control; nk.delete = HotKey(code: 2, mods: 256)
    st.keys = nk
    check(st.keys == nk, "the keys stored and read back")
    st.keys = .standard
    // Clashes.
    check(keyClashes(show: .standard, queue: .queue, keys: .standard).isEmpty, "the defaults clash with nothing: \(keyClashes(show: .standard, queue: .queue, keys: .standard))")
    var ck = Keys.standard; ck.copy = .standard
    let c1 = keyClashes(show: .standard, queue: .queue, keys: ck)
    check(c1.count == 1 && c1[0].contains("Show History") && c1[0].contains("Copy"), "Copy on ⌥⌘C clashes with Show History: \(c1)")
    check(keyClashes(show: .standard, queue: .standard, keys: .standard).first?.contains("Paste Queue") == true, "the two hot keys the same: said")
    ck = .standard; ck.preview = HotKey(code: 0, mods: 256)
    check(keyClashes(show: .standard, queue: .queue, keys: ck).first?.contains("Select All") == true, "Preview on ⌘A clashes with Select All")
    ck = .standard; ck.copy = HotKey(code: 18, mods: 256)
    check(keyClashes(show: .standard, queue: .queue, keys: ck).first?.contains("Quick Pick 1") == true, "Copy on ⌘1 clashes with Quick Pick")
    ck = .standard; ck.paste = HotKey(code: 36, mods: 256)
    check(keyClashes(show: .standard, queue: .queue, keys: ck).contains { $0.contains("needs a modifier") }, "⌘Return with a ⌘ plain modifier: said")

    // The panel, its real window never shown: Return pastes (writes, then hands over to the paster), ⌘Return plain,
    // Quick Pick, the digits, «/» kinds.
    let pc = PanelController(store: st, monitor: nil, onScreen: true)
    let pb = NSPasteboard(name: .init("com.geragaraza.copia.test.paste.\(getpid())"))
    pc.pasteboard = pb
    var pastes = 0
    pc.pasteInto = { _ in pastes += 1 }
    var copies: [([Int64], Bool)] = []
    pc.copied = { copies.append(($0, $1)) }
    func press(_ e: NSEvent) {
        let w = pc.window!
        let r = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: e.modifierFlags, timestamp: 0, windowNumber: w.windowNumber,
                                 context: nil, characters: e.characters ?? "", charactersIgnoringModifiers: e.charactersIgnoringModifiers ?? "",
                                 isARepeat: false, keyCode: e.keyCode)!
        if r.modifierFlags.contains(.command) && w.performKeyEquivalent(with: r) { return }
        w.sendEvent(r)
    }
    pc.view.setFrameSize(NSSize(width: panelSize.width, height: panelSize.height))
    pc.window!.makeFirstResponder(pc.view)
    let first = pc.shown[0]
    press(ev(36, [], "\r"))
    check(pastes == 1 && pb.pasteboardItems?.count ?? 0 >= 1 && pc.sel.order == [first.id] && copies.isEmpty,
          "Return with nothing picked: the first row written and pasted, past the queue (\(pastes), \(copies.count))")
    let rich = pc.shown.firstIndex { $0.kind == .text }!
    pc.sel.clear(); pc.sel.click(pc.shown[rich].id); pc.selectionChanged()
    press(ev(36, .command, "\r"))
    check(pastes == 2 && pb.pasteboardItems?.count == 1 && pb.pasteboardItems?.first?.types.contains(.rtf) == false
          && pb.string(forType: .string) == Copia.plainText([pc.shown[rich]]), "⌘Return: the plain text alone, pasted")
    pc.sel.clear(); pc.selectionChanged()
    press(ev(8, .command, "c"))
    check(pastes == 2 && copies.isEmpty, "⌘C with nothing picked: nothing")
    let vis = pc.visibleEntryIDs()
    check(vis.count == min(9, pc.shown.count) || vis.count >= 7, "rows in sight: \(vis.count)")
    press(ev(19, .command, "2"))
    check(pastes == 3 && pc.sel.order == [vis[1]], "⌘2 pastes the second row in sight")
    pc.sel.clear(); pc.sel.click(vis[2]); pc.selectionChanged()
    press(ev(8, .command, "c"))
    check(copies.count == 1 && copies[0].0 == [vis[2]] && !copies[0].1, "⌘C copies and joins the queue")
    pc.sel.clear(); pc.sel.click(pc.shown[rich].id); pc.selectionChanged()
    pc.menuCopyPlain()
    check(copies.count == 2 && copies[1].1, "Copy as Plain Text joins the queue as plain text")
    // The digits: the modifier alone shows them; the footer does not change.
    let footer = pc.view.facts.stringValue
    pc.flagsChanged([.command, .option])
    pc.flagsChanged(.command)
    check(!pc.showsDigits, "still held from the hot key: not at once (⌥ of ⌥⌘C let go first)")
    _ = wait(0.4) { pc.showsDigits }
    check(pc.showsDigits && pc.view.facts.stringValue == footer, "⌘ held: the numbers; the footer stays as it was")
    pc.flagsChanged([])
    check(!pc.showsDigits, "all let go: gone")
    pc.flagsChanged(.command)
    check(pc.showsDigits && pc.view.facts.stringValue == footer, "⌘ pressed fresh: the numbers in the same event, the footer unchanged")
    pc.flagsChanged([.command, .shift])
    check(!pc.showsDigits, "another modifier added: gone")
    // «/»: the kinds as suggestions, Return picks one as a token, ⌫ on the empty field takes it away.
    pc.focusSearch()
    pc.view.field.stringValue = "/"; pc.filter()
    check(pc.suggesting && pc.rows.count == 7, "«/» offers the seven kinds (\(pc.rows.count))")
    pc.view.field.stringValue = "/im"; pc.filter()
    check(pc.suggestions == [.images], "«/im»: Images")
    press(ev(36, [], "\r"))
    check(pc.kindToken == .images && pc.query.isEmpty && !pc.suggesting && pc.shown.allSatisfy { inPane($0, .images) } && !pc.shown.isEmpty
          && pastes == 3 && !pc.view.token.isHidden, "Return picks Images: a token, only images, nothing pasted (\(pc.shown.count))")
    _ = pc.control(pc.view.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    check(pc.kindToken == nil && pc.view.token.isHidden && pc.shown.count == st.entries().count, "⌫ on the empty search: the token goes")
    pc.view.field.stringValue = "/"; pc.filter()
    press(ev(125, [], "\u{F701}")); press(ev(125, [], "\u{F701}"))
    check(pc.suggestion == 2, "↓ ↓ moves among the kinds")
    pc.mouseDown(row: 4, flags: [], clicks: 1)
    check(pc.kindToken == .audio, "a click picks a kind (the fifth, Audio)")
    pc.view.field.stringValue = "/usr/bin"; pc.filter()
    check(!pc.suggesting, "«/usr/bin» matches no kind: a plain search")
    pc.escape()
    check(pc.kindToken == nil && pc.query.isEmpty, "Esc clears the token with the search")
    // Kind-only items in their fixed slot, nothing else moves.
    func rowOf(_ k: Kind) -> Int { pc.rows.firstIndex { if case .entry(let i) = $0 { return pc.shown[i].kind == k }; return false }! }
    pc.sel.clear()
    let lm = pc.contextMenu(row: rowOf(.link))!.items.map(\.title)
    check(lm == ["Paste", "Paste as Plain Text", "", "Copy", "Copy as Plain Text", "", "Share…", "Open With", "Open in Browser", "", "Delete"], "a link: Open in Browser after Open With \(lm)")
    pc.sel.clear()
    let fm = pc.contextMenu(row: rowOf(.files))!
    check(fm.items.map(\.title) == ["Paste", "Paste as Plain Text", "", "Copy", "Copy as Plain Text", "", "Share…", "Open With", "Show in Finder", "", "Delete"]
          && fm.items[8].keyEquivalent == "r" && fm.items[8].keyEquivalentModifierMask == .command, "files: Show in Finder ⌘R in its slot \(fm.items.map(\.title))")
    pc.sel.clear()
    let im = pc.contextMenu(row: rowOf(.image))!
    check(im.items.count == 10 && !im.items[1].isEnabled && !im.items[4].isEnabled && im.items[0].isEnabled, "a picture: the same order, the plain-text items off")
    // The paster: without the permission, the explanation, no keys.
    let p = Paster()
    var denied = 0, posted = 0
    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    p.allowed = { false }; p.fresh = { false }; p.denied = { denied += 1 }; p.post = { _ in posted += 1 }
    p.paste(into: dock)
    _ = wait(1) { denied == 1 }
    check(denied == 1 && posted == 0, "no Accessibility: explained, nothing sent")
    // Turned on while Copia runs: Copia's own answer stays no, a fresh copy says yes, and the paste goes on.
    // (the app already in front, so nothing is brought forward; the post is counted, not sent)
    p.fresh = { true }
    p.paste(into: NSWorkspace.shared.frontmostApplication)
    _ = wait(2) { posted == 1 }
    check(denied == 1 && (posted == 1 || NSWorkspace.shared.frontmostApplication == .current) && Paster.allowedFresh, "granted after launch: the fresh copy's yes, the ⌘V sent")
    Paster.allowedFresh = false; posted = 0
    // A password's plain text keeps the concealed mark; a global key of ⌘ alone is refused, ⇧⌘ taken.
    let cpb = NSPasteboard(name: .init("com.geragaraza.copia.test.conceal\(getpid())"))
    Copia.writePlain("secret", concealed: true, to: cpb)
    let concealedKept = cpb.types?.contains(.concealed) == true
    Copia.writePlain("plain", to: cpb)
    check(concealedKept && cpb.types?.contains(.concealed) == false, "concealed copies stay marked, others not")
    cpb.releaseGlobally()
    func ev(_ f: NSEvent.ModifierFlags) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)! }
    check(HotKey.from(ev(.command)) == nil && HotKey.from(ev([.command, .shift])) != nil && HotKey.from(ev([.control, .option])) != nil,
          "global keys: ⌘V refused, ⇧⌘V and ⌃⌥V taken")
    check(Paster.freshCopy(["0", "1"]) == 2 && Paster.freshCopy(["x"]) == 2 && Paster.freshCopy(["-5"]) == 2 && Paster.freshCopy([]) == 2,
          "--paste-to takes one process number, nothing else")
    p.allowed = { true }
    p.paste(into: .current); p.paste(into: nil)
    _ = wait(0.2) { false }
    check(posted == 0, "never into Copia itself or nowhere")
    pb.releaseGlobally()

    // The big window: Return copies (window stays), Esc clears the search then the selection, ⌫ deletes, copies join.
    let b = BrowserController(store: st, monitor: nil)
    b.pasteboard = NSPasteboard(name: .init("com.geragaraza.copia.test.bk\(getpid())"))
    var bc: [([Int64], Bool)] = []
    b.copied = { bc.append(($0, $1)) }
    b.open(pane: .text); b.open(pane: .all)
    let ids = b.shown.filter { $0.kind == .text }.map(\.id)
    b.selectionChanged(to: [ids[0]])
    check(b.itemsKey(ev(36, [], "\r")) && bc.count == 1 && bc[0].0 == [ids[0]] && !bc[0].1, "big window: Return copies, and the copy joins the queue")
    check(b.itemsKey(ev(36, .command, "\r")) && bc.count == 2 && bc[1].1, "⌘Return copies plain text, joining as plain text")
    b.query = "zzz-none"; b.reload()
    check(b.itemsKey(ev(53, [], "\u{1b}")) && b.query.isEmpty, "Esc clears the search first")
    b.selectionChanged(to: [ids[1]])
    check(b.itemsKey(ev(53, [], "\u{1b}")) && b.order.isEmpty, "then the selection")
    check(!b.itemsKey(ev(0, [], "a")), "a letter does nothing")
    b.selectionChanged(to: [ids[1]])
    let before = st.entries().count
    check(b.itemsKey(ev(51)) && st.entries().count == before - 1, "⌫ deletes as ⌘⌫")
    let menu = b.itemMenu()
    check(menu.items.map(\.title).prefix(5) == ["Paste", "Paste as Plain Text", "", "Copy", "Copy as Plain Text"], "the big window's menu is the panel's: \(menu.items.map(\.title))")
    b.pasteboard.releaseGlobally()
}

/// Dragging out: one file per picked thing, in pick order (0.4's recording: two items became one merged text file).
func dragTests() {
    let dir = tmpDir("drag")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (st, ids) = seeded(dir, mockSpecs())
    let all = st.entries()
    func e(_ id: Int64) -> Entry { all.first { $0.id == id }! }
    let two = Drag.items([e(ids[7]), e(ids[9])], store: st)
    check(two.count == 2 && two.allSatisfy { $0.types.contains(.fileURL) && $0.types.contains(.string) }, "two texts: two files, each with its text")
    let names = two.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent }
    check(names.count == 2 && names.allSatisfy { $0.hasSuffix(".txt") || $0.hasSuffix(".rtf") } && Set(names).count == 2, "two different text files: \(names)")
    check(two.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "the files exist")
    let twelve = Drag.items([e(ids[5])], store: st)
    check(twelve.count == 12, "twelve Finder files go out as twelve: \(twelve.count)")
    let mixed = Drag.items([e(ids[12]), e(ids[8]), e(ids[13])], store: st)
    check(mixed.count == 1 + 1 + 3, "an image, a link, three images: five items (\(mixed.count))")
    check(mixed[1].string(forType: .fileURL)?.hasSuffix(".webloc") == true && mixed[1].string(forType: .URL) == "https://geragaraza.com", "a link is a .webloc with its address")
    check(mixed.allSatisfy { $0.types.contains(.own) }, "marked as ours: a drag is never recorded as a copy")
}

/// 0.5, his review of 0.4: an item copied again, from anywhere or from Copia itself, moves to the top; one entry, not twins.
func orderTests() {
    let dir = tmpDir("order")
    defer { try? FileManager.default.removeItem(at: dir) }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let (st, ids) = seeded(dir, [(textSnap("alpha", app: "com.apple.Notes"), t0), (textSnap("beta"), t0.addingTimeInterval(60)),
                                 (imageSnap(testImage("P", (0.2, 0.4, 0.8))), t0.addingTimeInterval(120)),
                                 (Snapshot(items: [[Rep(type: furl, data: Data("file:///tmp/a.txt".utf8))], [Rep(type: furl, data: Data("file:///tmp/b.txt".utf8))]],
                                           source: "com.apple.finder"), t0.addingTimeInterval(180))])
    check(st.entries().map(\.id) == ids.reversed(), "newest first")
    // The same text from Safari, now with its HTML and RTF: the same entry, on top, with Safari's richer types.
    let rich = Snapshot(items: [[Rep(type: str, data: Data("alpha".utf8)), Rep(type: html, data: Data("<b>alpha</b>".utf8))]], source: "com.apple.Safari")
    let (e1, it1) = prepare(rich, dir: dir, at: t0.addingTimeInterval(300))!
    let id1 = st.add(e1, it1)
    check(id1 == ids[0], "the same text from another app is the same entry")
    check(st.entries().first?.id == ids[0] && st.entries().count == 4, "copied again, it moves to the top: \(st.entries().map(\.id))")
    check(st.reps(ids[0]).first?.contains { $0.type == html } == true, "the newer copy's types replace the old ones")
    check(st.entries().first?.app == "com.apple.Safari", "the app of the newer copy")
    // The same picture again (another app, same pixels), the same two files again.
    let (e2, it2) = prepare(imageSnap(testImage("P", (0.2, 0.4, 0.8)), app: "com.apple.Preview"), dir: dir, at: t0.addingTimeInterval(400))!
    check(st.add(e2, it2) == ids[2], "the same picture is the same entry")
    let (e3, it3) = prepare(Snapshot(items: [[Rep(type: furl, data: Data("file:///tmp/a.txt".utf8)), Rep(type: str, data: Data("a.txt".utf8))],
                                             [Rep(type: furl, data: Data("file:///tmp/b.txt".utf8))]], source: "com.apple.finder"), dir: dir, at: t0.addingTimeInterval(500))!
    check(st.add(e3, it3) == ids[3], "the same files are the same entry")
    let (e4, it4) = prepare(Snapshot(items: [[Rep(type: furl, data: Data("file:///tmp/b.txt".utf8))], [Rep(type: furl, data: Data("file:///tmp/a.txt".utf8))]],
                                     source: "com.apple.finder"), dir: dir, at: t0.addingTimeInterval(510))!
    check(st.add(e4, it4) != ids[3], "the same files in another order are another copy")
    check(st.entries().count == 5, "no twins: \(st.entries().count)")
    // Copied back from Copia: the picked move to the top, keeping their order among themselves.
    let before = st.entries().map(\.id)
    st.touch([before[4], before[2]], now: t0.addingTimeInterval(1000))
    let after = st.entries().map(\.id)
    check(Array(after.prefix(2)) == [before[2], before[4]], "used entries go to the top in the order they had: \(after) from \(before)")
    check(st.entries().first.map { abs($0.copied.timeIntervalSince1970 - (t0.timeIntervalSince1970 + 1000)) < 0.01 } == true, "the date shown is the last use")
    st.touch(after, now: t0.addingTimeInterval(2000))
    check(st.entries().map(\.id) == after, "⌘A ⌘C lifts the whole list without shuffling it")
    // Recently Deleted: a copy of the same thing brings it back, to the top.
    st.delete([ids[1]])
    let (e5, it5) = prepare(textSnap("beta", app: "com.apple.TextEdit"), dir: dir, at: t0.addingTimeInterval(3000))!
    check(st.add(e5, it5) == ids[1] && st.entries().first?.id == ids[1] && st.entries(deleted: true).isEmpty, "copied again, a deleted entry comes back on top")
    // An edited text is its new text: copying the old text again makes a new entry, the edit stays.
    st.edit(ids[1], plain: "beta, edited", rtf: nil)
    let (e6, it6) = prepare(textSnap("beta"), dir: dir, at: t0.addingTimeInterval(3100))!
    check(st.add(e6, it6) != ids[1], "the original text of an edited entry is a copy of its own")
    let (e7, it7) = prepare(textSnap("beta, edited"), dir: dir, at: t0.addingTimeInterval(3200))!
    check(st.add(e7, it7) == ids[1], "the edited text copied elsewhere and back is the edited entry")

    // A store of 0.4 (version 2, no content keys) with twins opens merged: the newest copy stays, with the latest date.
    let odir = tmpDir("order-old")
    defer { try? FileManager.default.removeItem(at: odir) }
    do {
        let (o, oids) = seeded(odir, [(textSnap("same", app: "com.apple.Notes"), t0), (textSnap("other"), t0.addingTimeInterval(10))])
        _ = o
        _ = oids
    }
    var db: OpaquePointer?
    sqlite3_open(odir.appendingPathComponent("copia.sqlite").path, &db)
    sqlite3_exec(db, """
        INSERT INTO entries(copied, app, kind, title, text, bytes, count, width, height, thumb, digest, concealed)
          SELECT copied + 100, 'com.apple.Safari', kind, title, text, bytes, count, width, height, thumb, 'twin', concealed FROM entries WHERE text = 'same';
        INSERT INTO reps(entry, item, type, data, file) SELECT (SELECT MAX(id) FROM entries), item, type, data, file FROM reps
          WHERE entry = (SELECT id FROM entries WHERE text = 'same' AND digest != 'twin');
        UPDATE entries SET ckey = NULL; PRAGMA user_version = 2;
        """, nil, nil, nil)
    sqlite3_close(db)
    let o2 = try! Store(dir: odir)
    let left = o2.entries()
    check(left.count == 2 && left.filter { $0.text == "same" }.count == 1, "0.4's twins merged on opening: \(left.map(\.text))")
    check(left.first?.text == "same" && left.first?.app == "com.apple.Safari", "the newest twin stays, on top")
    check(left.allSatisfy { $0.key != nil }, "every kept entry has its content key")
}

/// The big window's logic without a screen: panes, sort, the pick order, delete, Recently Deleted, the hot key text.
func browserTests() {
    let dir = tmpDir("browser")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (st, ids) = seeded(dir, mockSpecs())
    let b = BrowserController(store: st, monitor: nil)
    b.pasteboard = NSPasteboard(name: .init("com.geragaraza.copia.test.b\(getpid())"))
    b.open(pane: .text); b.open(pane: .all)
    check(b.shown.count == ids.count, "All shows every entry: \(b.shown.count)")
    let count = { (p: Pane) -> Int in b.open(pane: p); return b.shown.count }
    check(count(.text) == 5, "Text: the five texts, got \(count(.text))")
    check(count(.links) == 1, "Links: one")
    check(count(.colors) == 2, "Colors: two")
    check(count(.video) == 1, "Video: the mp4 file")
    check(count(.audio) == 1, "Audio: the m4a file")
    check(count(.images) == 6, "Images: picture data and picture files, got \(count(.images))")
    check(count(.files) == 4, "Files: every Finder copy, got \(count(.files))")
    b.open(pane: .all)
    b.setSort(.size, ascending: false)
    check(zip(b.shown, b.shown.dropFirst()).allSatisfy { $0.bytes >= $1.bytes }, "sorted by size, biggest first")
    b.setSort(.date, ascending: false)
    check(zip(b.shown, b.shown.dropFirst()).allSatisfy { $0.copied >= $1.copied }, "sorted by date, newest first")
    let s = b.shown.map(\.id)
    b.selectionChanged(to: [s[3]]); b.selectionChanged(to: [s[3], s[0]]); b.selectionChanged(to: [s[3], s[0], s[5]])
    check(b.order == [s[3], s[0], s[5]], "picks keep their order: \(b.order)")
    b.selectionChanged(to: [s[0], s[5]])
    check(b.order == [s[0], s[5]], "an unpicked one leaves the order")
    b.selectAll(nil)
    check(b.order == [s[0], s[5]] + b.shown.sorted { $0.copied < $1.copied }.map(\.id).filter { ![s[0], s[5]].contains($0) },
          "⌘A in the big window: the picks keep their numbers, the rest in the order of copying")
    b.selectionChanged(to: []); b.selectAll(nil)
    check(b.order == b.shown.sorted { $0.copied < $1.copied }.map(\.id), "⌘A with nothing picked: the order of copying, oldest first")
    b.selectionChanged(to: [s[1], s[2]])
    b.copy(nil)
    check(b.pasteboard.pasteboardItems?.count ?? 0 >= 1, "⌘C writes the picks")
    b.selectionChanged(to: [s[1]])
    b.moveToRecentlyDeleted(nil)
    check(b.shown.count == ids.count - 1 && st.entries(deleted: true).map(\.id) == [s[1]], "⌘⌫ into Recently Deleted")
    check(b.order == [s[2]], "the next one takes its place")
    b.open(pane: .deleted)
    check(b.shown.map(\.id) == [s[1]], "Recently Deleted lists it")
    b.selectionChanged(to: [s[1]])
    b.putBack(nil)
    check(st.entries(deleted: true).isEmpty && st.entries().count == ids.count, "Put Back returns it")
    st.delete([s[4]]); st.erase([s[4]])
    check(!st.entries().contains { $0.id == s[4] } && !st.entries(deleted: true).contains { $0.id == s[4] }, "Delete Immediately removes it for good")
    check(HotKey.standard.text.hasPrefix("⌥⌘"), "the hot key reads ⌥⌘C: \(HotKey.standard.text)")
    check(HotKey("8:2304") == HotKey(code: 8, mods: 2304), "a stored hot key reads back")
    b.pasteboard.releaseGlobally()
}

// MARK: capture

/// Writes `write` to `pb` and waits for the monitor; returns what it captured (nil = nothing within `timeout`).
func captured(_ m: Monitor, _ pb: NSPasteboard, timeout: Double = 1.5, _ write: () -> Void) -> (Snapshot?, Double) {
    var got: Snapshot?
    m.onCopy = { got = $0 }
    let t0 = CFAbsoluteTimeGetCurrent()
    write()
    _ = wait(timeout) { got != nil }
    return (got, CFAbsoluteTimeGetCurrent() - t0)
}

func captureTests(_ pb: NSPasteboard, general: Bool) {
    let m = Monitor(pb)
    m.start()
    let dir = tmpDir("capture")
    var lat: [Double] = []

    // Twelve files from Finder = one entry with twelve items.
    let files = (1...12).map { i -> URL in
        let u = dir.appendingPathComponent("file \(i).txt"); try! Data("file \(i)".utf8).write(to: u); return u }
    var (s, t) = captured(m, pb) { pb.clearContents(); pb.writeObjects(files as [NSURL]) }
    lat.append(t)
    check(s?.items.count == 12 && s!.items.allSatisfy { $0.contains { $0.type == furl } }, "12 files = one copy of 12 items (\(s?.items.count ?? 0))")
    check(s.map { $0.items.flatMap { $0 }.allSatisfy { !isSynthesized($0.type) } } == true, "no system-made aliases kept")
    if let s, let (e, _) = prepare(s, dir: dir) {
        check(e.kind == .files && e.count == 12 && e.title == counted(12, "object|objects"), "files entry \(e.title)")
    }

    // Rich text: every type kept.
    (s, t) = captured(m, pb) {
        pb.clearContents()
        pb.writeObjects([item([(rtf, Data("{\\rtf1 {\\b bold} text}".utf8)), (html, Data("<b>bold</b> text".utf8)), (str, Data("bold text".utf8))])])
    }
    lat.append(t)
    check(Set(s?.items.first?.map(\.type) ?? []).isSuperset(of: [rtf, html, str]), "rich text: RTF, HTML and text kept \(s?.items.first?.map(\.type) ?? [])")

    // Several images in one copy: every one kept (ClipBook kept the first, Maccy let the last overwrite).
    let imgs = [testImage("A", (0.9, 0.2, 0.2)), testImage("B", (0.2, 0.7, 0.2)), testImage("C", (0.2, 0.3, 0.9))]
    (s, t) = captured(m, pb) { pb.clearContents(); pb.writeObjects(imgs.map { item([(png, $0)]) }) }
    lat.append(t)
    if let s, let (e, items) = prepare(s, dir: dir) {
        check(e.kind == .image && items.count == 3 && Set(items.compactMap { $0.first?.file }).count == 3, "three images = one entry of three")
    } else { check(false, "three images captured") }

    // Writes no person made are skipped; a password manager's copy is kept, marked concealed.
    for marker in ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "de.petermaurer.TransientPasteboardType"] {
        (s, _) = captured(m, pb, timeout: 0.8) { pb.clearContents(); pb.writeObjects([item([(str, Data("secret".utf8)), (marker, Data())])]) }
        check(s == nil, "\(marker) skipped")
    }
    (s, t) = captured(m, pb) { pb.clearContents(); pb.writeObjects([item([(str, Data("hunter2".utf8)), ("org.nspasteboard.ConcealedType", Data())])]) }
    check(s?.concealed == true, "concealed (password) kept")

    // Our own write: skipped by its count and by the marker inside the item.
    (s, _) = captured(m, pb, timeout: 0.8) {
        pb.clearContents(); pb.writeObjects([item([(str, Data("ours".utf8)), (NSPasteboard.PasteboardType.own.rawValue, Data("1".utf8))])])
    }
    check(s == nil, "own write skipped by its marker")
    (s, _) = captured(m, pb, timeout: 0.8) { pb.clearContents(); pb.setString("ours too", forType: .string); m.ownCount = pb.changeCount }
    check(s == nil, "own write skipped by its count")

    // Chromium's way: the count moves on an empty clear, the content comes later without a new count.
    (s, t) = captured(m, pb, timeout: 4) {
        pb.clearContents()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { pb.setString("late text", forType: .string) }
    }
    check(s.flatMap { String(data: $0.items[0][0].data!, encoding: .utf8) } == "late text", "empty read retried: late write caught after \(String(format: "%.2f", t)) s")

    // The copying app's own declaration wins over the app in front.
    (s, _) = captured(m, pb) { pb.clearContents(); pb.writeObjects([item([(str, Data("from KeePassXC".utf8)), ("org.nspasteboard.source", Data("org.keepassxc.keepassxc".utf8))])]) }
    check(s?.source == "org.keepassxc.keepassxc", "source from org.nspasteboard.source")

    m.stop()
    print(String(format: "capture latency (write → captured): %@ s", lat.map { String(format: "%.2f", $0) }.joined(separator: " / ")))
    try? FileManager.default.removeItem(at: dir)
}

// MARK: copy

func copyTests(_ pb: NSPasteboard) {
    let dir = tmpDir("copy")
    let now = Date()
    let imgs = [testImage("1", (0.9, 0.2, 0.2)), testImage("2", (0.2, 0.7, 0.2)), testImage("3", (0.2, 0.3, 0.9))]
    let files = (1...3).map { i -> URL in let u = dir.appendingPathComponent("doc \(i).pdf"); try! Data("x".utf8).write(to: u); return u }
    let filesSnap = Snapshot(items: files.map { [Rep(type: furl, data: Data($0.absoluteString.utf8))] }, source: "com.apple.finder")
    let rich = Snapshot(items: [[Rep(type: rtf, data: Data("{\\rtf1 {\\b bold}}".utf8)), Rep(type: html, data: Data("<b>bold</b>".utf8)),
                                 Rep(type: str, data: Data("bold".utf8))]], source: "com.apple.TextEdit")
    var specs: [(Snapshot, Date)] = imgs.enumerated().map { (imageSnap($1), now.addingTimeInterval(Double($0))) }
    specs += [(textSnap("first"), now.addingTimeInterval(10)), (textSnap("second"), now.addingTimeInterval(11)),
              (textSnap("third"), now.addingTimeInterval(12)), (filesSnap, now.addingTimeInterval(13)), (rich, now.addingTimeInterval(14))]
    let (st, ids) = seeded(dir, specs)
    func sel(_ k: [Int]) -> [(Entry, [[Rep]])] { k.map { i in (st.entries().first { $0.id == ids[i] }!, st.reps(ids[i])) } }
    let own = NSPasteboard.PasteboardType.own.rawValue

    // Three images picked 3, 1, 2: three items, each a real file + PNG + TIFF, in the picked order.
    var r = Copia.write(sel([2, 0, 1]), store: st, to: pb)
    var ty = types(pb)
    check(ty.count == 3 && ty.allSatisfy { Set($0).isSuperset(of: [furl, png, tiff, own]) }, "3 images = 3 items of file URL + PNG + TIFF \(ty)")
    check(r.urls == 3 && r.expected == 3, "file URLs verified after the write (\(r.urls)/\(r.expected))")
    let urls = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
    let order = urls.compactMap { try? Data(contentsOf: $0) }.map(sha)
    check(order == [2, 0, 1].map { sha(imgs[$0]) }, "images arrive in the picked order, as real files")
    check(urls.allSatisfy { $0.path.hasPrefix(dir.appendingPathComponent("paste").path) } && urls.map(\.lastPathComponent) == ["\(L("Image")) 1.png", "\(L("Image")) 2.png", "\(L("Image")) 3.png"],
          "temporary files in paste/, readable names \(urls.map(\.lastPathComponent))")
    let tiffBack = pb.pasteboardItems?.first?.data(forType: .tiff)
    check(tiffBack.flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 400, "TIFF made on request")
    check(pb.pasteboardItems?.allSatisfy { $0.string(forType: .source) == (Bundle.main.bundleIdentifier ?? "com.geragaraza.copia") } == true, "source marked")

    // Three texts: one item, joined by a new line, in the picked order.
    r = Copia.write(sel([5, 3, 4]), store: st, to: pb)
    check(types(pb).count == 1 && pb.string(forType: .string) == "third\nfirst\nsecond", "texts joined into one item: \(pb.string(forType: .string) ?? "nil")")

    // One rich text: kept rich.
    r = Copia.write(sel([7]), store: st, to: pb)
    ty = types(pb)
    check(ty.count == 1 && Set(ty[0]).isSuperset(of: [rtf, html, str, own]), "one rich text keeps RTF and HTML \(ty)")

    // A Finder copy of three files: three items with their URLs, as Finder wrote them.
    r = Copia.write(sel([6]), store: st, to: pb)
    check(((pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []) == files, "files go back as the same file URLs")

    // Text + image + files: one write, one item per thing, the text where it was picked.
    r = Copia.write(sel([3, 0, 6]), store: st, to: pb)
    ty = types(pb)
    check(ty.count == 5 && ty[0].contains(str) && !ty[0].contains(furl) && ty[1].contains(png) && ty[2...].allSatisfy { $0.contains(furl) },
          "mixed selection: 5 items in order \(ty)")
    check(ty.allSatisfy { $0.contains(own) } && ty.count == (pb.pasteboardItems?.count ?? 0), "the marker sits inside the items, no item of its own")

    // A picture copied with its file (screenshot tools, Pixlift: file URL + PNG + TIFF) is read without the TIFF;
    // it goes back with one, made on request, and another process gets it (Qt reads images only from TIFF).
    let shotFile = dir.appendingPathComponent("shot.png"); try! imgs[1].write(to: shotFile)
    let withFile = Snapshot(items: [[Rep(type: furl, data: Data(shotFile.absoluteString.utf8)), Rep(type: png, data: imgs[1])]], source: "com.geragaraza.pixlift")
    let (wfe, wfi) = prepare(withFile, dir: dir)!
    let wfid = st.add(wfe, wfi)
    r = Copia.write([(st.entries().first { $0.id == wfid }!, st.reps(wfid))], store: st, to: pb)
    ty = types(pb)
    check(ty.count == 1 && Set(ty[0]).isSuperset(of: [furl, png, tiff]), "image with its file: file URL + PNG + TIFF \(ty)")
    let reader = Process()
    reader.executableURL = URL(fileURLWithPath: argv[0])
    reader.arguments = ["readtiff", pb.name.rawValue]
    let rpipe = Pipe(); reader.standardOutput = rpipe
    try! reader.run()
    _ = wait(5) { !reader.isRunning }   // our run loop must turn: the TIFF is made here when the other process asks
    let answer = String(data: rpipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    check(answer == "400", "another process reads the TIFF: \(answer ?? "nil") px wide")
    // The two-image copy of the trial shows a stack of its pictures, not a document icon (drawn: renders).

    // The monitor does not take our write back into the history.
    let m = Monitor(pb)
    var got = false
    m.onCopy = { _ in got = true }
    m.start()
    let w = Copia.write(sel([0, 1]), store: st, to: pb)
    m.ownCount = w.count
    _ = wait(0.8) { got }
    check(!got, "our copy is not recorded again")
    m.stop()
    try? FileManager.default.removeItem(at: dir)
}

// MARK: the general pasteboard, his content kept

func general() {
    let pb = NSPasteboard.general
    // Saved as data, every item and type, and put back after; if anything else wrote meanwhile (he copied), his new
    // copy wins and nothing is put back.
    let saved: [[(String, Data)]] = (pb.pasteboardItems ?? []).map { it in it.types.compactMap { t in it.data(forType: t).map { (t.rawValue, $0) } } }
    print("saved his clipboard: \(saved.count) items")
    var last = pb.changeCount
    func mark() { last = pb.changeCount }
    defer {
        if pb.changeCount == last {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved.map(item)) }
            print("restored his clipboard: \(pb.pasteboardItems?.count ?? 0) items")
        } else { print("the clipboard changed during the test: left as it is") }
    }
    let dir = tmpDir("general")
    let imgs = [testImage("1", (0.9, 0.2, 0.2)), testImage("2", (0.2, 0.7, 0.2)), testImage("3", (0.2, 0.3, 0.9))]
    let (st, ids) = seeded(dir, imgs.enumerated().map { (imageSnap($1), Date().addingTimeInterval(Double($0))) })
    let r = Copia.write(ids.map { id in (st.entries().first { $0.id == id }!, st.reps(id)) }, store: st, to: pb)
    mark()
    let ty = types(pb)
    check(ty.count == 3 && ty.allSatisfy { Set($0).isSuperset(of: [furl, png, tiff]) }, "general: 3 items of file URL + PNG + TIFF \(ty)")
    check(r.urls == 3, "general: all 3 file URLs present (\(r.urls)/\(r.expected)); 1 means the command sandbox")
    print("item layout on the general pasteboard:"); for (i, t) in ty.enumerated() { print("  item \(i): \(t.joined(separator: ", "))") }

    // Capture from the general pasteboard: twelve files.
    let m = Monitor(pb)
    m.start()
    let files = (1...12).map { i -> URL in let u = dir.appendingPathComponent("f\(i).txt"); try! Data("\(i)".utf8).write(to: u); return u }
    let (s, t) = captured(m, pb) { pb.clearContents(); pb.writeObjects(files as [NSURL]); mark() }
    check(s?.items.count == 12, "general: 12 files captured as one copy of 12 (\(s?.items.count ?? 0)) in \(String(format: "%.2f", t)) s")
    m.stop()
    if #available(macOS 15.4, *) {
        let b = pb.accessBehavior
        print("NSPasteboard.general.accessBehavior = \(b.rawValue) (0 default, 1 ask, 2 alwaysAllow, 3 alwaysDeny)")
    }
    try? FileManager.default.removeItem(at: dir)
}

// MARK: render

/// The approved mockup's content (round 3), newest last; the panel's renders and the trials' seed use it.
func mockSpecs() -> [(Snapshot, Date)] {
    // COPIA_RES: a copy readable by the agents' own session (cs), whose user can't enter his home.
    let res = ProcessInfo.processInfo.environment["COPIA_RES"] ?? "/Users/harazha/.local/share/clipboard/mock/res/"
    let day = Calendar.current.startOfDay(for: Date())
    func at(_ h: Int, _ m: Int, _ d: Int = 0) -> Date { day.addingTimeInterval(Double(d * 86400 + h * 3600 + m * 60)) }
    func txt(_ n: String) -> String { ((try? String(contentsOfFile: res + "text/\(n).txt", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func shot(_ n: String) -> Data { try! Data(contentsOf: URL(fileURLWithPath: res + "shots/" + n)) }
    let video = URL(fileURLWithPath: res + "video.mp4")
    let twelve = (0..<12).map { URL(fileURLWithPath: res + (["bg-0.jpg", "bg-1.jpg", "aer_60.jpg", "img_Mac_Blue-0.jpg", "img_Mac_Purple-0.jpg", "video.mp4"][$0 % 6])) }
    let link = Snapshot(items: [[Rep(type: str, data: Data("https://geragaraza.com".utf8)), Rep(type: "public.url", data: Data("https://geragaraza.com".utf8)),
                                 Rep(type: "public.url-name", data: Data("Herman Harazha".utf8))]], source: "com.apple.Safari")
    func files(_ u: [URL], _ app: String) -> Snapshot { Snapshot(items: u.map { [Rep(type: furl, data: Data($0.absoluteString.utf8))] }, source: app) }
    return [
        (imageSnap(shot("2026-11-13 18-47-05.png"), app: "com.geragaraza.pixlift"), at(18, 47, -1)),
        (textSnap(txt("karenina"), app: "com.apple.iBooksX"), at(19, 12, -1)),
        (imageSnap(shot("2026-11-14 07-11-29.png")), at(7, 11)),
        (imageSnap(shot("2026-11-14 07-11-38.png")), at(7, 11)),
        (textSnap(txt("pageB")), at(7, 16)),
        (files(twelve, "com.apple.finder"), at(7, 20)),
        (files([video], "com.apple.finder"), at(7, 22)),
        (textSnap(txt("dictated"), app: "com.geragaraza.stt"), at(7, 24)),
        (link, at(7, 27)),
        (textSnap(txt("pageA")), at(7, 28)),
        (textSnap("#0A84FF", app: "com.apple.DigitalColorMeter"), at(7, 30)),
        (textSnap(txt("pageC")), at(7, 31)),
        (imageSnap(shot("2026-11-14 07-34-26.png")), at(7, 34)),
        // The trial's faults: several images in one copy, and two picture files with their data (a stack each).
        (Snapshot(items: [[Rep(type: png, data: shot("2026-11-14 07-11-29.png"))], [Rep(type: png, data: shot("2026-11-13 18-47-05.png"))],
                          [Rep(type: png, data: shot("2026-11-14 07-34-26.png"))]], source: "com.apple.Safari"), at(7, 36)),
        (files([URL(fileURLWithPath: res + "img_Mac_Blue-0.jpg"), URL(fileURLWithPath: res + "img_iMac_Orange-0.jpg")], "com.apple.finder"), at(7, 37)),
        (files([URL(fileURLWithPath: res + "answer.m4a")], "com.apple.finder"), at(7, 38)),
        (textSnap("#34C759", app: "com.apple.DigitalColorMeter"), at(7, 39, -2)),
    ]
}


/// The approved mockup's content, through the real capture path, into a store; the panel drawn over a desktop
/// picture in one window under the desktop (seen through a solid wallpaper: see below), captured with screencapture -l.
func render(app: String, theme: String, out: String, mode: String) {
    let motion = mode == "motion"
    strings = Bundle(path: app)!
    // COPIA_RES: a copy readable by the agents' own session (cs), whose user can't enter his home.
    let res = ProcessInfo.processInfo.environment["COPIA_RES"] ?? "/Users/harazha/.local/share/clipboard/mock/res/"
    let dir = tmpDir("render")
    let links = mode == "links"   // the real Safari copies of tests/links, newest on top
    let lpb = NSPasteboard(name: .init("com.geragaraza.copia.render.\(getpid())"))
    let specs = links ? linkSpecs(lpb) : mockSpecs()
    let few = mode == "few" || links, empty = mode == "empty"
    let (st, ids) = seeded(dir, empty ? [] : links ? specs : few ? Array(specs.prefix(15).suffix(3)) : specs)
    let pc = PanelController(store: st, monitor: nil, onScreen: false)
    pc.forceFocus = true
    // Picked in the mockup's order: the dictated message, page A, page C, the screenshot.
    let rowOf = { (id: Int64) in pc.rows.firstIndex { if case .entry(let i) = $0 { return pc.shown[i].id == id }; return false }! }
    if !few && !empty {
        pc.mouseDown(row: rowOf(ids[7]), flags: [], clicks: 1)
        for k in [9, 11, 12] { pc.mouseDown(row: rowOf(ids[k]), flags: .command, clicks: 1) }
    }

    NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
    let SW: CGFloat = 1728, SH: CGFloat = 1117
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SW, height: SH), styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)   // under the wallpaper
    win.appearance = NSApp.appearance
    let root = Flipped(frame: NSRect(x: 0, y: 0, width: SW, height: SH))
    let bg = NSImageView(frame: root.bounds)
    bg.image = NSImage(contentsOfFile: res + (theme == "dark" ? "bg-1.jpg" : "bg-0.jpg"))
    bg.imageScaling = .scaleAxesIndependently
    root.addSubview(bg)
    pc.view.frame.origin = NSPoint(x: (SW - panelSize.width) / 2, y: ((SH - pc.view.frame.height) / 2).rounded())
    // COPIA_RENDER_PLACE: the panel where the app puts it on a 16-inch screen (menu bar 32 pt, Dock hidden), in this
    // flipped picture (place.swift, PlaceGrid).
    func origin(_ p: Place, _ h: CGFloat) -> NSPoint {
        let g = PlaceGrid(frame: NSRect(x: 0, y: 0, width: SW, height: SH), visible: NSRect(x: 0, y: 0, width: SW, height: SH - 32))
        return NSPoint(x: g.left(p.column), y: SH - g.top(p.row, height: h))
    }
    let place = ProcessInfo.processInfo.environment["COPIA_RENDER_PLACE"].flatMap(Place.init)
    if let place { pc.view.frame.origin = origin(place, pc.view.frame.height) }
    root.addSubview(pc.view)
    win.contentView = root
    // «Under the wallpaper» is NOT unseen: on his Mac (solid black wallpaper, 2026-11-21 08:52, his recording) the
    // pictures showed through as his desktop. Off every screen screencapture -l gets nothing («could not create image»),
    // so ./test runs the renders only on its own screen (test machine) or with COPIA_RENDER=1 when he is away.
    win.setFrame(NSRect(x: 0, y: 0, width: SW, height: SH), display: true)
    win.orderFrontRegardless()
    func shoot(_ path: String) {
        root.layoutSubtreeIfNeeded(); root.display()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(win.windowNumber)", path]; try? p.run(); p.waitUntilExit()
    }
    _ = wait(1.5) { false }
    shoot(out)
    if mode == "image" {   // an image's preview, settled (Quick Look's own view)
        Ticker.manual = true
        pc.preview.host = root
        pc.sel.clear(); pc.mouseDown(row: rowOf(ids[12]), flags: [], clicks: 1)
        pc.togglePreview()
        for _ in 0...16 { Ticker.advance(1.0 / 60) }
        _ = wait(1.5) { false }
        shoot(out)
    }
    if mode == "preview" {
        // Space on the picked row: the preview grows out of the row's picture over 250 ms (every 60 fps frame
        // shot), then a word made bold, then it closes back into the row in 130 ms.
        Ticker.manual = true
        pc.preview.host = root
        pc.sel.clear(); pc.mouseDown(row: rowOf(ids[7]), flags: [], clicks: 1)
        pc.togglePreview()
        for k in 0...16 { shoot(out.replacingOccurrences(of: ".png", with: String(format: "-o%02d.png", k))); Ticker.advance(1.0 / 60) }
        if let tv = pc.preview.textForTest {
            tv.setSelectedRange(NSRange(location: 0, length: 6)); pc.preview.toggle(.boldFontMask)
            tv.setSelectedRange(NSRange(location: 8, length: 4)); pc.preview.toggle(.italicFontMask)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            pc.preview.textDidChange(Notification(name: .init("edit")))
        }
        shoot(out.replacingOccurrences(of: ".png", with: "-edit.png"))
        pc.closePreview()
        for k in 0...9 { shoot(out.replacingOccurrences(of: ".png", with: String(format: "-c%02d.png", k))); Ticker.advance(1.0 / 60) }
    }
    if mode == "height" {
        // Typing that narrows the list: the rows change in one frame, then the bottom edge comes up in 200 ms.
        // Every 60 fps frame is drawn (time stepped by hand) and shot.
        Ticker.manual = true
        pc.fitHeightAfterFilterForTest()
        pc.view.field.stringValue = "http"
        pc.fitHeightAfterFilterForTest()
        for k in 0...14 {
            shoot(out.replacingOccurrences(of: ".png", with: String(format: "-h%02d.png", k)))
            Ticker.advance(1.0 / 60)
        }
        pc.view.field.stringValue = ""
        pc.fitHeightAfterFilterForTest()
        for k in 0...14 {
            shoot(out.replacingOccurrences(of: ".png", with: String(format: "-g%02d.png", k)))
            Ticker.advance(1.0 / 60)
        }
    }
    if mode == "keys" {
        // 0.8: Quick Pick's numbers with ⌘ held (and the footer's app and time); «/» offering the kinds, the second one
        // marked; the Images token picked with nothing typed after it.
        pc.setDigits(true)
        shoot(out.replacingOccurrences(of: ".png", with: "-digits.png"))
        pc.setDigits(false)
        pc.view.field.stringValue = "/"; pc.filter(); pc.moveSuggestion(1)
        _ = wait(0.3) { false }
        shoot(out.replacingOccurrences(of: ".png", with: "-kinds.png"))
        pc.pickKind(.images)
        _ = wait(0.3) { false }
        shoot(out.replacingOccurrences(of: ".png", with: "-token.png"))
    }
    if motion {
        // The leaving animation, 20 × slower, a frame every 1/60 s of real time: blur and growth on the glass (the
        // window's own fade is replaced by the view's here, since the picture behind shares the window).
        let d = 0.085 * 20
        pc.view.animateOut(duration: d)
        NSAnimationContext.runAnimationGroup { c in c.duration = d; c.timingFunction = CAMediaTimingFunction(name: .easeIn); pc.view.animator().alphaValue = 0 }
        let t0 = CFAbsoluteTimeGetCurrent()
        for k in 0..<6 {
            _ = wait(max(0, t0 + Double(k) * d / 5 - CFAbsoluteTimeGetCurrent())) { false }
            shoot(out.replacingOccurrences(of: ".png", with: "-out\(k).png"))
        }
    }
    try? FileManager.default.removeItem(at: dir)
    exit(0)
}


// MARK: links (run with the network denied: ./test wraps it in sandbox-exec)

/// A pasteboard as an app left it, saved by proto/mc save (tests/links/*.plist: real Safari copies, 2026-11-14).
func fixture(_ name: String) -> [[String: Data]] {
    let u = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/tests/links/\(name).plist")
    return try! PropertyListSerialization.propertyList(from: Data(contentsOf: u), format: nil) as! [[String: Data]]
}
/// Written to a private pasteboard and read back through the monitor's own read, as a copy would be.
func readBack(_ items: [[String: Data]], _ pb: NSPasteboard) -> Snapshot {
    pb.clearContents()
    pb.writeObjects(items.map { d in item(d.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }) })
    guard case .copy(var s) = Monitor.read(pb, count: pb.changeCount) else { fatalError("no copy read") }
    s.source = "com.apple.Safari"
    return s
}
func linkSpecs(_ pb: NSPasteboard) -> [(Snapshot, Date)] {
    let now = Date()
    let u8 = { (t: String) in Data(t.utf8) }
    return [
        (readBack(fixture("safari-paragraph"), pb), now.addingTimeInterval(-50)),
        (readBack([[str: u8("https://github.com"), "public.url": u8("https://github.com/"), "public.url-name": u8("https://github.com")]], pb),
         now.addingTimeInterval(-40)),   // Notes: its url-name is the address itself
        (readBack(fixture("safari-selected-link"), pb), now.addingTimeInterval(-30)),
        (readBack(fixture("safari-copy-link"), pb), now.addingTimeInterval(-20)),
        (readBack(fixture("safari-address"), pb), now.addingTimeInterval(-10)),
    ]
}

func linkTests() {
    let pb = NSPasteboard(name: .init("com.geragaraza.copia.test.\(getpid())"))
    defer { pb.releaseGlobally() }
    let dir = tmpDir("links")
    let specs = linkSpecs(pb)
    let (st, ids) = seeded(dir, specs)
    let byId = Dictionary(uniqueKeysWithValues: st.entries().map { ($0.id, $0) })
    let para = byId[ids[0]]!, sel = byId[ids[2]]!, copyLink = byId[ids[3]]!, bar = byId[ids[4]]!
    // Notes' copy and Safari's address bar are the same link (https://github.com): one entry, the newer copy's title
    // (0.5's content key). The Notes copy alone is read as prepared, before the store.
    check(ids[1] == ids[4] && st.entries().count == 4, "the same link from Notes and from Safari is one entry, Safari's newer copy on top")
    let notes = prepare(specs[1].0, dir: dir)!.0

    // Safari's address bar: the title and both pictures from the archived LPLinkMetadata, no network.
    check(bar.kind == .link, "address bar: a link (\(bar.kind))")
    check(bar.title == "GitHub · Change is constant. GitHub keeps you ahead. · GitHub", "address bar: the page's title (\(bar.title))")
    check(bar.url == nil && bar.address == "https://github.com", "address bar: the address is the text (\(bar.address))")
    check(metaText(bar).hasSuffix(" · https://github.com"), "address bar: the address under the title (\(metaText(bar)))")
    let icon = bar.thumb.flatMap { NSImage(contentsOf: dir.appendingPathComponent($0)) }
    check(icon.map { Int($0.representations[0].pixelsWide) } == 120 && bar.thumb?.hasSuffix(".png") == true,
          "address bar: the site's 120 px PNG icon kept (\(bar.thumb ?? "none"))")
    let pic = bar.picture.flatMap { NSImage(contentsOf: dir.appendingPathComponent($0)) }
    check(pic.map { Int($0.representations[0].pixelsWide) } == 1024 && bar.picture?.hasSuffix(".jpeg") == true,
          "address bar: the page's 1024 px picture kept as JPEG (\(bar.picture ?? "none"))")
    check(st.reps(bar.id).first?.contains { $0.type == "com.apple.linkpresentation.metadata" } == true,
          "address bar: the metadata kept for pasting (Notes and Messages make their link card from it)")

    // Safari's Copy Link: public.url-name is the link's text.
    check(copyLink.kind == .link && copyLink.title == "Страница macOS" && copyLink.address == "https://www.apple.com/macos/",
          "Copy Link: titled by url-name (\(copyLink.title), \(copyLink.address))")
    check(copyLink.thumb == nil && copyLink.picture == nil, "Copy Link: no pictures carried, none made up")

    // A link selected on a page: the HTML is one <a>; the text stays what pastes, the address its own field.
    check(sel.kind == .link && sel.title == "GitHub" && sel.url == "https://github.com/" && sel.text == "GitHub",
          "selected link: title GitHub, address github.com/ (\(sel.kind), \(sel.title), \(sel.url ?? "nil"))")
    check(metaText(sel).hasSuffix(" · https://github.com/"), "selected link: the address under the title (\(metaText(sel)))")
    check(sel.searchable(sel.title).contains("github.com/"), "selected link: its address is searchable")

    // Not links, or links with no title.
    check(para.kind == .text, "a paragraph with a link inside stays text (\(para.kind))")
    check(notes.kind == .link && notes.title == "https://github.com" && !metaText(notes).contains(" · https"),
          "url-name equal to the address is no title (\(notes.title); \(metaText(notes)))")

    // Telegram's hidden link: plain «text (address)», HTML one <a> with an entity in its address.
    let tg = linkInfo([Rep(type: str, data: Data("Сайт (https://example.com/a?b=1&c=2)".utf8)),
                       Rep(type: html, data: Data("<meta charset=\"utf-8\"><a href=\"https://example.com/a?b=1&amp;c=2\">Сайт</a>".utf8))],
                      plain: "Сайт (https://example.com/a?b=1&c=2)")
    check(tg == LinkInfo(url: "https://example.com/a?b=1&c=2", title: "Сайт"), "Telegram's hidden link (\(String(describing: tg)))")
    func htmlLink(_ h: String, _ plain: String) -> LinkInfo? {
        linkInfo([Rep(type: str, data: Data(plain.utf8)), Rep(type: html, data: Data(h.utf8))], plain: plain)
    }
    check(htmlLink("<a href='https://a.com'>A</a> and <a href='https://b.com'>B</a>", "A and B") == nil, "two links: text")
    check(htmlLink("<a href=\"javascript:alert(1)\">A</a>", "A") == nil, "a script link: text")
    check(htmlLink("<b>Read:</b> <a href=\"https://a.com\">A</a>", "Read: A") == nil, "words beside the link: text")
    check(htmlLink("<a href=\"https://a.com\">A</a>", "B") == nil, "plain text not the link's: text")
    check(htmlLink("<html><head><title>T</title><style>a{}</style></head><body><!-- c --><a href=https://a.com/x>A&nbsp;b</a></body></html>", "A b")
          == LinkInfo(url: "https://a.com/x", title: "A b"), "Chromium-style page: head, comment, unquoted href, &nbsp;")
    check(htmlLink("<a href=\"https://a.com/\">a.com</a>", "a.com") == LinkInfo(url: "https://a.com/", title: nil),
          "a link whose text is its address: no title")
    check(sameAddress("https://www.github.com/", "github.com") && !sameAddress("github.com/a", "github.com"), "sameAddress")

    // Apple's link card for a link that carried a picture, at Apple's own size; none for one without.
    let card = linkCard(bar, store: st)
    check(card != nil && card!.intrinsicContentSize.width == 350 && card!.intrinsicContentSize.height > 200,
          "address bar: Apple's link card at its own size (\(String(describing: card?.intrinsicContentSize)))")
    check(linkCard(copyLink, store: st) == nil && linkCard(para, store: st) == nil, "no card without a picture")

    // Two pictures per link, so the purge must keep them while the entry lives and drop them after.
    let files = [bar.thumb!, bar.picture!].map { dir.appendingPathComponent($0) }
    let old = Date().addingTimeInterval(-3600)
    for f in files { try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path) }
    st.purge()
    check(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "purge keeps a live link's pictures")
    st.erase([bar.id])
    st.purge()
    check(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "purge removes an erased link's pictures")

    // A store from before (version 1, no url or picture columns) opens and takes link entries.
    let odir = tmpDir("links-v1")
    let o1 = try! Store(dir: odir); _ = o1
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = [odir.appendingPathComponent("copia.sqlite").path,
                   "ALTER TABLE entries DROP COLUMN url; ALTER TABLE entries DROP COLUMN picture; PRAGMA user_version = 1;"]
    try! p.run(); p.waitUntilExit()
    let o2 = try! Store(dir: odir)
    let (e, it) = prepare(readBack(fixture("safari-selected-link"), pb), dir: odir)!
    let oid = o2.add(e, it)
    check(o2.entries().first { $0.id == oid }?.url == "https://github.com/", "a version 1 store gains the link columns")
}

// MARK: the Quick Look crash of 0.4 (on a real screen: run in the agents' own session, ./test cs)

/// His two crash reports of 0.4 (2026-11-14 17:38, 17:39): closing the panel while a Quick Look preview was open
/// aborted in PreviewController.dismiss() → -[QLPreviewView deactivate]. This drives the real panel and preview windows
/// through every way the preview ends, many times over: the leaving panel, Esc then the leaving panel, the arrows
/// moving to another item, dismiss twice, a video's player. 0.4 aborts in the first round; a pass means no abort.
func qlCrash() {
    let dir = tmpDir("ql")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (st, ids) = seeded(dir, mockSpecs())
    let pc = PanelController(store: st, monitor: nil)
    let image = ids[12], video = ids[6], shot2 = ids[2], text = ids[7]
    func row(_ id: Int64) -> Int { pc.rows.firstIndex { if case .entry(let i) = $0 { return pc.shown[i].id == id }; return false }! }
    func open(_ id: Int64) { pc.mouseDown(row: row(id), flags: [], clicks: 1); pc.togglePreview(); _ = wait(0.35) { false } }
    func show() { pc.show(); _ = wait(0.1) { false } }
    func hide() { pc.hide(); _ = wait(0.25) { !pc.isVisible && pc.window?.isVisible != true } }
    for round in 0..<12 {
        for id in [image, video] {
            show(); open(id); check(pc.preview.isOpen, "round \(round): the preview opened"); hide()           // the panel leaves with it open
            show(); open(id); pc.closePreview(); _ = wait(0.3) { false }; hide()                              // Esc first, then the panel
            show(); open(id); pc.move(1, extending: false); _ = wait(0.1) { false }; hide()                   // the arrows load another item
            show(); open(id); pc.preview.dismiss(); pc.preview.dismiss(); hide()                              // twice
            show(); open(shot2); pc.mouseDown(row: row(id), flags: [], clicks: 1); _ = wait(0.1) { false }; hide()
        }
        show(); open(text); hide()
    }
    check(!pc.preview.isOpen, "the preview is closed at the end")
    // The video plays in AVKit's view with the inline controls (a scrubber): the player is there and seekable.
    show(); open(video)
    let pv = pc.preview.playerViewForTest
    check(pv?.controlsStyle == .inline, "a video shows AVKit's inline controls")
    if let p = pv?.player {
        p.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
        _ = wait(1) { p.currentTime().seconds >= 0.9 }
        check(abs(p.currentTime().seconds - 1) < 0.1, "the video can be scrubbed: at \(p.currentTime().seconds) s")
    } else { check(false, "the video has a player") }
    hide()
    check(pc.preview.playerViewForTest == nil, "the player is let go when the panel leaves")
}

/// The panel on a real screen (the agents' own session): focus on opening, ⌘F, Esc step by step, Return, the place.
/// The paste queue's deck on a real screen: never key, at the bottom right place, the front card leaves on a paste and
/// the next comes forward; dragged by its edge to another place; closed.
func shelfOnScreen() {
    let dir = tmpDir("shelf")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (st, ids) = seeded(dir, Array(mockSpecs().prefix(4)))
    let pb = NSPasteboard(name: .init("com.geragaraza.copia.test.shelf.\(getpid())"))
    let q = PasteQueue(store: st, pasteboard: pb)
    q.sinceKey = { 0.01 }
    q.cmdDown = { false }
    let sh = Shelf(queue: q, store: st)
    let d = sh.deck
    sh.open(); _ = wait(0.6) { false }
    check(d.window.isVisible && !d.window.isKeyWindow && !d.window.canBecomeKey && d.window.alphaValue > 0.99,
          "the deck shows, faded in, and takes no keyboard")
    q.add([ids[0], ids[1], ids[2]]); _ = wait(0.4) { false }
    if let s = d.screen {
        let box = NSRect(x: d.origin.x, y: d.origin.y - deckBox.height, width: deckBox.width, height: deckBox.height)
        check(abs(box.maxX - (s.visibleFrame.maxX - deckGap)) < 0.5 && abs(box.minY - (s.visibleFrame.minY + deckGap)) < 0.5,
              "at the bottom right place: \(box) in \(s.visibleFrame)")
        check(d.view.badge.number == 3, "the badge counts three")
        let t = pb.pasteboardItems?.first?.types.first { ![.own, .source, .transient, .concealed].contains($0) }
        _ = t.flatMap { pb.data(forType: $0) }
        _ = wait(0.6) { false }
        check(q.left == 2 && d.view.badge.number == 2, "a paste: two left (\(q.left))")
        // Two fingers on the trackpad (his words 2026-11-15 10:47 and 11:25): the deck follows to the right; a short
        // swipe comes back, a long one to the right sends it off the edge and closes the queue, one to the left comes back.
        // `right` is the way the fingers go: the deltas follow them with natural scrolling and oppose them without.
        func swipe(_ steps: [Double], end: Int64 = 4) {
            var t = ProcessInfo.processInfo.systemUptime
            for (k, v) in steps.enumerated() {
                guard let probe = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0),
                      let inverted = NSEvent(cgEvent: probe)?.isDirectionInvertedFromDevice else { continue }
                let dx = inverted ? v : -v
                guard let ce = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0) else { continue }
                ce.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                ce.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
                ce.setIntegerValueField(.scrollWheelEventScrollPhase, value: k == 0 ? 1 : (k == steps.count - 1 ? end : 2))
                t += 0.016; ce.timestamp = CGEventTimestamp(t * 1e9)
                if let e = NSEvent(cgEvent: ce) { d.view.scrollWheel(with: e) }
                _ = wait(0.016) { false }
            }
        }
        let rest = d.window.frame.origin
        swipe([0, 4, 4, 0])
        _ = wait(0.4) { false }
        check(q.isOpen && d.window.frame.origin == rest, "a short slow swipe: the deck comes back, the queue stays (\(d.window.frame.origin) vs \(rest))")
        swipe([0] + Array(repeating: -14, count: 10) + [0])
        _ = wait(0.4) { false }
        check(q.isOpen && d.window.frame.origin == rest, "a long swipe to the left: comes back (\(d.window.frame.origin))")
        swipe([0, 6, 6, 6], end: 2)   // a gesture whose end never comes
        check(d.window.frame.origin.x > rest.x + 10, "mid-swipe the deck follows the fingers to the right")
        _ = wait(3.5) { false }
        check(q.isOpen && d.window.frame.origin == rest, "a gesture that never ends: back after 3 s")
        swipe([0] + Array(repeating: 14, count: 10) + [0])
        _ = wait(0.7) { false }
        check(!q.isOpen && !d.window.isVisible, "a long swipe to the right: off the edge, the queue closed")
        // The mouse: pressed on the deck and moved to the right, let go; from the front card leftwards is a drag out.
        sh.open(); q.add([ids[0], ids[1]]); _ = wait(0.6) { false }
        var at = NSPoint(x: 500, y: 500)
        d.pointer = { at }
        func dragged() -> Bool {
            let e = NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return d.mouseDragged(e)
        }
        d.mouseDown(onCard: true); at.x -= 10
        check(dragged(), "from the card to the left: the item is dragged out")
        d.mouseUp()
        at = NSPoint(x: 500, y: 500)
        d.mouseDown(onCard: true)
        for _ in 0..<8 { at.x += 4; _ = dragged(); _ = wait(0.02) { false } }
        d.mouseUp(); _ = wait(0.4) { false }
        check(q.isOpen && d.window.frame.origin == rest, "the mouse a little to the right, slowly: comes back")
        at = NSPoint(x: 500, y: 500)
        d.mouseDown(onCard: true)
        for _ in 0..<8 { at.x += 15; _ = dragged(); _ = wait(0.016) { false } }
        d.mouseUp(); _ = wait(0.7) { false }
        check(!q.isOpen && !d.window.isVisible, "the mouse flung to the right: off the edge, the queue closed")
        d.pointer = { NSEvent.mouseLocation }
        sh.open(); _ = wait(0.6) { false }
        check(d.window.isVisible && d.window.frame.origin == rest, "opened again: back at its place, the bottom right")
    }
    sh.close(); _ = wait(0.4) { false }
    check(!d.window.isVisible, "closed")
    pb.releaseGlobally()
}

func panelOnScreen() {
    let dir = tmpDir("onscreen")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (st, _) = seeded(dir, mockSpecs())
    let pc = PanelController(store: st, monitor: nil)
    let pb = NSPasteboard(name: .init("com.geragaraza.copia.test.onscreen.\(getpid())"))
    pc.pasteboard = pb
    func press(_ ch: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: pc.window!.windowNumber,
                                 context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        if mods.contains(.command) { _ = pc.window!.performKeyEquivalent(with: e) } else { pc.window!.sendEvent(e) }
        _ = wait(0.05) { false }
    }
    pc.show(); _ = wait(0.2) { false }
    check(pc.window!.firstResponder === pc.view && !pc.searching, "opened: the list has the keys, no caret in the search")
    if let s = pc.screen {
        let f = pc.panelScreenRect
        check(abs(f.width - 640) < 0.5 && abs(f.maxY - restingTop(.top, height: f.height, on: s)) < 0.5 && abs(f.midX - s.frame.midX) <= 0.5,
              "opened top centre, 640 wide, at Spotlight's top: \(f) on \(s.frame), visible \(s.visibleFrame)")
        check(f.height <= 546.5, "at most Spotlight's height: \(f.height)")
    }
    press("a", 0)
    check(pc.query.isEmpty, "a letter types nothing until ⌘F")
    press("\u{F701}", 125); press("\u{F701}", 125)
    check(pc.sel.count == 1, "↓ picks a row")
    press("f", 3, .command)
    check(pc.searching, "⌘F: the caret in the search")
    check(!pc.spaceOpensPreview, "Space in the search is a space, not the preview")
    check(!pc.focused, "the picked row turns grey while the search has the keys")
    pc.window!.fieldEditor(false, for: pc.view.field)?.insertText("xyz")
    press("a", 0, .command)
    let ed = pc.window!.fieldEditor(false, for: pc.view.field) as! NSTextView
    check(ed.selectedRange() == NSRange(location: 0, length: 3) && pc.sel.count == 1, "⌘A in the search selects the query, not the rows")
    press("\u{7f}", 51)
    check(pc.query.isEmpty && pc.sel.count <= 1 && st.entries(deleted: true).isEmpty, "⌫ in the search erases the query, deletes nothing")
    press("\u{F701}", 125)
    check(!pc.searching && pc.focused, "↓ from the search gives the keys to the list")
    press("a", 0, .command)
    check(pc.sel.count == pc.shown.count, "⌘A in the list picks every row")
    press("\u{7f}", 51)
    check(pc.shown.isEmpty && st.entries(deleted: true).count == 17, "⌫ in the list deletes the picks (into Recently Deleted)")
    press("z", 6, .command)
    check(pc.shown.count == 17, "⌘Z brings them back")
    // His recording 2026-11-15 09:27: with the caret in the (empty) search, a click on a row gives the list the keys.
    press("f", 3, .command)
    let r1 = pc.rows.firstIndex { if case .entry = $0 { return true }; return false } ?? 0
    pc.mouseDown(row: r1, flags: [], clicks: 1); pc.mouseUp()
    check(!pc.searching && pc.focused && pc.sel.count == 1,
          "a click in the list while searching: the list has the keys, the row in the accent (searching \(pc.searching), focused \(pc.focused), picks \(pc.sel.count))")
    press("f", 3, .command)
    pc.window!.fieldEditor(false, for: pc.view.field)?.insertText("pageB")
    _ = wait(0.1) { false }
    check(pc.query == "pageB" || pc.shown.count < 17, "typing after ⌘F searches (\(pc.query))")
    press("\u{1b}", 53)
    check(pc.query.isEmpty && !pc.searching && pc.sel.isEmpty && pc.isVisible, "Esc: search and picks cleared, as on opening, still open")
    press("\u{1b}", 53); _ = wait(0.3) { !pc.isVisible }
    check(!pc.isVisible, "Esc again: gone")
    // Picks without a search: the first Esc drops them (Spotlight's empty state), the second closes.
    pc.show(); _ = wait(0.2) { false }
    press("\u{F701}", 125)
    press("\u{1b}", 53)
    check(pc.isVisible && pc.sel.isEmpty, "Esc with a row picked: the pick goes, the panel stays")
    press("\u{1b}", 53); _ = wait(0.3) { !pc.isVisible }
    check(!pc.isVisible, "then Esc closes")
    pc.show(); _ = wait(0.2) { false }
    press("\r", 36); _ = wait(0.3) { !pc.isVisible }
    check(!pc.isVisible && (pb.pasteboardItems?.count ?? 0) >= 1, "Return with nothing picked copies the first row, as Spotlight's top hit")

    // The fifteen places on a real screen (2026-11-16): opened at each, the window where PlaceGrid says; then twelve of
    // the seventeen rows deleted by ⌫ and the window's frame read through the whole 200 ms of the change: the held edge
    // (top for the top and middle rows, bottom for the bottom row) never moves a point; closed and opened again, the
    // panel comes back exactly where it was (0.1 dropped the middle row 120 pt here); ⌘Z, and it is as at first.
    if let s = pc.screen {
        let g = PlaceGrid(s)
        var worst: CGFloat = 0
        for p in Place.allCases {
            pc.setPlace(p, on: s)
            pc.show(); _ = wait(0.25) { false }
            let f0 = pc.panelScreenRect
            let edge0 = p.row == .bottom ? f0.minY : f0.maxY
            check(abs(f0.minX - g.left(p.column)) < 0.5 && abs(edge0 - (p.row == .bottom ? g.bottomEdge : g.top(p.row, height: f0.height))) < 0.5,
                  "\(p.rawValue): opened at \(f0)")
            press("a", 0, .command)
            for id in pc.shown.suffix(5).map(\.id) { pc.sel.toggle(id) }   // keep five
            pc.selectionChanged()
            press("\u{7f}", 51)
            var moved: CGFloat = 0, frames = 0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 0.35 {
                let f = pc.window!.frame.insetBy(dx: panelMargin, dy: panelMargin)
                moved = max(moved, abs((p.row == .bottom ? f.minY : f.maxY) - edge0)); frames += 1
                _ = wait(1.0 / 120) { false }
            }
            let f1 = pc.panelScreenRect
            worst = max(worst, moved)
            check(pc.shown.count == 5 && f1.height < f0.height && moved < 0.5,
                  "\(p.rawValue): twelve deleted, \(Int(f0.height)) → \(Int(f1.height)) tall, the held edge moved \(moved) pt over \(frames) reads")
            press("\u{1b}", 53); press("\u{1b}", 53); _ = wait(0.3) { !pc.isVisible }
            pc.show(); _ = wait(0.25) { false }
            check(pc.panelScreenRect == f1, "\(p.rawValue): opened again, the same frame \(pc.panelScreenRect)")
            press("z", 6, .command); _ = wait(0.3) { false }
            check(pc.shown.count == 17 && pc.panelScreenRect == f0, "\(p.rawValue): ⌘Z, as at first")
            press("\u{1b}", 53); press("\u{1b}", 53); _ = wait(0.3) { !pc.isVisible }
        }
        print("places on screen: the held edge moved at most \(worst) pt")
        pc.setPlace(.standard, on: s)
    }
    pb.releaseGlobally()

    // The big window at its smallest shows Settings whole, with no scroll bar (his recording 2026-11-15 ~17:00).
    let b = BrowserController(store: st, monitor: nil)
    b.show(.settings); _ = wait(0.4) { false }
    if let w = b.window {
        w.setContentSize(w.contentMinSize); _ = wait(0.3) { false }
        func find(_ v: NSView) -> SettingsView? { (v as? SettingsView) ?? v.subviews.lazy.compactMap(find).first }
        let sv = w.contentView.flatMap(find)
        check(sv?.groups.map(\.rowCount) == SettingsView.groupRows, "Settings' rows as the minimum counts them")
        check(sv?.scrolls == false, "smallest window \(w.contentLayoutRect.size): Settings whole, no scroll bar")
        w.close()
    }
}

/// Return and Quick Pick paste for real (paste.swift): run in the agents' own session (cs) with TextEdit open on an empty
/// plain-text file in front (./test cs opens it). The panel opens over it, Return pastes the first row into TextEdit, ⌘2
/// the second row in sight, ⌘Return a rich text as plain text; TextEdit's text is read back through Accessibility. The
/// keys go to TextEdit's process only (CGEventPostToPid), never into the session's stream.
func pasteOnScreen() {
    guard let te = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
        check(false, "TextEdit is running in this session"); return
    }
    check(CGPreflightPostEventAccess(), "this process may send keys (cs: Claude Code's Accessibility)")
    te.activate(options: [])
    _ = wait(3) { NSWorkspace.shared.frontmostApplication == te }
    check(NSWorkspace.shared.frontmostApplication == te, "TextEdit in front")
    let dir = tmpDir("pastelive")
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let (st, _) = seeded(dir, [(textSnap("gamma third"), now.addingTimeInterval(-30)), (textSnap("beta second"), now.addingTimeInterval(-20)),
                               (textSnap("alpha first"), now.addingTimeInterval(-10))])
    let pc = PanelController(store: st, monitor: nil)
    let paster = Paster()
    pc.pasteInto = { paster.paste(into: $0) }
    func text() -> String {
        let a = AXUIElementCreateApplication(te.processIdentifier)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f else { return "<no focus>" }
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(f as! AXUIElement, kAXValueAttribute as CFString, &v)
        return v as? String ?? "<no value>"
    }
    func press(_ ch: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: pc.window!.windowNumber,
                                 context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        if mods.contains(.command), pc.window!.performKeyEquivalent(with: e) { return }
        pc.window!.sendEvent(e)
    }
    let before = text()
    pc.show(); _ = wait(0.3) { false }
    check(pc.pasteTarget == te && pc.window!.isKeyWindow, "the panel has the keys, TextEdit is where Return pastes (\(pc.pasteTarget?.bundleIdentifier ?? "-"))")
    press("\r", 36)
    _ = wait(2) { text() != before }
    let t1 = text()
    check(t1.hasSuffix("alpha first") && paster.lastPid == te.processIdentifier && !pc.isVisible, "Return pasted the first row into TextEdit: «\(t1)»")
    check(NSWorkspace.shared.frontmostApplication == te, "TextEdit still in front")
    pc.show(); _ = wait(0.3) { false }
    press("2", 19, .command)
    _ = wait(2) { text() != t1 }
    let t2 = text()
    // The row pasted moved to the top (Store.touch), so the second in sight is «beta second» again.
    check(t2.hasSuffix("alpha firstbeta second"), "⌘2 pasted the second row in sight: «\(t2)»")
    pc.show(); _ = wait(0.3) { false }
    press("\u{F701}", 125); press("\u{F701}", 125); press("\u{F701}", 125)
    press("\r", 36, .command)
    _ = wait(2) { text() != t2 }
    let t3 = text()
    check(t3.hasSuffix("gamma third") && NSPasteboard.general.pasteboardItems?.first?.types.contains(.rtf) == false,
          "⌘Return pasted the third row as plain text: «\(t3)»")
}

// MARK: main

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)   // no Dock icon while the tests draw
switch argv.count > 1 ? argv[1] : "" {
case "unit": unit()
case "capture":
    let pb = NSPasteboard(name: .init("com.geragaraza.copia.test.\(getpid())"))
    captureTests(pb, general: false); pb.releaseGlobally(); finish("capture")
case "copy":
    let pb = NSPasteboard(name: .init("com.geragaraza.copia.test.\(getpid())"))
    copyTests(pb); pb.releaseGlobally(); finish("copy")
case "general": general(); finish("general")
case "links": linkTests(); finish("links")
case "qlcrash": qlCrash(); finish("qlcrash")
case "migrate" where argv.count == 3:   // opens a copy of a real history with this version's store: counts after migrating
    let st = try! Store(dir: URL(fileURLWithPath: argv[2]))
    let live = st.entries(), gone = st.entries(deleted: true)
    print("live \(live.count), recently deleted \(gone.count), keys \(live.filter { $0.key != nil }.count + gone.filter { $0.key != nil }.count)")
    exit(0)
case "write" where argv.count >= 3:   // another app copying: TEXT on the general pasteboard, with HTML too when asked
    let pb = NSPasteboard.general
    pb.clearContents()
    let it = NSPasteboardItem()
    it.setString(argv[2], forType: .string)
    if argv.count > 3 { it.setString("<b>\(argv[2])</b>", forType: .html) }
    pb.writeObjects([it]); exit(0)
case "screen": qlCrash(); panelOnScreen(); shelfOnScreen(); finish("screen")
case "pastelive": pasteOnScreen(); finish("pastelive")
case "readtiff" where argv.count == 3:   // copy's helper: another process asking for the TIFF
    let d = NSPasteboard(name: .init(argv[2])).pasteboardItems?.first?.data(forType: .tiff)
    print(d.flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide ?? 0); exit(0)
case "seed" where argv.count == 3:   // the mockup's content into a data folder, for a trial run of the app
    // The link fixtures too (run from the source folder: they are read from tests/links), so the trial shows titles and pictures.
    let lpb = NSPasteboard(name: .init("com.geragaraza.copia.test.\(getpid())"))
    _ = seeded(URL(fileURLWithPath: argv[2]), mockSpecs() + linkSpecs(lpb).map { ($0.0, $0.1.addingTimeInterval(-86400)) })
    lpb.releaseGlobally(); exit(0)
case "render" where argv.count >= 5: render(app: argv[2], theme: argv[3], out: argv[4], mode: argv.count > 5 ? argv[5] : "")
default:
    print("usage: copia-tests unit | capture | copy | general | links | render APP THEME OUT [motion]"); exit(2)
}
