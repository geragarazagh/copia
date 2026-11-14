// Dragging out of the panel and the big window, several at once like Finder (clipboard.md, «Decided»: wanted if done
// well). His recording of 0.4 showed two items dragged out arriving as one merged text file. The choice here: every
// picked entry is its own dragged item, and every item is a real file, so Finder makes as many files as were picked
// (an image a .png, copied files themselves, a text a .txt or, when styled, an .rtf, a link a .webloc), in pick order.
// A text item also carries its text (and rich text), so a text view (Notes, TextEdit, Mail) inserts the words, not a
// file icon: the receiving app takes the richest type it reads, as with any drag on macOS.
import AppKit

enum Drag {
    /// The pasteboard items of a drag of `entries`, in pick order.
    static func items(_ entries: [Entry], store: Store) -> [NSPasteboardItem] {
        var out: [NSPasteboardItem] = []
        for e in entries {
            let reps = store.reps(e.id)
            if e.kind == .link, let u = URL(string: e.address), u.scheme != nil {
                let it = NSPasteboardItem()
                if let f = webloc(e, url: u, store: store) { it.setString(f.absoluteString, forType: .fileURL) }
                it.setString(u.absoluteString, forType: .URL)
                it.setString(e.address, forType: .string)
                out.append(it)
                continue
            }
            let files = entryFiles(e, store: store, forOpening: true)
            let text = [Kind.text, .color, .other].contains(e.kind)
            for u in files {
                let it = NSPasteboardItem()
                it.setString(u.standardizedFileURL.absoluteString, forType: .fileURL)
                if text {
                    it.setString(e.text, forType: .string)
                    if let r = reps.first?.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }), let d = store.data(r) {
                        it.setData(d, forType: .rtf)
                    }
                }
                out.append(it)
            }
        }
        for it in out { it.setString("1", forType: .own) }   // our own: the monitor never records a drag as a copy
        return out
    }

    /// A link as Finder saves one: a .webloc named after the page, in the paste folder (24 h).
    static func webloc(_ e: Entry, url: URL, store: Store) -> URL? {
        let folder = store.dir.appendingPathComponent("paste").appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(shownTitle(e).prefix(60)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let dst = folder.appendingPathComponent((name.isEmpty ? (url.host ?? L("Link")) : name) + ".webloc")
        guard let d = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0),
              (try? d.write(to: dst)) != nil else { return nil }
        return dst
    }

    /// Dragging items with their pictures, fanned a little as Finder fans several files, starting at `at` (in
    /// `view`'s coordinates).
    static func begin(_ entries: [Entry], store: Store, from view: NSView, event: NSEvent, at p: NSPoint, source: NSDraggingSource) {
        let items = items(entries, store: store)
        guard !items.isEmpty else { return }
        let pics = entries.flatMap { e in Array(repeating: Thumbs.shared.thumb(e, store: store, side: 48), count: max(1, items.count / max(1, entries.count))) }
        let dragging = items.enumerated().map { k, it -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: it)
            let o = CGFloat(min(k, 4)) * 4
            d.setDraggingFrame(NSRect(x: p.x - 24 + o, y: p.y - 24 - o, width: 48, height: 48), contents: pics[min(k, pics.count - 1)])
            return d
        }
        let s = view.beginDraggingSession(with: dragging, event: event, source: source)
        s.animatesToStartingPositionsOnCancelOrFail = true
        s.draggingFormation = .pile
    }
}

/// The panel's list as a drag source.
extension PanelController: NSDraggingSource {
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }

    /// Starts a drag of the picks once the mouse moved 3 pt with the button down on a row (the row is picked first if
    /// it was not, as in Finder).
    func dragOut(row: Int, event: NSEvent, at p: NSPoint) {
        guard row >= 0, row < rows.count, case .entry(let i) = rows[row] else { return }
        let id = shown[i].id
        if !sel.contains(id) { sel.click(id); selectionChanged() }
        draggedIDs = sel.order
        Drag.begin(sel.order.compactMap(entry), store: store, from: view.table, event: event, at: p, source: self)
    }

    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation o: NSDragOperation) {
        if o != [] { used(draggedIDs) }   // dropped somewhere: used, to the top
        draggedIDs = []
    }
}

/// The big window's views as a drag source.
extension BrowserController: NSDraggingSource {
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }

    func dragOut(from view: NSView, event: NSEvent, at p: NSPoint) {
        guard pane != .deleted, !order.isEmpty else { return }
        Drag.begin(picked, store: store, from: view, event: event, at: p, source: self)
    }

    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation o: NSDragOperation) {
        if o != [] { used() }
    }
}
