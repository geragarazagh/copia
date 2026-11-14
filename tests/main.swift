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
    s.all(list); check(s.order == [5, 6, 7, 8, 9, 10], "⌘A = copy order, oldest first")
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
    check(f.parts.count == 4 && f.parts[0] == "28\u{00A0}characters" && f.parts[1] == "5\u{00A0}words", "facts parts \(f.parts)")
    check(f.parts[2].hasPrefix("≈"), "tokens \(f.parts)")

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
    check(pc.undoDelete() && pc.shown.map(\.id) == shown0 && pc.sel.order == picked, "⌘Z: back in place, picked as before")
    pc.selectAll(); check(pc.sel.order == did, "⌘A in copy order")
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

    // The middle place: the box's centre on the visible frame's centre, on every screen.
    for sc in NSScreen.screens {
        let t = restingTop(.middle, height: 400, on: sc)
        check(abs((t - 200) - sc.visibleFrame.midY) <= 0.5, "middle of \(sc.localizedName): centre \(t - 200) vs \(sc.visibleFrame.midY)")
        check(restingTop(.top, height: 400, on: sc) <= sc.visibleFrame.maxY - screenGap
              && restingTop(.bottom, height: 400, on: sc) - 400 == sc.visibleFrame.minY + screenGap, "top and bottom inside the visible frame")
    }

    // Drag and snap (place.swift): magnets at top, middle, bottom; the sideways rubber band; the settle spring;
    // the place remembered per screen.
    if let main = NSScreen.main {
        let gdir = tmpDir("snap")
        let gs = try! Store(dir: gdir)
        for i in 0..<4 { let (e, it) = prepare(textSnap("snap \(i)"), dir: gdir, at: now.addingTimeInterval(Double(i)))!; gs.add(e, it) }
        let dc = PanelController(store: gs, monitor: nil, onScreen: false)
        dc.screen = main
        check(dc.placeFor(main) == .middle, "the middle until moved")
        dc.setBox(height: dc.contentHeight(), top: restingTop(.middle, height: dc.contentHeight(), on: main))
        let sn = dc.snap!
        let (tp, md, bt) = (sn.detents[0], sn.detents[1], sn.detents[2])
        check(tp > md && md > bt, "places in order \(sn.detents)")
        check(abs(sn.shown(md + 5) - md) < 1.5 && abs(sn.shown(md + sn.reach) - (md + sn.reach)) < 1e-6, "a place holds a small pull; free past its reach")
        let ys = stride(from: bt - 80, through: tp + 80, by: 1).map(sn.shown)
        check(zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && zip(ys, ys.dropFirst()).allSatisfy { $1 - $0 < 2.01 },
              "no jump and no reversal anywhere along the way")
        let tight = Snap(detents: [908, 820, 726])   // a 720 pt panel on a 13-inch Air
        let ty = stride(from: 700.0, through: 930.0, by: 0.5).map { tight.shown(CGFloat($0)) }
        check(tight.reach == 44 && zip(ty, ty.dropFirst()).allSatisfy { $1 >= $0 && $1 - $0 < 1.1 }, "close places: smaller reach, still no jump")
        check(sn.shown(tp + 500) < tp + 30 && sn.shown(bt - 500) > bt - 30, "past top and bottom: a short rubber band")
        check(abs(sn.band(5000, limit: Snap.sideways)) < Snap.sideways && sn.band(20, limit: Snap.sideways) > 5, "sideways: gives, at most \(Snap.sideways)")
        Ticker.manual = true
        // From the middle up to the top: one tap when the top catches, settles there, remembered.
        dc.dragBegin()
        for raw in stride(from: md, through: tp + 4, by: 4) { dc.dragMove(raw: raw, sideways: 12, snap: sn) }
        check(dc.hapticTaps == 1 && dc.dragX > 0, "one alignment tap at the top (\(dc.hapticTaps)); pulled sideways \(dc.dragX)")
        dc.dragEnd(velocity: 400, snap: sn)
        for _ in 0..<60 { Ticker.advance(1.0 / 60) }
        check(dc.top == tp && dc.dragX == 0 && dc.placeFor(main) == .top, "settled at the top, centred, remembered (\(dc.top) vs \(tp))")
        // A small pull down from the top springs back.
        dc.dragBegin(); dc.dragMove(raw: tp - 25, sideways: 0, snap: sn)
        check(dc.top > tp - 12, "a small pull lags behind the pointer (\(tp - dc.top) pt for 25)")
        dc.dragEnd(velocity: 0, snap: sn)
        for _ in 0..<60 { Ticker.advance(1.0 / 60) }
        check(dc.top == tp, "…and springs back")
        // Let go between middle and bottom: the spring's shape (Spotlight: about 0.5 s, a small overshoot).
        dc.dragBegin(); dc.dragMove(raw: md - 100, sideways: 0, snap: sn)
        dc.dragEnd(velocity: 0, snap: sn)
        var path: [CGFloat] = [dc.top]
        for _ in 0..<60 { Ticker.advance(1.0 / 60); path.append(dc.top) }
        let over = (path.max() ?? md) - md
        let within = path.firstIndex { abs($0 - md) < 1 } ?? 99
        print(String(format: "settle from 100 pt: overshoot %.1f pt, within 1 pt after %d ms", over, within * 1000 / 60))
        check(over > 0.5 && over < 5 && within >= 18 && within <= 36 && path.last == md,
              "settle: overshoot \(String(format: "%.1f", over)) pt of 100, within 1 pt at \(within) frames (\(within * 1000 / 60) ms)")
        // Flung down from the middle: the speed carries it to the bottom.
        dc.dragBegin(); dc.dragMove(raw: md - 70, sideways: 0, snap: sn)
        dc.dragEnd(velocity: -1500, snap: sn)
        for _ in 0..<90 { Ticker.advance(1.0 / 60) }
        check(dc.top == bt && dc.placeFor(main) == .bottom, "a fling goes on to the bottom")
        Ticker.manual = false
        gs.setSetting("place." + screenKey(main), "middle")
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
    check(!pv.spaceOpensPreview || pv.sel.isEmpty, "Space after typing a search: a space")
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
    check(pv.preview.factsText.hasPrefix(counted(19, "character|characters")) && pv.preview.factsText.contains(counted(1, "line|lines")),
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
    check(menu.items.map(\.title) == ["Copy", "Copy as Plain Text", "Share…", "Open With", "", "Delete"], "menu: \(menu.items.map(\.title))")
    check(menu.items[5].keyEquivalent == "\u{8}" && menu.items[5].keyEquivalentModifierMask == .command, "Delete shows ⌘⌫")
    check(menu.items[3].submenu?.items.contains { $0.title == "TextEdit" } == true, "Open With lists TextEdit for a text")
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
    check(b.order == b.shown.sorted { $0.copied < $1.copied }.map(\.id), "⌘A: the order of copying, oldest first")
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
/// picture in one window under the desktop (never seen), captured with screencapture -l.
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
    win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)   // under the wallpaper: never seen
    win.appearance = NSApp.appearance
    let root = Flipped(frame: NSRect(x: 0, y: 0, width: SW, height: SH))
    let bg = NSImageView(frame: root.bounds)
    bg.image = NSImage(contentsOfFile: res + (theme == "dark" ? "bg-1.jpg" : "bg-0.jpg"))
    bg.imageScaling = .scaleAxesIndependently
    root.addSubview(bg)
    pc.view.frame.origin = NSPoint(x: (SW - panelSize.width) / 2, y: ((SH - pc.view.frame.height) / 2).rounded())
    root.addSubview(pc.view)
    win.contentView = root
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
    let para = byId[ids[0]]!, notes = byId[ids[1]]!, sel = byId[ids[2]]!, copyLink = byId[ids[3]]!, bar = byId[ids[4]]!

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
