// The right-click menu of an item, one for the panel and the big window (his answer 2026-11-15 ~15:35: «one order for
// every kind», kind-only items added in their place, never a menu reordered by kind: «нелогично»):
//   Paste, Paste as Plain Text | Copy, Copy as Plain Text | Share…, Open With, [Open in Browser: links],
//   [Show in Finder ⌘R: files] | Delete
// The keys beside the items are the person's own (Settings). macOS's own words, no icons (AppKit on macOS 27 draws none
// in such menus, Spotlight's clipboard menu has none). A right click on a row outside the selection picks that row
// first, as in Finder; the menu then acts on the whole selection. On empty space: Open Copia Window, Clear History…,
// Settings… (the panel; the big window keeps Finder's view menu there).
import AppKit
import UniformTypeIdentifiers

/// The verbs of the item menu, as the window's own selectors.
struct ItemVerbs {
    var paste, pastePlain, copy, copyPlain, share, openInBrowser, showInFinder, delete: Selector
}

/// The item menu for these picks, in the one fixed order.
func makeItemMenu(_ picked: [Entry], target: AnyObject, verbs v: ItemVerbs, keys: Keys, openWith: NSMenu) -> NSMenu {
    let m = NSMenu()
    m.autoenablesItems = false
    func add(_ title: String, _ action: Selector, _ key: HotKey? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if let key { dressMenuKey(it, key) }
        it.target = target
        m.addItem(it)
        return it
    }
    let hasPlain = !Copia.plainText(picked).isEmpty
    _ = add(L("Paste"), v.paste, keys.paste)
    add(L("Paste as Plain Text"), v.pastePlain, keys.plain == .fn ? nil : HotKey(code: keys.paste.code, mods: keys.paste.mods | keys.plain.carbon))
        .isEnabled = hasPlain
    m.addItem(.separator())
    _ = add(L("Copy"), v.copy, keys.copy)
    add(L("Copy as Plain Text"), v.copyPlain, HotKey(code: 8, mods: 2048 | 512 | 256)).isEnabled = hasPlain   // ⌥⇧⌘C
    m.addItem(.separator())
    _ = add(L("Share…"), v.share)
    let open = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
    open.submenu = openWith
    open.isEnabled = !openWith.items.isEmpty
    m.addItem(open)
    if !picked.isEmpty && picked.allSatisfy({ $0.kind == .link }) { _ = add(L("Open in Browser"), v.openInBrowser) }
    if !picked.isEmpty && picked.allSatisfy({ $0.kind == .files }) { _ = add(L("Show in Finder"), v.showInFinder, HotKey(code: 15, mods: 256)) }   // ⌘R
    m.addItem(.separator())
    _ = add(L("Delete"), v.delete, keys.delete)
    return m
}

/// Each link's page in the default browser.
func openInBrowser(_ picked: [Entry]) {
    for e in picked where e.kind == .link {
        if let u = URL(string: e.address), u.scheme != nil { NSWorkspace.shared.open(u) }
    }
}

/// The copied files, selected in Finder (those still there).
func showInFinder(_ picked: [Entry], store: Store) {
    let urls = picked.filter { $0.kind == .files }.flatMap { entryFiles($0, store: store) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
}

extension PanelController: NSMenuDelegate {
    static let verbs = ItemVerbs(paste: #selector(menuPaste), pastePlain: #selector(menuPastePlain), copy: #selector(menuCopy),
                                 copyPlain: #selector(menuCopyPlain), share: #selector(menuShare), openInBrowser: #selector(menuOpenInBrowser),
                                 showInFinder: #selector(menuShowInFinder), delete: #selector(menuDelete))

    func contextMenu(row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count, case .entry(let i) = rows[row] else { return emptyMenu() }
        let id = shown[i].id
        if !sel.contains(id) { sel.click(id); selectionChanged() }
        let picked = sel.order.compactMap(entry)
        menuRow = row
        return makeItemMenu(picked, target: self, verbs: Self.verbs, keys: keys, openWith: openWithMenu(picked))
    }

    /// Empty space in the panel.
    func emptyMenu() -> NSMenu {
        let m = NSMenu()
        for (t, a) in [(L("Open Copia Window"), #selector(menuOpenWindow)), (L("Clear History…"), #selector(menuClearHistory)),
                       (L("Settings…"), #selector(menuSettings))] {
            let it = m.addItem(withTitle: t, action: a, keyEquivalent: a == #selector(menuSettings) ? "," : "")
            it.target = self
        }
        return m
    }

    @objc func menuOpenWindow() { openBrowser?(.all) }
    @objc func menuClearHistory() { clearHistory() }
    @objc func menuSettings() { openBrowser?(.settings) }
    @objc func menuPaste() { pasteSelection(plain: false) }
    @objc func menuPastePlain() { pasteSelection(plain: true) }
    @objc func menuCopy() { copySelection() }
    @objc func menuOpenInBrowser() { openInBrowser(sel.order.compactMap(entry)); hide() }
    @objc func menuShowInFinder() { showInFinder(sel.order.compactMap(entry), store: store); hide() }

    /// Every picked text as plain text, joined by a new line (files give their names, images nothing); it joins the paste
    /// queue as plain text, as any copy joins it.
    @objc func menuCopyPlain() {
        let picked = sel.order
        let t = Copia.plainText(picked.compactMap(entry))
        guard !t.isEmpty else { return }
        let own = Copia.writePlain(t, to: pasteboard); monitor?.ownCount = own
        used(picked)
        copied(picked, true)
        hide()
    }

    /// The system's share sheet from the row: texts as text, images and files as files.
    @objc func menuShare() {
        let picked = sel.order.compactMap(entry)
        let items: [Any] = picked.flatMap { e -> [Any] in
            switch e.kind {
            case .image, .files: return fileURLs(e)
            default: return [e.text]
            }
        }
        guard !items.isEmpty, let r = menuRow, r < rows.count else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: view.table.rect(ofRow: r), of: view.table, preferredEdge: .maxX)
    }

    @objc func menuDelete() { deleteSelection() }

    /// The apps that open the item (the system's default first), as Finder's Open With lists them.
    func openWithMenu(_ picked: [Entry]) -> NSMenu {
        let m = NSMenu()
        guard picked.count == 1, let e = picked.first else { return m }
        let urls = fileURLs(e, forOpening: true)
        guard let u = urls.first else { return m }
        let def = NSWorkspace.shared.urlForApplication(toOpen: u)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: u)
        if let def { apps.removeAll { $0 == def }; apps.insert(def, at: 0) }
        for a in apps.prefix(12) {
            let it = NSMenuItem(title: FileManager.default.displayName(atPath: a.path).replacingOccurrences(of: ".app", with: ""),
                                action: #selector(openWith(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = (a, urls)
            let icon = NSWorkspace.shared.icon(forFile: a.path)
            icon.size = NSSize(width: 16, height: 16)
            it.image = icon   // Finder's Open With shows the apps' icons
            // macOS 27 hides menu images unless the item asks (seen on 27.2 in the agents' session, 2026-11-14)
            if #available(macOS 27.0, *) { it.preferredImageVisibility = .visible }
            m.addItem(it)
            if a == def && apps.count > 1 { m.addItem(.separator()) }
        }
        return m
    }

    @objc func openWith(_ it: NSMenuItem) {
        guard let (app, urls) = it.representedObject as? (URL, [URL]) else { return }
        hide()
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func fileURLs(_ e: Entry, forOpening: Bool = false) -> [URL] { entryFiles(e, store: store, forOpening: forOpening) }
}

/// Real files for an entry: its own files, its pictures as PNG files, or (to open a text) the text as a file;
/// made in paste/, which lives 24 h, like the files of a copy.
func entryFiles(_ e: Entry, store: Store, forOpening: Bool = false) -> [URL] {
    let furl = NSPasteboard.PasteboardType.fileURL.rawValue, png = NSPasteboard.PasteboardType.png.rawValue
    let reps = store.reps(e.id)
    let own = reps.compactMap { $0.first { $0.type == furl } }.compactMap { store.data($0).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:)) }
    if !own.isEmpty { return own }
    let folder = store.dir.appendingPathComponent("paste").appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pics = reps.compactMap { $0.first { $0.type == png && $0.file != nil } }
    if !pics.isEmpty {
        return pics.enumerated().map { k, r in
            let dst = folder.appendingPathComponent((pics.count == 1 ? L("Image") : "\(L("Image")) \(k + 1)") + ".png")
            try? FileManager.default.copyItem(at: store.dir.appendingPathComponent(r.file!), to: dst)
            return dst
        }
    }
    guard forOpening else { return [] }
    let rtf = reps.first?.first { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }
    let name = String(e.title.prefix(40)).replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
    let dst = folder.appendingPathComponent((name.isEmpty ? L("Text") : name) + (rtf != nil ? ".rtf" : ".txt"))
    if let rtf, let d = store.data(rtf) { try? d.write(to: dst) } else { try? Data(e.text.utf8).write(to: dst) }
    return [dst]
}
