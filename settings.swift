// Settings (the big window's last sidebar row; his approved round-3 Г, without the Recently Deleted row): the hot key,
// open at login, how long the history is kept, and clearing it. Grouped rows as System Settings draws them. Then Finder's
// View Options panel (⌘J) and the app's menus (hidden while the app has no menu bar of its own, yet they carry the keys).
import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: the hot key, stored

struct HotKey: Equatable {
    var code: UInt32, mods: UInt32   // Carbon modifiers (cmdKey, optionKey, …)
    static let standard = HotKey(code: UInt32(kVK_ANSI_C), mods: UInt32(cmdKey | optionKey))   // ⌥⌘C, his key

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
        return HotKey(code: UInt32(e.keyCode), mods: m)
    }
}

/// The key's printed name on the current keyboard layout (the letter the person sees on the key).
func keyName(_ code: UInt16) -> String {
    let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
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
}

extension Keep {
    var title: String { switch self { case .days30: L("30 Days"); case .year1: L("1 Year"); case .forever: L("Forever") } }
}

/// Open at Login: the agent in the bundle (./build writes it; main.swift, --login), as in the other apps.
let loginItem = SMAppService.agent(plistName: "\(Bundle.main.bundleIdentifier ?? "com.geragaraza.copia").login.plist")

// MARK: the settings pane

final class SettingsView: FlippedLayout {
    weak var owner: BrowserController?
    private let column = FlippedView()
    private let recorder = ShortcutButton()
    private let login = NSSwitch()
    private let keep = NSPopUpButton()
    private let clear = NSButton()
    private var groups: [GroupBox] = []

    init(owner: BrowserController) {
        self.owner = owner
        super.init(frame: .zero)
        addSubview(column)

        recorder.onChange = { [weak self] k in
            guard let o = self?.owner else { return }
            o.store.hotKey = k
            o.onHotKeyChange?()
        }
        login.target = self; login.action = #selector(loginChanged)
        for k in Keep.allCases { keep.addItem(withTitle: k.title); keep.lastItem?.representedObject = k.rawValue }
        keep.target = self; keep.action = #selector(keepChanged)
        keep.isBordered = false
        clear.title = L("Clear Clipboard History…")
        clear.bezelStyle = .push
        clear.target = self; clear.action = #selector(clearHistory)

        groups = [
            GroupBox(rows: [(L("Show History"), recorder), (L("Open at Login"), login)]),
            GroupBox(rows: [(L("Keep History"), keep)]),
            GroupBox(rows: [("", clear)], centered: true),
        ]
        for g in groups { column.addSubview(g) }
        onLayout = { [weak self] in self?.place() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard let o = owner else { return }
        recorder.key = o.store.hotKey
        login.state = loginItem.status == .enabled ? .on : .off
        keep.selectItem(at: Keep.allCases.firstIndex(of: o.store.keep) ?? 0)
    }

    private func place() {
        // Under the toolbar, a column as System Settings' (its forms are 500-600 pt wide), centred.
        let top = (window?.contentLayoutRect.minY).map { _ in safeAreaInsets.top } ?? 0
        let w = min(580, bounds.width - 48)
        column.frame = NSRect(x: (bounds.width - w) / 2, y: top + 24, width: w, height: bounds.height)
        var y: CGFloat = 0
        for g in groups { g.frame = NSRect(x: 0, y: y, width: w, height: g.height); g.layoutRows(); y += g.height + 12 }
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

    @objc private func keepChanged() {
        guard let o = owner, let k = (keep.selectedItem?.representedObject as? String).flatMap(Keep.init) else { return }
        o.store.keep = k
        o.store.purge()
        o.reload()
        o.panelReload()
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

/// The shortcut field: shows the key; clicked, it waits for the next combination (Esc keeps the old one).
final class ShortcutButton: NSButton {
    var key = HotKey.standard { didSet { show() } }
    var onChange: ((HotKey) -> Void)?
    private var monitor: Any?

    init() {
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
            if let k = HotKey.from(e) { self.key = k; self.end(); self.onChange?(k) }
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
