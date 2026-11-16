// Settings (the big window's last sidebar row; his approved round-3 Г, without the Recently Deleted row): the hot key,
// open at login, the paste queue, the keys of the lists (every key settable, his word 2026-11-15: keys.swift), with a
// warning when two are the same, how long the history is kept, and clearing it. Grouped rows as System Settings draws them. Then Finder's
// View Options panel (⌘J) and the app's menus (hidden while the app has no menu bar of its own, yet they carry the keys).
import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: the hot key, stored

struct HotKey: Equatable {
    var code: UInt32, mods: UInt32   // Carbon modifiers (cmdKey, optionKey, …)
    static let standard = HotKey(code: UInt32(kVK_ANSI_C), mods: UInt32(cmdKey | optionKey))   // ⌥⌘C, his key
    /// The paste queue's key, his idea 2026-11-15: ⌃⌥C, the panel's letter with ⌃ for ⌘ (free on macOS 27.2: no
    /// system or Finder shortcut uses it).
    static let queue = HotKey(code: UInt32(kVK_ANSI_C), mods: UInt32(controlKey | optionKey))

    init(code: UInt32, mods: UInt32) { self.code = code; self.mods = mods }
    init?(_ s: String) {
        let p = s.split(separator: ":").compactMap { UInt32($0) }
        guard p.count == 2 else { return nil }
        code = p[0]; mods = p[1]
    }
    var stored: String { "\(code):\(mods)" }

    /// «⌥⌘C», in the order macOS writes modifiers (⌃⌥⇧⌘).
    var text: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(UInt16(code))
    }

    static func from(_ e: NSEvent) -> HotKey? {
        let f = e.modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        // A global key needs ⌘, ⌥ or ⌃: a plain letter would be taken from every app.
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        // ⌘ alone would take an app's own command from every app (⌘V, ⌘C, ⌘Q): with ⇧, ⌥ or ⌃ it is a global key
        // (security pass 2026-11-15).
        guard m != UInt32(cmdKey) else { return nil }
        return HotKey(code: UInt32(e.keyCode), mods: m)
    }
}

/// The key's printed name on the current keyboard layout (the letter the person sees on the key).
func keyName(_ code: UInt16) -> String {
    let special: [UInt16: String] = [49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓",
                                     126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
                                     96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
    if let s = special[code] { return code == 49 ? L("Space") : s }
    guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
    let data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
    var dead: UInt32 = 0, len = 0
    var chars = [UniChar](repeating: 0, count: 4)
    data.withUnsafeBytes { b in
        _ = UCKeyTranslate(b.bindMemory(to: UCKeyboardLayout.self).baseAddress, code, UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
    }
    return String(utf16CodeUnits: chars, count: len).uppercased()
}

extension Store {
    var hotKey: HotKey {
        get { setting("hotkey").flatMap(HotKey.init) ?? .standard }
        set { setSetting("hotkey", newValue.stored) }
    }
    /// The paste queue's order (his word 2026-11-15): the order of copying, or the newest first. Photos' words.
    var newestFirst: Bool {
        get { setting("queueorder") == "newest" }
        set { setSetting("queueorder", newValue ? "newest" : "oldest") }
    }
    var queueKey: HotKey {
        get { setting("queuekey").flatMap(HotKey.init) ?? .queue }
        set { setSetting("queuekey", newValue.stored) }
    }
}

extension Keep {
    var title: String {
        switch self {
        case .day1: L("1 Day"); case .days7: L("7 Days"); case .days30: L("30 Days"); case .year1: L("1 Year"); case .forever: L("Forever")
        }
    }
}

/// Open at Login: the agent in the bundle (./build writes it; main.swift, --login), as in the other apps.
let loginItem = SMAppService.agent(plistName: "\(Bundle.main.bundleIdentifier ?? "com.geragaraza.copia").login.plist")

// MARK: the settings pane

final class SettingsView: FlippedLayout {
    weak var owner: BrowserController?
    private let column = FlippedView()
    private let recorder = ShortcutButton()
    private let queueRecorder = ShortcutButton()
    private let order = NSPopUpButton()
    private let login = NSSwitch()
    private let keep = NSPopUpButton()
    private let position = NSPopUpButton()
    private let clear = NSButton()
    private let pasteRec = ShortcutButton(local: true)
    private let plainPop = NSPopUpButton()
    private let copyRec = ShortcutButton(local: true)
    private let deleteRec = ShortcutButton(local: true)
    private let previewRec = ShortcutButton(local: true)
    private let pickPop = NSPopUpButton()
    private let access = AccessRow()
    /// What clashes, under the keys (nothing when none).
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private(set) var groups: [GroupBox] = []
    /// Rows in each group, as built in init (a test checks the two agree): the window's smallest height comes from it.
    static let groupRows = [3, 2, 7, 1, 1]
    /// The column's height with every group and no clash warning (place(): 24 above, 12 after each group, 12 below).
    static var columnHeight: CGFloat { 24 + groupRows.reduce(0) { $0 + CGFloat($1) * GroupBox.rowH + 12 } + 12 }
    /// Where the warning goes: after this group.
    private var warnAfter = 2

    init(owner: BrowserController) {
        self.owner = owner
        super.init(frame: .zero)
        addSubview(column)

        recorder.onChange = { [weak self] k in
            guard let o = self?.owner else { return }
            o.store.hotKey = k
            o.onHotKeyChange?()
            self?.refresh()
        }
        queueRecorder.onChange = { [weak self] k in
            guard let o = self?.owner else { return }
            o.store.queueKey = k
            o.onHotKeyChange?()
            self?.refresh()
        }
        let keyRecorders: [(ShortcutButton, WritableKeyPath<Keys, HotKey>)] = [(pasteRec, \.paste), (copyRec, \.copy),
                                                                              (deleteRec, \.delete), (previewRec, \.preview)]
        for (r, path) in keyRecorders {
            r.onChange = { [weak self] k in self?.setKeys { $0[keyPath: path] = k } }
        }
        plainPop.target = self; plainPop.action = #selector(plainChanged); plainPop.isBordered = false
        pickPop.target = self; pickPop.action = #selector(pickChanged); pickPop.isBordered = false
        access.allow = { [weak self] in self?.owner?.allowPasting() }
        warning.font = .systemFont(ofSize: 12)
        warning.textColor = .systemRed
        warning.isHidden = true
        order.addItems(withTitles: [L("Oldest First"), L("Newest First")])
        order.target = self; order.action = #selector(orderChanged)
        order.isBordered = false
        login.target = self; login.action = #selector(loginChanged)
        // The periods, then the open end after a separator, as STT's Mac pop-up groups them.
        for k in Keep.allCases {
            if k == .forever { keep.menu?.addItem(.separator()) }
            keep.addItem(withTitle: k.title); keep.lastItem?.representedObject = k.rawValue
        }
        keep.target = self; keep.action = #selector(keepChanged)
        keep.isBordered = false
        // The panel's place, as the Dock's «Position on screen»: the fifteen places (place.swift), also reached by
        // dragging the panel by its edge; for the screen it opens on now (each screen keeps its own). Fifteen names
        // alone are hard to tell apart, so each carries a small screen with the panel at its place.
        for p in Place.allCases {
            position.addItem(withTitle: p.title)
            position.lastItem?.representedObject = p.rawValue
            position.lastItem?.image = placePicture(p)
        }
        position.menu?.insertItem(.separator(), at: 5); position.menu?.insertItem(.separator(), at: 11)   // by rows
        position.target = self; position.action = #selector(positionChanged)
        position.isBordered = false
        clear.title = L("Clear Clipboard History…")
        clear.bezelStyle = .push
        clear.target = self; clear.action = #selector(clearHistory)

        groups = [
            GroupBox(rows: [(L("Show History"), recorder), (L("Position on Screen"), position), (L("Open at Login"), login)]),
            GroupBox(rows: [(L("Paste Queue"), queueRecorder), (L("Paste Order"), order)]),
            GroupBox(rows: [(L("Paste"), pasteRec), (L("Paste as Plain Text"), plainPop), (L("Copy"), copyRec), (L("Delete"), deleteRec),
                            (L("Preview"), previewRec), (L("Quick Pick"), pickPop), (L("Paste into Apps"), access)]),
            GroupBox(rows: [(L("Keep History"), keep)]),
            GroupBox(rows: [("", clear)], centered: true),
        ]
        for g in groups { column.addSubview(g) }
        column.addSubview(warning)
        // The groups scroll when the window is shorter than they are (the keys made them taller than its smallest size).
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = column
        addSubview(scroll)
        onLayout = { [weak self] in self?.place() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()   // back from System Settings: Paste into Apps may be on now
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The groups are taller than the room: the pane scrolls (tests).
    var scrolls: Bool { layoutSubtreeIfNeeded(); place(); return column.frame.height > scroll.contentSize.height + 0.5 }

    func refresh() {
        guard let o = owner else { return }
        recorder.key = o.store.hotKey
        queueRecorder.key = o.store.queueKey
        order.selectItem(at: o.store.newestFirst ? 1 : 0)
        login.state = loginItem.status == .enabled ? .on : .off
        keep.selectItem(withTitle: o.store.keep.title)
        let p = NSScreen.main.flatMap { o.store.setting("place." + screenKey($0)).flatMap(Place.init) } ?? .standard
        position.selectItem(withTitle: p.title)
        let k = o.store.keys
        pasteRec.key = k.paste; copyRec.key = k.copy; deleteRec.key = k.delete; previewRec.key = k.preview
        plainPop.removeAllItems()
        for m in PlainMod.allCases {
            plainPop.addItem(withTitle: m == .fn ? "fn " + k.paste.text : HotKey(code: k.paste.code, mods: k.paste.mods | m.carbon).text)
            plainPop.lastItem?.representedObject = m.rawValue
        }
        plainPop.selectItem(at: PlainMod.allCases.firstIndex(of: k.plain) ?? 1)
        pickPop.removeAllItems()
        for m in PickMod.allCases {
            pickPop.addItem(withTitle: "\(m.symbol)1 – \(m.symbol)9"); pickPop.lastItem?.representedObject = m.rawValue
        }
        pickPop.selectItem(at: PickMod.allCases.firstIndex(of: k.pick) ?? 0)
        access.allowed = Paster().allowed()
        // Turned on since Copia started: only a fresh copy of Copia can tell (paste.swift).
        if !access.allowed && !trialDeny {
            DispatchQueue.global(qos: .utility).async {
                guard Paster.runFresh(pid: 0) else { return }
                DispatchQueue.main.async { [weak self] in Paster.allowedFresh = true; self?.access.allowed = true }
            }
        }
        let clashes = keyClashes(show: o.store.hotKey, queue: o.store.queueKey, keys: k)
        warning.stringValue = clashes.joined(separator: "\n")
        warning.isHidden = clashes.isEmpty
        place()
    }

    private func setKeys(_ change: (inout Keys) -> Void) {
        guard let o = owner else { return }
        var k = o.store.keys
        change(&k)
        o.store.keys = k
        o.onKeysChange()
        refresh()
    }

    @objc private func plainChanged() {
        guard let m = (plainPop.selectedItem?.representedObject as? String).flatMap(PlainMod.init) else { return }
        setKeys { $0.plain = m }
    }

    @objc private func pickChanged() {
        guard let m = (pickPop.selectedItem?.representedObject as? String).flatMap(PickMod.init) else { return }
        setKeys { $0.pick = m }
    }

    @objc private func orderChanged() { owner?.store.newestFirst = order.indexOfSelectedItem == 1 }

    @objc private func positionChanged() {
        guard let o = owner, let p = (position.selectedItem?.representedObject as? String).flatMap(Place.init), let s = NSScreen.main else { return }
        o.onPlaceChange?(p, s)
    }

    private func place() {
        // Under the toolbar, a column as System Settings' (its forms are 500-600 pt wide), centred.
        let top = (window?.contentLayoutRect.minY).map { _ in safeAreaInsets.top } ?? 0
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let w = min(580, bounds.width - 48)
        let x = (bounds.width - w) / 2
        var y: CGFloat = 24
        for (i, g) in groups.enumerated() {
            g.frame = NSRect(x: x, y: y, width: w, height: g.height); g.layoutRows(); y += g.height + 12
            if i == warnAfter && !warning.isHidden {
                warning.preferredMaxLayoutWidth = w - 24
                let h = warning.sizeThatFits(NSSize(width: w - 24, height: 1000)).height
                warning.frame = NSRect(x: x + 12, y: y - 6, width: w - 24, height: h)
                y += h + 8
            }
        }
        column.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y + 12, scroll.contentSize.height))
    }

    @objc private func loginChanged() {
        // A trial never touches the person's login items.
        guard !trial else { return }
        do {
            if login.state == .on {
                if loginItem.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } else { try loginItem.register() }
            } else {
                try loginItem.unregister()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    /// A shorter period removes older copies for good, so it asks first when there are any, as Messages does when
    /// «Keep Messages» is shortened (0.5 removed them at once, with no way back).
    @objc private func keepChanged() {
        guard let o = owner, let k = (keep.selectedItem?.representedObject as? String).flatMap(Keep.init) else { return }
        let apply = {
            o.store.keep = k
            o.store.purge()
            o.reload()
            o.panelReload()
        }
        let n = o.store.olderThan(k)
        guard n > 0, let w = window else { apply(); return }
        let a = NSAlert()
        a.messageText = String(format: L("Delete %@ immediately?"), counted(n, "object|objects"))
        a.informativeText = L("You can’t undo this action.")
        a.addButton(withTitle: L("Delete")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: w) { r in
            if r == .alertFirstButtonReturn { apply() } else { self.refresh() }
        }
    }

    @objc private func clearHistory() { owner?.clearHistory() }
}

/// A group of rows on a soft plate with hairlines between them, as System Settings draws a form section.
final class GroupBox: NSView {
    private let rows: [(NSTextField, NSView)]
    private let centered: Bool
    private var lines: [Separator] = []
    static let rowH: CGFloat = 40
    override var isFlipped: Bool { true }

    init(rows r: [(String, NSView)], centered c: Bool = false) {
        rows = r.map { (NSTextField(labelWithString: $0.0), $0.1) }
        centered = c
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        for (i, (l, v)) in rows.enumerated() {
            l.font = .systemFont(ofSize: 13)
            addSubview(l); addSubview(v)
            if i > 0 { let s = Separator(); lines.append(s); addSubview(s) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat { CGFloat(rows.count) * Self.rowH }
    var rowCount: Int { rows.count }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.06 : 0.035).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 0.5
    }
    override var wantsUpdateLayer: Bool { true }

    func layoutRows() {
        let w = bounds.width
        for (i, (l, v)) in rows.enumerated() {
            let y = CGFloat(i) * Self.rowH
            (v as? NSControl)?.sizeToFit()
            let vs = v.fittingSize.width > 0 ? v.fittingSize : v.frame.size
            if centered {
                v.frame = NSRect(x: (w - vs.width) / 2, y: y + (Self.rowH - vs.height) / 2, width: vs.width, height: vs.height)
            } else {
                l.frame = NSRect(x: 12, y: y + (Self.rowH - 17) / 2, width: w - 24 - vs.width - 12, height: 17)
                v.frame = NSRect(x: w - 10 - vs.width, y: y + (Self.rowH - vs.height) / 2, width: vs.width, height: vs.height)
            }
            if i > 0 { lines[i - 1].frame = NSRect(x: 12, y: y, width: w - 24, height: 1) }
        }
    }
}

/// The shortcut field: shows the key; clicked, it waits for the next combination (Esc keeps the old one). A global hot
/// key needs ⌘, ⌥ or ⌃; a list key (`local`) may be any key, Return or ⌫ alone too.
final class ShortcutButton: NSButton {
    var key = HotKey.standard { didSet { show() } }
    var onChange: ((HotKey) -> Void)?
    private var monitor: Any?
    let local: Bool

    init(local: Bool = false) {
        self.local = local
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .regular
        target = self; action = #selector(begin)
        show()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show() { title = monitor == nil ? key.text : L("Press Keys"); sizeToFit(); frame.size.width = max(frame.width, 72) }

    @objc private func begin() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.end(); return nil }
            if let k = self.local ? HotKey.local(e) : HotKey.from(e) { self.key = k; self.end(); self.onChange?(k) }
            return nil
        }
        show()
    }

    private func end() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        show()
    }
}

/// Paste into Apps: «On» when macOS lets Copia press ⌘V, else a button that asks (App.explainPasting).
final class AccessRow: NSView {
    private let state = NSTextField(labelWithString: "")
    private let button = NSButton(title: L("Allow…"), target: nil, action: nil)
    var allow: () -> Void = {}
    var allowed = false { didSet { state.isHidden = !allowed; button.isHidden = allowed; invalidateIntrinsicContentSize() } }

    init() {
        super.init(frame: .zero)
        state.stringValue = L("On")
        state.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 13)
        button.bezelStyle = .push
        button.target = self; button.action = #selector(tap)
        addSubview(state); addSubview(button)
        allowed = false
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tap() { allow() }

    override var fittingSize: NSSize {
        state.sizeToFit(); button.sizeToFit()
        let v: NSView = allowed ? state : button
        return v.frame.size
    }
    override func layout() {
        super.layout()
        let v: NSView = allowed ? state : button
        v.frame = NSRect(x: bounds.width - v.frame.width, y: (bounds.height - v.frame.height) / 2, width: v.frame.width, height: v.frame.height)
    }
    override var isFlipped: Bool { true }
}

// MARK: View Options (⌘J)

/// Finder's View Options: a small floating panel for the window in front, what each view can change, applied at once.
final class ViewOptions: NSObject, NSWindowDelegate {
    static let shared = ViewOptions()
    private var panel: NSPanel?
    private weak var owner: BrowserController?
    private let content = FlippedView()
    private let size = NSSlider(value: 64, minValue: 32, maxValue: 128, target: nil, action: nil)
    private let sort = NSPopUpButton()
    private var checks: [SortKey: NSButton] = [:]

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(for o: BrowserController) {
        if isVisible { panel?.orderOut(nil); return }
        owner = o
        let p = panel ?? make()
        refresh()
        if let w = o.window, !p.isVisible {
            p.setFrameTopLeftPoint(NSPoint(x: w.frame.maxX + 12, y: w.frame.maxY - 40))
            if let s = w.screen, p.frame.maxX > s.visibleFrame.maxX { p.setFrameTopLeftPoint(NSPoint(x: w.frame.maxX - p.frame.width - 20, y: w.frame.maxY - 60)) }
        }
        if trial { p.orderFrontRegardless() } else { p.orderFront(nil) }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200), styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = content
        size.target = self; size.action = #selector(sizeChanged)
        size.isContinuous = true
        for k in SortKey.allCases { sort.addItem(withTitle: k.title); sort.lastItem?.representedObject = k.rawValue }
        sort.target = self; sort.action = #selector(sortChanged)
        for k in [SortKey.date, .size, .kind, .app] {
            let b = NSButton(checkboxWithTitle: k.title, target: self, action: #selector(columnsChanged))
            checks[k] = b
        }
        panel = p
        return p
    }

    /// The panel shows only what the view in front can change: icon size for Icons, columns for List, Sort By for all.
    func refresh() {
        guard let o = owner, let p = panel else { return }
        p.title = o.window?.title ?? ""
        for v in content.subviews { v.removeFromSuperview() }
        var y: CGFloat = 16
        let w: CGFloat = 260
        func label(_ s: String) {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13)
            l.frame = NSRect(x: 16, y: y, width: w - 32, height: 17)
            content.addSubview(l)
            y += 22
        }
        if o.mode == .icons {
            label(L("Icon size:"))
            size.doubleValue = Double(o.iconSize)
            size.frame = NSRect(x: 16, y: y, width: w - 32, height: 24)
            content.addSubview(size)
            y += 36
        }
        label(L("Sort By:"))
        sort.selectItem(at: SortKey.allCases.firstIndex(of: o.sort) ?? 0)
        sort.frame = NSRect(x: 14, y: y, width: w - 28, height: 26)
        content.addSubview(sort)
        y += 38
        if o.mode == .list {
            label(L("Show Columns:"))
            for k in [SortKey.date, .size, .kind, .app] {
                let b = checks[k]!
                b.state = o.columns.contains(k) ? .on : .off
                b.frame = NSRect(x: 24, y: y, width: w - 40, height: 20)
                content.addSubview(b)
                y += 24
            }
            y += 8
        }
        p.setContentSize(NSSize(width: w, height: y + 4))
    }

    @objc private func sizeChanged() {
        guard let o = owner else { return }
        o.iconSize = CGFloat(size.doubleValue.rounded())
        o.content.items?.reload()
        o.content.items?.select(Set(o.order))
    }

    @objc private func sortChanged() {
        guard let o = owner, let k = (sort.selectedItem?.representedObject as? String).flatMap(SortKey.init) else { return }
        o.setSort(k, ascending: k == o.sort ? o.ascending : k.ascendingFirst)
    }

    @objc private func columnsChanged() {
        guard let o = owner else { return }
        o.columns = [SortKey.date, .size, .kind, .app].filter { checks[$0]?.state == .on }
        o.reload()
    }
}

// MARK: menus

/// The app's menus. The menu bar shows while the big window is open (the app then has a Dock icon: browser.swift,
/// «Dock»); with only the panel there is none on screen, yet AppKit still finds key equivalents here. The app menu is
/// the standard one (About, Settings…, Services, Hide, Hide Others, Show All, Quit) in the words of Apple's own apps
/// (TextEdit, Stickies: «О приложении %@», «Про %@»); the View menu is also the toolbar's and the right click's.
func makeMainMenu(settings: Selector, target: AnyObject) -> NSMenu {
    let main = NSMenu()
    func sub(_ title: String, _ items: [NSMenuItem]) {
        let m = NSMenu(title: title)
        for i in items { m.addItem(i) }
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = m
        main.addItem(top)
    }
    func it(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, target tg: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
        i.keyEquivalentModifierMask = mods
        i.target = tg
        return i
    }
    func viewItem(_ v: ViewMode, _ a: Selector) -> NSMenuItem { let i = it(v.title, a, String(v.rawValue)); v.dress(i); return i }
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Copia"
    let services = NSMenu(title: L("Services"))
    let servicesItem = it(L("Services"), nil)
    servicesItem.submenu = services
    NSApp.servicesMenu = services
    sub(name, [
        it(String(format: L("About %@"), name), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
        it(L("Check for Updates…"), #selector(App.checkForUpdates), target: target), .separator(),
        it(L("Settings…"), settings, ",", target: target), .separator(),
        servicesItem, .separator(),
        it(String(format: L("Hide %@"), name), #selector(NSApplication.hide(_:)), "h"),
        it(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        it(L("Show All"), #selector(NSApplication.unhideAllApplications(_:)), ""), .separator(),
        it(String(format: L("Quit %@"), name), #selector(NSApplication.terminate(_:)), "q"),
    ])
    let sortItem = it(L("Sort By"), nil)
    let sortMenu = NSMenu()
    for k in SortKey.allCases {
        let i = it(k.title, #selector(BrowserController.sortBy(_:)))
        i.representedObject = k.rawValue
        sortMenu.addItem(i)
    }
    sortItem.submenu = sortMenu
    sub(L("Edit"), [
        it(L("Undo"), Selector(("undo:")), "z"), it(L("Redo"), Selector(("redo:")), "z", [.command, .shift]), .separator(),
        it(L("Cut"), #selector(NSText.cut(_:)), "x"), it(L("Copy"), #selector(NSText.copy(_:)), "c"),
        it(L("Copy as Plain Text"), #selector(BrowserController.copyAsPlainText(_:)), "c", [.command, .option, .shift]),
        it(L("Paste"), #selector(NSText.paste(_:)), "v"),
        it(L("Delete"), #selector(BrowserController.moveToRecentlyDeleted(_:)), "\u{8}"),
        it(L("Select All"), #selector(NSText.selectAll(_:)), "a"), .separator(),
        it(L("Search"), #selector(BrowserController.focusSearch(_:)), "f"),
    ])
    sub(L("View"), [
        viewItem(.icons, #selector(BrowserController.showIcons(_:))),
        viewItem(.list, #selector(BrowserController.showList(_:))),
        viewItem(.gallery, #selector(BrowserController.showGallery(_:))), .separator(),
        sortItem, .separator(),
        it(L("Quick Look"), #selector(BrowserController.quickLook(_:)), "y"), .separator(),
        it(L("Show Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
        it(L("Hide Toolbar"), #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
        it(L("Customize Toolbar…"), #selector(NSWindow.runToolbarCustomizationPalette(_:))), .separator(),
        it(L("Show View Options"), #selector(BrowserController.showViewOptions(_:)), "j"),
    ])
    sub(L("Window"), [
        it(L("Close"), #selector(NSWindow.performClose(_:)), "w"),
        it(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"), .separator(),
        it(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
    ])
    NSApp.windowsMenu = main.items.last?.submenu   // AppKit adds the window list and the system's tiling items
    return main
}

/// A place in the Position on Screen menu: a screen 20 × 13 pt and the panel in it, drawn as the places stand on a
/// 16-inch screen (PlaceGrid), as a template so it takes the menu's own colour, light, dark or highlighted.
func placePicture(_ p: Place) -> NSImage {
    let size = NSSize(width: 22, height: 15)
    let img = NSImage(size: size, flipped: true) { _ in
        let screen = NSRect(x: 0.75, y: 0.75, width: size.width - 1.5, height: size.height - 1.5)
        let frame = NSBezierPath(roundedRect: screen, xRadius: 2.5, yRadius: 2.5)
        frame.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.45).setStroke(); frame.stroke()
        // The panel: 640 pt of 1728 wide, its full 546 of 1117 tall, inside the screen's 2 pt inset.
        let inner = screen.insetBy(dx: 2, dy: 2)
        let w = (inner.width * 640 / 1728 * 2).rounded() / 2, h = (inner.height * 0.42 * 2).rounded() / 2
        let x = inner.minX + (inner.width - w) * CGFloat(p.column.rawValue) / 4
        let y = inner.minY + (inner.height - h) * CGFloat(p.row.rawValue) / 2
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 1, yRadius: 1).fill()
        return true
    }
    img.isTemplate = true
    return img
}
