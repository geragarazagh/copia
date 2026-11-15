// The big window (his word 2026-11-14: opening the app or ⌘, shows the whole history «как файлы», like Finder's views,
// keeping only what a clipboard needs). A sidebar by kind, then Recently Deleted and Settings; three views of the same
// items: Icons ⌘1, List ⌘2, Gallery ⌘4; Sort By; Show View Options ⌘J; Finder's own toolbar mechanism (NSToolbar
// customization, its right-click with Icon and Text / Icon Only / Text Only). The same store and the same verbs as the
// panel: ⌘C copies the selection in pick order in one write, ⌘⌫ moves it to Recently Deleted, ⌘Z brings it back, Space
// is Quick Look (Apple's own panel, which zooms out of the item's picture), a double click copies.
//
// Columns (⌘3) is left out on purpose: Finder's column view walks a tree of folders, and a history is a flat list in
// time; its one level of nesting (twelve files in one copy) is already a stack picture and opens in Quick Look. ⌘3
// stays unused so that ⌘4 is Gallery, as in Finder (the hands remember Finder's numbers).
//
// Everything the window remembers (view, sort, icon size, columns, toolbar, size) lives in the history's own settings
// table, never in ~/Library/Preferences: the app keeps one removable folder (dev/rules.md, section 3).
import AppKit
import Quartz
import UniformTypeIdentifiers

enum Pane: String, CaseIterable {
    case all, text, links, images, video, audio, files, colors, deleted, settings

    var title: String {
        switch self {
        case .all: L("All")
        case .text: L("Text")
        case .links: L("Links")
        case .images: L("Images")
        case .video: L("Video")
        case .audio: L("Audio")
        case .files: L("Files")
        case .colors: L("Colors")
        case .deleted: L("Recently Deleted")
        case .settings: L("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .all: "doc.on.clipboard"
        case .text: "text.alignleft"
        case .links: "link"
        case .images: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .files: "folder"
        case .colors: "paintpalette"
        case .deleted: "trash"
        case .settings: "gearshape"
        }
    }
}

/// Which pane an entry shows in. Images, video and audio are what was copied as such, picture data or files of that
/// type alike (a screenshot copied in Finder is an image to the person); Files is everything copied as files.
func inPane(_ e: Entry, _ p: Pane) -> Bool {
    func files(_ t: UTType) -> Bool {
        guard e.kind == .files else { return false }
        let names = e.text.split(separator: "\n")
        return !names.isEmpty && names.allSatisfy { UTType(filenameExtension: ($0 as NSString).pathExtension)?.conforms(to: t) == true }
    }
    switch p {
    case .all, .deleted: return true
    case .text: return e.kind == .text || (e.kind == .other && !e.text.isEmpty)
    case .links: return e.kind == .link
    case .images: return e.kind == .image || files(.image)
    case .video: return files(.movie)
    case .audio: return files(.audio)
    case .files: return e.kind == .files
    case .colors: return e.kind == .color
    case .settings: return false
    }
}

enum ViewMode: Int, CaseIterable {
    case icons = 1, list = 2, gallery = 4
    var title: String { switch self { case .icons: L("as Icons"); case .list: L("as List"); case .gallery: L("as Gallery") } }
    /// Finder's own symbols (its toolbar and View menu on macOS 27.2: the gallery is squares below a rectangle).
    var symbol: String { switch self { case .icons: "square.grid.2x2"; case .list: "list.bullet"; case .gallery: "squares.below.rectangle" } }
    /// The symbol beside the item in a menu, as Finder's View menu draws its views: from macOS 26 on; macOS 27 hides
    /// menu images unless the item asks for them (NSMenuItem.preferredImageVisibility, new in the 27 SDK), and Finder's
    /// view items ask, the rest of its items carry none (seen on 27.2, 2026-11-14). Before 26 Apple's menus have none.
    func dress(_ it: NSMenuItem) {
        guard #available(macOS 26.0, *) else { return }
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if #available(macOS 27.0, *) { it.preferredImageVisibility = .visible }
    }
}

enum SortKey: String, CaseIterable {
    case date, name, kind, size, app
    var title: String {
        switch self { case .date: L("Date Copied"); case .name: L("Name"); case .kind: L("Kind"); case .size: L("Size"); case .app: L("Application") }
    }
    /// Finder's first direction for each: newest and biggest first, words from A.
    var ascendingFirst: Bool { self == .name || self == .kind || self == .app }
}

/// The Kind column, as Finder names kinds: a single file by its type («Аудио MPEG-4»), the rest by what was copied.
func kindName(_ e: Entry) -> String {
    switch e.kind {
    case .image: return L("Image")
    case .files where e.count == 1:
        let ext = (e.text as NSString).pathExtension
        return UTType(filenameExtension: ext)?.localizedDescription ?? L("File")
    case .files: return L("Files")
    default: return kindLabel(e)
    }
}

func appName(_ id: String?) -> String {
    guard let id, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "" }
    return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
}

// MARK: the controller

final class BrowserController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    /// The app's one undo (panel.swift, appUndo): Edit > Undo here also takes back what the panel deleted.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { appUndo }

    let store: Store
    weak var monitor: Monitor?
    /// Re-registers the hot key after it is changed in Settings.
    var onHotKeyChange: (() -> Void)?
    /// The list keys changed in Settings (the panel reads them again).
    var onKeysChange: () -> Void = {}
    /// Settings' «Allow…» beside Paste into Apps.
    var allowPasting: () -> Void = {}
    /// Set by the app: copies made here join the paste queue as any copy does (true: as plain text).
    var copied: ([Int64], Bool) -> Void = { _, _ in }
    /// Set by the app: ⌘V into the app that was in front before this window (Paste in the item menu).
    var pasteInto: () -> Void = {}
    /// Settings' «Position on Screen» changed (the panel takes it).
    var onPlaceChange: ((Place, NSScreen) -> Void)?
    private(set) var window: BrowserWindow?
    private let split = NSSplitViewController()
    let sidebar = SidebarController()
    let content = ContentController()
    var toolbar: NSToolbar?
    var searchItem: NSSearchToolbarItem?
    var viewItem: NSToolbarItemGroup?
    private(set) var all: [Entry] = []
    private(set) var shown: [Entry] = []
    /// The selection in the order it was picked (the paste order), as the panel's badges show it.
    private(set) var order: [Int64] = []
    var query = ""
    private var foldCache: [Int64: ContiguousArray<UInt8>] = [:]
    var pasteboard = NSPasteboard.general

    var pane: Pane { didSet { store.setSetting("browser.pane", pane.rawValue) } }
    var mode: ViewMode { didSet { store.setSetting("browser.mode", String(mode.rawValue)) } }
    var sort: SortKey { didSet { store.setSetting("browser.sort", sort.rawValue) } }
    var ascending: Bool { didSet { store.setSetting("browser.ascending", ascending ? "1" : "0") } }
    var iconSize: CGFloat { didSet { store.setSetting("browser.iconSize", String(Int(iconSize))) } }
    /// List view columns besides Name, in order.
    var columns: [SortKey] { didSet { store.setSetting("browser.columns", columns.map(\.rawValue).joined(separator: ",")) } }

    init(store: Store, monitor: Monitor?) {
        self.store = store
        self.monitor = monitor
        pane = store.setting("browser.pane").flatMap(Pane.init) ?? .all
        mode = store.setting("browser.mode").flatMap(Int.init).flatMap(ViewMode.init) ?? .icons
        let s = store.setting("browser.sort").flatMap(SortKey.init) ?? .date
        sort = s
        ascending = store.setting("browser.ascending").map { $0 == "1" } ?? s.ascendingFirst
        iconSize = store.setting("browser.iconSize").flatMap(Double.init).map { CGFloat($0) } ?? 64
        columns = store.setting("browser.columns").map { $0.split(separator: ",").compactMap { SortKey(rawValue: String($0)) } }
            ?? [.date, .size, .kind, .app]
        super.init()
        sidebar.owner = self
        content.owner = self
        // Quick Look's pictures of files arrive one by one: the visible items are drawn again, at most every 0.2 s.
        NotificationCenter.default.addObserver(forName: Thumbs.ready, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.thumbRedraw else { return }
            self.thumbRedraw = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.thumbRedraw = false
                guard self.isVisible else { return }
                if self.content.items?.redrawPictures() == true { self.content.items?.select(Set(self.order)) }
            }
        }
    }
    private var thumbRedraw = false

    var isVisible: Bool { window?.isVisible == true }

    /// Opens the window (made on first use) at `pane`, or at the pane last used.
    func show(_ p: Pane? = nil) {
        let w = window ?? makeWindow()
        if let p { pane = p }
        reload()
        sidebar.select(pane)
        if let s = trialScreen(), !w.isVisible {
            w.setFrame(NSRect(x: s.visibleFrame.midX - w.frame.width / 2, y: s.visibleFrame.midY - w.frame.height / 2,
                              width: w.frame.width, height: w.frame.height), display: false)
        }
        // A trial on a display of its own inside his session never takes his keyboard; a trial in the agents' own
        // login session (cs) is a whole Mac of its own and runs as he would.
        if trial && trialDisplay != nil { w.orderFrontRegardless(); return }
        // Dock: while this window is open the app is a normal one, with its icon lit in the Dock and its menu bar,
        // as his apps with a window are (his word 2026-11-14 ~13:35); the panel alone never puts anything there.
        // The policy goes first, so the window comes up already in a regular app and the menu bar with it.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // The window opens only on the person's own word (⌘, in the panel, the app opened again), so it takes the
        // front. The cooperative activate() of macOS 14+ was refused when the ⌘, came from the panel, a window of an
        // app not yet active (macOS 27.2, cs, 2026-11-14: the window opened behind Finder and Finder's menu bar
        // stayed; tried before this call too, it still lost); this older call brings it forward there.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Back to no Dock icon and no menu bar once the window is gone. After the close has run, so the window is
    /// already off screen when the icon leaves and the next app takes the front in the same step.
    private func leaveDock() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isVisible, NSApp.activationPolicy() != .accessory else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func makeWindow() -> BrowserWindow {
        let (defaultSize, minSize) = windowSizes()
        let w = BrowserWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.owner = self
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.contentMinSize = minSize
        w.titlebarSeparatorStyle = .automatic
        w.toolbarStyle = .unified
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 200
        sideItem.maximumThickness = 320
        sideItem.canCollapse = true
        let mainItem = NSSplitViewItem(viewController: content)
        mainItem.titlebarSeparatorStyle = .automatic
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(mainItem)
        split.splitView.dividerStyle = .thin
        w.contentViewController = split
        if let f = store.setting("browser.frame") { w.setFrame(NSRectFromString(f), display: false) }
        else { w.setContentSize(defaultSize); w.center() }
        // Wide enough for the longest row in every language («Недавно удаленные»).
        split.splitView.setPosition(CGFloat(store.setting("browser.sidebar").flatMap(Double.init) ?? Double(Self.sidebarWidth)), ofDividerAt: 0)
        if store.setting("browser.sidebarHidden") == "1" { sideItem.isCollapsed = true }
        let tb = NSToolbar(identifier: "browser")
        tb.delegate = self
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = false
        tb.displayMode = .iconOnly
        if let d = store.setting("browser.toolbar").flatMap({ Data(base64Encoded: $0) }),
           let c = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
            tb.setConfiguration(c)
        }
        w.toolbar = tb
        toolbar = tb
        // A toolbar saved by 0.4 without them gets them back (they can't be taken out any more).
        for id in [NSToolbarItem.Identifier.view, .sortBy] where !tb.items.contains(where: { $0.itemIdentifier == id }) {
            let after = id == .sortBy ? (tb.items.firstIndex { $0.itemIdentifier == .view }.map { $0 + 1 }) : nil
            tb.insertItem(withItemIdentifier: id, at: after ?? min(2, tb.items.count))
        }
        window = w
        return w
    }

    /// The window's first size and its smallest, computed from what it shows rather than picked (his review of 0.4:
    /// 0.4 opened at 1100 × 680 with a fixed 620 × 380 minimum; HIG, Windows: «choose an initial size that minimizes
    /// empty areas», and a minimum where nothing overlaps). Default: the sidebar and five columns of icons, three rows
    /// under a day's title (his pick of 0.5's variants, ~19:05). Smallest: five columns too, two rows (his recording
    /// 2026-11-15 10:33: at three or four the toolbar's search shrank to a button; 0.5-0.7 allowed three).
    func windowSizes() -> (NSSize, NSSize) {
        let n = 5
        let side = Self.sidebarWidth + 1
        let rowH = IconItem.size(side: iconSize).height, lines: CGFloat = 12
        let chrome: CGFloat = 52 + ContentController.statusH + 34 + 8 + 16   // toolbar, status bar, a day's title, insets
        let def = NSSize(width: side + IconsView.width(columns: n, iconSize: iconSize), height: chrome + 3 * rowH + 2 * lines)
        let min = NSSize(width: side + max(IconsView.width(columns: n, iconSize: iconSize), Self.toolbarMinimum),
                         height: chrome + 2 * rowH + lines)
        return (def, min)
    }
    static let sidebarWidth: CGFloat = 230
    /// What the toolbar needs beside the sidebar: the longest pane title with its subtitle, the view switch, Sort By,
    /// Share and the search as its button (measured in the agents' session on 27.2 in ru, the longest of the three).
    static let toolbarMinimum: CGFloat = 470

    /// The window's size, sidebar, toolbar set and display mode, into the store (nothing in ~/Library/Preferences).
    func saveLayout() {
        guard let w = window else { return }
        store.setSetting("browser.frame", NSStringFromRect(w.frame))
        if let side = split.splitViewItems.first {
            store.setSetting("browser.sidebarHidden", side.isCollapsed ? "1" : "0")
            if !side.isCollapsed { store.setSetting("browser.sidebar", String(Double(side.viewController.view.frame.width))) }
        }
        if let tb = toolbar, let d = try? PropertyListSerialization.data(fromPropertyList: tb.configuration, format: .binary, options: 0) {
            store.setSetting("browser.toolbar", d.base64EncodedString())
        }
    }

    func windowWillClose(_ n: Notification) {
        saveLayout()
        leaveDock()
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared().orderOut(nil) : ()
    }
    func windowDidResize(_ n: Notification) { content.relayout() }

    // MARK: data

    /// Reads the store again and shows the pane's entries, searched and sorted; the selection keeps what is still there.
    func reload() {
        all = store.entries(deleted: pane == .deleted)
        let q = Array(fold(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        var list = all.filter { inPane($0, pane) }
        if !q.isEmpty {
            list = list.filter { e in
                let f = foldCache[e.id] ?? { let f = fold(e.searchable(shownTitle(e))); foldCache[e.id] = f; return f }()
                return f.withUnsafeBytes { h in q.withUnsafeBytes { nd in memmem(h.baseAddress, h.count, nd.baseAddress, nd.count) != nil } }
            }
        }
        shown = sorted(list)
        let ids = Set(shown.map(\.id))
        order.removeAll { !ids.contains($0) }
        updateTitle()
        content.show(pane: pane, mode: mode)
        content.items?.reload()
        content.items?.select(Set(order))
        updateStatus()
        validateToolbar()
    }

    func sorted(_ l: [Entry]) -> [Entry] {
        func cmp(_ a: Entry, _ b: Entry) -> ComparisonResult {
            switch sort {
            case .date: return a.copied == b.copied ? .orderedSame : (a.copied < b.copied ? .orderedAscending : .orderedDescending)
            case .name: return shownTitle(a).localizedStandardCompare(shownTitle(b))
            case .kind: return kindName(a).localizedStandardCompare(kindName(b))
            case .size: return a.bytes == b.bytes ? .orderedSame : (a.bytes < b.bytes ? .orderedAscending : .orderedDescending)
            case .app: return appName(a.app).localizedStandardCompare(appName(b.app))
            }
        }
        return l.sorted { a, b in
            let c = cmp(a, b)
            if c == .orderedSame { return a.copied > b.copied }   // ties: newest first, as the history
            return ascending ? c == .orderedAscending : c == .orderedDescending
        }
    }

    func entry(_ id: Int64) -> Entry? { all.first { $0.id == id } }
    var picked: [Entry] { order.compactMap(entry) }

    private func updateTitle() {
        guard let w = window else { return }
        w.title = pane == .all ? L("Clipboard") : pane.title
        // No subtitle: the status bar already counts (0.4 said «21 objects» twice; Finder's title stands alone).
        w.subtitle = ""
    }

    /// «Выбрано 4 из 14 · 3 381 символ · 519 слов · ≈ 2 737 токенов · 6,2 МБ», or the count alone.
    func updateStatus() {
        let s = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        if order.isEmpty {
            s.append(NSAttributedString(string: counted(shown.count, "object|objects"), attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        } else {
            let f = Facts(picked)
            s.append(NSAttributedString(string: String(format: L("%@ of %@ selected"), grouped(order.count), grouped(shown.count)),
                                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            if !f.parts.isEmpty {
                s.append(NSAttributedString(string: "  ·  " + f.parts.joined(separator: "  ·  "), attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        content.setStatus(s)
    }

    // MARK: selection (from the views)

    /// The view's selection changed: the order keeps what stays picked, new picks go to its end in the direction they
    /// were made; picking everything at once (⌘A) is the order of copying, oldest first, as in the panel.
    func selectionChanged(to ids: Set<Int64>, cursor: Int64? = nil) {
        let before = order
        var o = order.filter { ids.contains($0) }
        let added = shown.map(\.id).filter { ids.contains($0) && !o.contains($0) }
        if ids.count == shown.count && shown.count > 1 && added.count > 1 && before.count < shown.count - 1 {
            // ⌘A: the picks keep their numbers, the rest follow in the order of copying (as Selection.all).
            o += shown.sorted { $0.copied < $1.copied }.map(\.id).filter { !o.contains($0) }
        } else if let c = cursor, added.contains(c), added.count > 1, let ci = shown.firstIndex(where: { $0.id == c }),
                  let first = shown.firstIndex(where: { $0.id == added.first }), ci < first {
            o += added.reversed()   // a range stretched upwards: picked from the anchor up
        } else {
            o += added
        }
        order = o
        content.items?.updateBadges()
        updateStatus()
        validateToolbar()
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            window?.refreshPreviewItems()
            QLPreviewPanel.shared().reloadData()
        }
    }

    // MARK: actions

    @objc func copy(_ sender: Any?) {
        guard pane != .deleted, !order.isEmpty else { return }
        let r = Copia.write(picked.map { ($0, store.reps($0.id)) }, store: store, to: pasteboard)
        monitor?.ownCount = r.count
        copied(order, false)
        used()
    }

    /// The item menu's Paste: the picks in one write, then ⌘V into the app that was in front before this window (it
    /// comes forward; this window stays). As the panel's, it goes past an open paste queue.
    @objc func paste(_ sender: Any?) {
        guard pane != .deleted, !order.isEmpty else { return }
        let own = Copia.write(picked.map { ($0, store.reps($0.id)) }, store: store, to: pasteboard).count; monitor?.ownCount = own
        used()
        pasteInto()
    }

    @objc func pastePlain(_ sender: Any?) {
        let t = Copia.plainText(picked)
        guard pane != .deleted, !t.isEmpty else { return }
        let own = Copia.writePlain(t, to: pasteboard); monitor?.ownCount = own
        used()
        pasteInto()
    }

    @objc func showInFinderFromMenu(_ sender: Any?) { showInFinder(picked, store: store) }
    @objc func openInBrowserFromMenu(_ sender: Any?) { openInBrowser(picked) }

    /// The list keys of Settings in this window (keys.swift): the same verbs on the selection, but nothing is pasted and
    /// the window stays, so Paste's key (Return) copies and Paste as Plain Text's copies plain text (his answer
    /// 2026-11-15 ~15:35: «Return copies, the same logic as the panel»). ⌫ deletes as ⌘⌫; Esc clears the search, then the
    /// selection. Letters do nothing (his no to type-to-search).
    func itemsKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 && e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if !query.isEmpty {
                query = ""
                searchItem?.searchField.stringValue = ""
                reload()
            } else if !order.isEmpty {
                order = []
                content.items?.select([])
                selectionChanged(to: [])
            }
            return true
        }
        guard pane != .settings, let a = store.keys.action(e) else { return false }
        switch a {
        case .paste, .copy:
            guard pane != .deleted, !order.isEmpty else { return false }
            copy(nil)
            flashStatus(String(format: L("Copied: %@"), counted(order.count, "object|objects")))
        case .pastePlain:
            guard pane != .deleted, !order.isEmpty else { return false }
            copyAsPlainText(nil)
            flashStatus(String(format: L("Copied as plain text: %@"), counted(order.count, "object|objects")))
        case .delete: moveToRecentlyDeleted(nil)
        case .preview: quickLook(nil)
        case .pick: return false   // ⌘1, ⌘2, ⌘4 are Finder's views here
        }
        return true
    }

    /// Copied back: the picked entries move to the top (Store.touch), here and in the panel; the selection stays and
    /// stays in sight.
    func used() {
        store.touch(order)
        reload()
        content.items?.scrollToSelection()
        panelReload()
    }

    @objc func copyAsPlainText(_ sender: Any?) {
        let t = Copia.plainText(picked)
        guard !t.isEmpty else { return }
        let own = Copia.writePlain(t, to: pasteboard); monitor?.ownCount = own
        copied(order, true)
        used()
    }

    /// ⌘⌫: no question, into Recently Deleted; ⌘Z (Edit > Undo) brings the same items back. In Recently Deleted
    /// itself it is Finder's «Delete Immediately…», which asks, since nothing brings that back.
    @objc func moveToRecentlyDeleted(_ sender: Any?) {
        let ids = order
        guard !ids.isEmpty else { return }
        if pane == .deleted { deleteImmediately(sender); return }
        let next = nextAfter(ids)
        store.delete(ids)
        window?.undoManager?.registerUndo(withTarget: self) { $0.restore(ids) }
        window?.undoManager?.setActionName(L("Delete"))
        // The deleted items fade (150 ms, the system's ease), then the rest close up in one frame; the status bar says
        // where they went (his review of 0.4: deleting was silent).
        let views = ids.compactMap { content.items?.anchorView(for: $0) }.filter { !($0 === content.items?.anchorView(for: nil)) }
        let finish = { [weak self] in
            guard let self else { return }
            for v in views { v.alphaValue = 1 }
            self.order = next.map { [$0] } ?? []
            self.reload()
            self.panelReload()
            self.flashStatus(String(format: L("Moved to Recently Deleted: %@"), counted(ids.count, "object|objects")) + "  ·  ⌘Z")
        }
        if views.isEmpty || mode == .gallery || Ticker.manual { finish(); return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.15
            for v in views { v.animator().alphaValue = 0 }
        }, completionHandler: finish)
    }

    /// A note in the status bar for a few seconds, then the counts again.
    func flashStatus(_ text: String) {
        statusNote = text
        content.setStatus(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.statusNote == text else { return }
            self.statusNote = nil
            self.updateStatus()
        }
    }
    private var statusNote: String?

    private func restore(_ ids: [Int64]) {
        store.undelete(ids)
        window?.undoManager?.registerUndo(withTarget: self) { c in c.store.delete(ids); c.reload(); c.panelReload() }
        if pane != .deleted { order = ids }
        reload()
        content.items?.scrollToSelection()   // HIG, Undo: show what came back
        panelReload()
    }

    /// The row that takes the first deleted row's place, as the panel and Finder pick it.
    private func nextAfter(_ ids: [Int64]) -> Int64? {
        let list = shown.map(\.id)
        guard let first = list.firstIndex(where: { ids.contains($0) }) else { return nil }
        let left = list.filter { !ids.contains($0) }
        return left.isEmpty ? nil : left[min(first, left.count - 1)]
    }

    /// Recently Deleted: back into the history.
    @objc func putBack(_ sender: Any?) {
        let ids = order
        guard pane == .deleted, !ids.isEmpty else { return }
        store.undelete(ids)
        order = []
        reload()
        panelReload()
    }

    @objc func deleteImmediately(_ sender: Any?) {
        let ids = order
        guard pane == .deleted, !ids.isEmpty, let w = window else { return }
        let a = NSAlert()
        a.messageText = ids.count == 1 ? L("Delete this item immediately?") : String(format: L("Delete %@ immediately?"), counted(ids.count, "object|objects"))
        a.informativeText = L("You can’t undo this action.")
        a.addButton(withTitle: L("Delete")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            self.store.erase(ids)
            self.store.purge()
            self.order = []
            self.reload()
        }
    }

    /// Settings' «Clear Clipboard History…»: everything into Recently Deleted, after one question (the «…» promises
    /// it), and ⌘Z brings it all back.
    func clearHistory() {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = L("Clear clipboard history?")
        a.informativeText = L("Everything copied moves to Recently Deleted.")
        a.addButton(withTitle: L("Clear"))
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            let ids = self.store.entries().map(\.id)
            self.store.delete(ids)
            w.undoManager?.registerUndo(withTarget: self) { $0.restore(ids) }
            w.undoManager?.setActionName(L("Clear"))
            self.reload()
            self.panelReload()
        }
    }

    /// The panel shows the same store: it reads it again after a change made here.
    var panelReload: () -> Void = {}

    @objc func selectAll(_ sender: Any?) {
        guard pane != .settings else { return }
        content.items?.select(Set(shown.map(\.id)))
        selectionChanged(to: Set(shown.map(\.id)))
    }

    @objc func showIcons(_ sender: Any?) { setMode(.icons) }
    @objc func showList(_ sender: Any?) { setMode(.list) }
    @objc func showGallery(_ sender: Any?) { setMode(.gallery) }
    @objc func viewSwitched(_ g: NSToolbarItemGroup) { setMode(ViewMode.allCases[max(0, g.selectedIndex)]) }

    /// A view change lands in one frame, as Finder's: the new view is there with the same selection.
    func setMode(_ m: ViewMode) {
        mode = m
        if pane == .settings { pane = .all; sidebar.select(.all) }
        reload()
        if let i = ViewMode.allCases.firstIndex(of: m) { viewItem?.selectedIndex = i }
        content.items?.scrollToSelection()
    }

    @objc func sortBy(_ it: NSMenuItem) {
        guard let k = (it.representedObject as? String).flatMap(SortKey.init) else { return }
        setSort(k, ascending: k == sort ? ascending : k.ascendingFirst)
    }

    func setSort(_ k: SortKey, ascending a: Bool) {
        sort = k; ascending = a
        reload()
        content.items?.scrollToSelection()
        ViewOptions.shared.refresh()
    }

    @objc func showViewOptions(_ sender: Any?) { ViewOptions.shared.toggle(for: self) }

    @objc func quickLook(_ sender: Any?) {
        let p = QLPreviewPanel.shared()!
        if p.isVisible { p.orderOut(nil) } else { p.makeKeyAndOrderFront(nil) }
    }

    @objc func search(_ f: NSSearchField) {
        query = f.stringValue
        reload()
    }

    /// ⌘F: into the search field (a selector of its own: NSCollectionView answers Find itself and swallowed it).
    @objc func focusSearch(_ sender: Any?) {
        guard pane != .settings, let s = searchItem else { return }
        if #available(macOS 14.0, *) { s.beginSearchInteraction() }
        window?.makeFirstResponder(s.searchField)
    }

    func open(pane p: Pane) {
        guard p != pane else { return }
        pane = p
        order = []
        query = ""
        searchItem?.searchField.stringValue = ""
        reload()
        if p == .settings, QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) }
    }

    // MARK: menus

    /// The right-click on an item: the panel's menu, in its one order (menu.swift); in Recently Deleted, Finder's Trash
    /// menu (Put Back, Delete Immediately…).
    func itemMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ a: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let it = m.addItem(withTitle: t, action: a, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
        }
        if pane == .deleted {
            add(L("Put Back"), #selector(putBack(_:)))
            add(L("Delete Immediately…"), #selector(deleteImmediately(_:)), "\u{8}")
            return m
        }
        return makeItemMenu(picked, target: self, verbs: Self.verbs, keys: store.keys, openWith: openWithMenu())
    }

    static let verbs = ItemVerbs(paste: #selector(paste(_:)), pastePlain: #selector(pastePlain(_:)), copy: #selector(copy(_:)),
                                 copyPlain: #selector(copyAsPlainText(_:)), share: #selector(shareFromMenu(_:)),
                                 openInBrowser: #selector(openInBrowserFromMenu(_:)), showInFinder: #selector(showInFinderFromMenu(_:)),
                                 delete: #selector(moveToRecentlyDeleted(_:)))

    /// The right-click on empty space, as Finder's: the views, Sort By, Show View Options.
    func emptyMenu() -> NSMenu {
        let m = NSMenu()
        for v in ViewMode.allCases {
            let it = m.addItem(withTitle: v.title, action: [#selector(showIcons(_:)), #selector(showList(_:)), #selector(showGallery(_:))][ViewMode.allCases.firstIndex(of: v)!], keyEquivalent: String(v.rawValue))
            it.target = self
            v.dress(it)
        }
        m.addItem(.separator())
        let s = m.addItem(withTitle: L("Sort By"), action: nil, keyEquivalent: "")
        s.submenu = sortMenu()
        m.addItem(.separator())
        let o = m.addItem(withTitle: L("Show View Options"), action: #selector(showViewOptions(_:)), keyEquivalent: "j")
        o.target = self
        return m
    }

    func sortMenu() -> NSMenu {
        let m = NSMenu()
        for k in SortKey.allCases {
            let it = m.addItem(withTitle: k.title, action: #selector(sortBy(_:)), keyEquivalent: "")
            it.representedObject = k.rawValue
            it.target = self
        }
        return m
    }

    private var shareAnchor: NSView?
    @objc func shareFromMenu(_ sender: Any?) {
        let items = shareItems()
        guard !items.isEmpty, let v = content.items?.anchorView(for: order.last) ?? content.view as NSView? else { return }
        NSSharingServicePicker(items: items).show(relativeTo: v.bounds, of: v, preferredEdge: .maxY)
    }

    func shareItems() -> [Any] {
        picked.flatMap { e -> [Any] in
            switch e.kind {
            case .image, .files: return entryFiles(e, store: store)
            default: return [e.text]
            }
        }
    }

    func openWithMenu() -> NSMenu {
        let m = NSMenu()
        guard picked.count == 1, let e = picked.first, let u = entryFiles(e, store: store, forOpening: true).first else { return m }
        let def = NSWorkspace.shared.urlForApplication(toOpen: u)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: u)
        if let def { apps.removeAll { $0 == def }; apps.insert(def, at: 0) }
        for a in apps.prefix(12) {
            let it = m.addItem(withTitle: FileManager.default.displayName(atPath: a.path).replacingOccurrences(of: ".app", with: ""),
                               action: #selector(openWith(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = (a, [u])
            let icon = NSWorkspace.shared.icon(forFile: a.path)
            icon.size = NSSize(width: 16, height: 16)
            it.image = icon
            // macOS 27 hides menu images unless the item asks (seen on 27.2 in the agents' session, 2026-11-14)
            if #available(macOS 27.0, *) { it.preferredImageVisibility = .visible }
            if a == def && apps.count > 1 { m.addItem(.separator()) }
        }
        return m
    }

    @objc func openWith(_ it: NSMenuItem) {
        guard let (app, urls) = it.representedObject as? (URL, [URL]) else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func validateMenuItem(_ it: NSMenuItem) -> Bool {
        let list = pane != .settings
        switch it.action {
        case #selector(copy(_:)), #selector(copyAsPlainText(_:)), #selector(shareFromMenu(_:)):
            return list && pane != .deleted && !order.isEmpty
        case #selector(moveToRecentlyDeleted(_:)), #selector(quickLook(_:)):
            return list && !order.isEmpty
        case #selector(putBack(_:)), #selector(deleteImmediately(_:)):
            return pane == .deleted && !order.isEmpty
        case #selector(selectAll(_:)): return list && !shown.isEmpty
        case #selector(showIcons(_:)): it.state = mode == .icons && list ? .on : .off; return true
        case #selector(showList(_:)): it.state = mode == .list && list ? .on : .off; return true
        case #selector(showGallery(_:)): it.state = mode == .gallery && list ? .on : .off; return true
        case #selector(sortBy(_:)): it.state = (it.representedObject as? String) == sort.rawValue ? .on : .off; return list
        case #selector(showViewOptions(_:)):
            it.title = ViewOptions.shared.isVisible ? L("Hide View Options") : L("Show View Options")
            return true
        default: return true
        }
    }

    /// Items that act on a selection follow it; in Settings the list's tools step aside, as the approved mockup
    /// shows the settings pane with its title alone.
    func validateToolbar() {
        for it in toolbar?.items ?? [] {
            switch it.itemIdentifier {
            case .delete, .quickLook: it.isEnabled = pane != .settings && !order.isEmpty
            case .share: it.isEnabled = pane != .settings && pane != .deleted && !order.isEmpty
            default: break
            }
            if #available(macOS 15.0, *), [.view, .sortBy, .share, .delete, .quickLook, .search].contains(it.itemIdentifier) {
                it.isHidden = pane == .settings
            } else if [.view, .sortBy, .search].contains(it.itemIdentifier) {
                it.isEnabled = pane != .settings
            }
        }
    }
}

// MARK: the window and Quick Look

final class BrowserWindow: NSWindow, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var owner: BrowserController?
    private var previewURLs: [URL] = []
    /// One file per entry for as long as the window lives: Quick Look finds the item again by its URL to zoom out of
    /// its picture (a new temporary file on every call made it fade in instead; test machine, 2026-11-14).
    private var files: [Int64: URL] = [:]

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        refreshPreviewItems()
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    /// What Quick Look shows: the picked items in pick order, each as a real file (a text as a .txt or .rtf, made in
    /// paste/, which lives 24 h); the one under the cursor first when it is picked.
    func refreshPreviewItems() {
        guard let o = owner else { previewURLs = []; return }
        previewURLs = o.picked.compactMap { e in
            if let u = files[e.id], FileManager.default.fileExists(atPath: u.path) { return u }
            let u = entryFiles(e, store: o.store, forOpening: true).first
            files[e.id] = u
            return u
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt i: Int) -> QLPreviewItem! { previewURLs[i] as NSURL }

    /// Quick Look zooms out of the item's picture and back into it (its own motion, Apple's).
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let o = owner, let u = item.previewItemURL, let i = previewURLs.firstIndex(of: u), i < o.order.count,
              let r = o.content.items?.pictureRect(for: o.order[i]) else { return .zero }
        return r
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle e: NSEvent!) -> Bool {
        // The arrows move the selection in the view under Quick Look, as in Finder.
        if e.type == .keyDown, [123, 124, 125, 126].contains(e.keyCode), let v = owner?.content.items?.keyView {
            v.keyDown(with: e)
            return true
        }
        return false
    }
}

extension NSToolbarItem.Identifier {
    static let view = Self("view"), sortBy = Self("sort"), share = Self("share"), delete = Self("delete")
    static let quickLook = Self("quicklook"), search = Self("search")
}

extension BrowserController: NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSSearchFieldDelegate {
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .view, .sortBy, .flexibleSpace, .share, .search]
    }

    /// View and Sort By stay in the toolbar whatever is customised (his recording: Sort By removed left no visible way
    /// to sort). HIG, Toolbars: the toolbar can't be the only place for a command, so sorting is also in the View menu
    /// and on a right-click on empty space, as in Finder.
    func toolbarImmovableItemIdentifiers(_ t: NSToolbar) -> Set<NSToolbarItem.Identifier> { [.view, .sortBy] }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .view, .sortBy, .share, .delete, .quickLook, .search, .space, .flexibleSpace]
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .view:
            let g = NSToolbarItemGroup(itemIdentifier: id, images: ViewMode.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
                                       selectionMode: .selectOne, labels: ViewMode.allCases.map(\.title), target: self, action: #selector(viewSwitched(_:)))
            g.label = L("View")
            g.paletteLabel = L("View")
            g.controlRepresentation = .automatic
            g.selectedIndex = ViewMode.allCases.firstIndex(of: mode) ?? 0
            viewItem = g
            return g
        case .sortBy:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: L("Sort By"))
            it.label = L("Sort By"); it.paletteLabel = L("Sort By")
            it.menu = sortMenu()
            it.showsIndicator = true
            return it
        case .share:
            let it = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            it.label = L("Share"); it.paletteLabel = L("Share")
            it.delegate = self
            return it
        case .delete:
            let it = NSToolbarItem(itemIdentifier: id)
            it.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("Delete"))
            it.label = L("Delete"); it.paletteLabel = L("Delete")
            it.target = self; it.action = #selector(moveToRecentlyDeleted(_:))
            it.autovalidates = false
            return it
        case .quickLook:
            let it = NSToolbarItem(itemIdentifier: id)
            it.image = NSImage(systemSymbolName: "eye", accessibilityDescription: L("Quick Look"))
            it.label = L("Quick Look"); it.paletteLabel = L("Quick Look")
            it.target = self; it.action = #selector(quickLook(_:))
            it.autovalidates = false
            return it
        case .search:
            let it = NSSearchToolbarItem(itemIdentifier: id)
            it.label = L("Search"); it.paletteLabel = L("Search")
            it.searchField.placeholderString = L("Search")
            it.searchField.target = self
            it.searchField.action = #selector(search(_:))
            it.searchField.sendsSearchStringImmediately = true
            it.searchField.delegate = self
            searchItem = it
            return it
        default:
            return nil
        }
    }

    func toolbarWillAddItem(_ n: Notification) { validateToolbar() }

    func items(for item: NSSharingServicePickerToolbarItem) -> [Any] { shareItems() }
}
