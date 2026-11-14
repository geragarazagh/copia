// The right-click menu of a row, his list (2026-11-14, kept from the mockups): Copy, Copy as Plain Text, Share…,
// Open With, Delete ⌘⌫. macOS's own words in ru and uk (AppKit MenuCommands.loctable; «Поделиться…» from Photos),
// no icons (AppKit on macOS 27 draws none in such menus, Spotlight's clipboard menu has none). A right click on a row
// outside the selection picks that row first, as in Finder; the menu then acts on the whole selection.
import AppKit
import UniformTypeIdentifiers

extension PanelController: NSMenuDelegate {
    func contextMenu(row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count, case .entry(let i) = rows[row] else { return nil }
        let id = shown[i].id
        if !sel.contains(id) { sel.click(id); selectionChanged() }
        let picked = sel.order.compactMap(entry)
        let m = NSMenu()
        m.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            m.addItem(it)
            return it
        }
        _ = add(L("Copy"), #selector(menuCopy), key: "c")
        add(L("Copy as Plain Text"), #selector(menuCopyPlain)).isEnabled = !plainText(picked).isEmpty
        _ = add(L("Share…"), #selector(menuShare))
        let open = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
        open.submenu = openWithMenu(picked)
        open.isEnabled = open.submenu?.items.isEmpty == false
        m.addItem(open)
        m.addItem(.separator())
        _ = add(L("Delete"), #selector(menuDelete), key: "\u{8}")
        menuRow = row
        return m
    }

    @objc func menuCopy() { copySelection() }

    /// Every picked text as plain text, joined by a new line (files and images give their names).
    @objc func menuCopyPlain() {
        let t = plainText(sel.order.compactMap(entry))
        guard !t.isEmpty else { return }
        pasteboard.clearContents()
        let it = NSPasteboardItem()
        it.setString(t, forType: .string)
        it.setString("1", forType: .own)
        pasteboard.writeObjects([it])
        monitor?.ownCount = pasteboard.changeCount
        hide()
    }

    func plainText(_ es: [Entry]) -> String {
        es.map { $0.kind == .image ? "" : $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
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
