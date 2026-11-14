// The running app: the history store, the clipboard monitor, the panel and its key ⌥⌘C. Nothing in the Dock or the
// menu bar; the app never posts keys and asks for no permission.
import AppKit
import Carbon.HIToolbox

/// Trial flags (main.swift lists them): here, since the tests build every file but main.swift.
let trial = CommandLine.arguments.contains("--trial")
let trialDisplay: UInt32? = CommandLine.arguments.firstIndex(of: "--display").flatMap {
    $0 + 1 < CommandLine.arguments.count ? UInt32(CommandLine.arguments[$0 + 1]) : nil }

/// COPIA_TRACE=1: every key and click a window of the app gets, on stderr (trials).
let traceEvents = ProcessInfo.processInfo.environment["COPIA_TRACE"] != nil

/// The screen of the trial display, when one is given.
func trialScreen() -> NSScreen? {
    guard let id = trialDisplay else { return nil }
    return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
}

/// The Carbon hot key's callback is a C function: it reaches the app through this.
nonisolated(unsafe) var hotKeyAction: (() -> Void)?

final class App: NSObject, NSApplicationDelegate {
    let store: Store
    let monitor = Monitor()
    var panel: PanelController!
    var browser: BrowserController!
    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false
    private var lastOtherApp: String?
    private let prepQueue = DispatchQueue(label: "com.geragaraza.copia.prepare", qos: .utility)
    private var housekeeping: Timer?

    init(store: Store) {
        self.store = store
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // A trial names its own screen; should that screen be gone, nothing may open on another one (2026-11-14:
        // a trial's virtual display vanished mid-run and the panel opened on the person's screen for 3 s).
        if trialDisplay != nil && trialScreen() == nil {
            FileHandle.standardError.write(Data("No display \(trialDisplay!): not opening anything\n".utf8))
            exit(3)
        }
        Copia.cleanPasteFolder(store, all: true)
        store.purge()
        panel = PanelController(store: store, monitor: monitor)
        browser = BrowserController(store: store, monitor: monitor)
        browser.panelReload = { [weak self] in self?.panel.reload() }
        browser.onHotKeyChange = { [weak self] in
            guard let self, !trial else { return }
            self.unregisterHotKey()
            self.registerHotKey()
        }
        panel.openBrowser = { [weak self] p in self?.panel.hide(); self?.browser.show(p) }
        // One window, no tabs: AppKit would add Show Tab Bar and the tab items to View and Window (seen on 27.2).
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = makeMainMenu(settings: #selector(openSettings), target: self)

        // The copying app, when it does not say so itself: the app in front, or, when the panel is in front, the one
        // before it (Pesty's lesson: the poll lags the copy).
        lastOtherApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if id != Bundle.main.bundleIdentifier { self?.lastOtherApp = id }
        }
        monitor.frontApp = { [weak self] in
            let f = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            return f == Bundle.main.bundleIdentifier ? self?.lastOtherApp : f
        }
        monitor.onCopy = { [weak self] snap in
            guard let self else { return }
            let dir = store.dir
            prepQueue.async {   // images become PNG files here, off the main thread
                guard let (e, items) = prepare(snap, dir: dir) else { return }
                DispatchQueue.main.async {
                    self.store.add(e, items)
                    self.panel.reload()
                    if self.browser.isVisible { self.browser.reload() }
                }
            }
        }
        if !trial { monitor.start() }

        hotKeyAction = { [weak self] in self?.panel.toggle() }
        if !trial { registerHotKey() }
        if CommandLine.arguments.contains("--show") { panel.show() }
        if let i = CommandLine.arguments.firstIndex(of: "--browser") {
            let p = i + 1 < CommandLine.arguments.count ? Pane(rawValue: CommandLine.arguments[i + 1]) : nil
            browser.show(p)
        }

        // Every hour: what the keep-history setting and Recently Deleted let go, and paste files older than a day.
        housekeeping = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            store.purge()
            Copia.cleanPasteFolder(store, all: false)
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows the big window at the pane last used; ⌘, opens it
    /// at Settings (clipboard.md, «His pick»). Closing every window leaves the app running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        browser.show(browser.pane == .settings ? .all : nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func openSettings() { panel.hide(); browser.show(.settings) }

    func applicationWillTerminate(_ n: Notification) { browser.saveLayout() }

    /// ⌥⌘C by default, his key (ClipBook's, used daily); set in Settings, kept in the database's settings. Carbon's
    /// RegisterEventHotKey needs no permission.
    @discardableResult
    func registerHotKey() -> OSStatus {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The handler once; the key itself may be registered again after a change in Settings.
        if !handlerInstalled { handlerInstalled = true; InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { hotKeyAction?() }
            return noErr
        }, 1, &spec, nil, nil) }
        let id = EventHotKeyID(signature: OSType(0x434C_4950), id: 1)   // 'CLIP'
        let k = store.hotKey
        return RegisterEventHotKey(k.code, k.mods, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregisterHotKey() { if let h = hotKey { UnregisterEventHotKey(h); hotKey = nil } }
}

/// The letter of a ⌘ shortcut whatever the keyboard layout. With a Cyrillic layout charactersIgnoringModifiers of
/// ⌘A is «ф», so the panel's and the preview's own shortcuts did nothing (measured on macOS 27.2 with the Russian
/// layout, 2026-11-14); menus avoid this by reading the key through the ASCII-capable layout, and so does this.
func shortcutKey(_ e: NSEvent) -> String {
    let raw = e.charactersIgnoringModifiers?.lowercased() ?? ""
    if raw.unicodeScalars.allSatisfy(\.isASCII) { return raw }
    guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return raw }
    let data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
    var dead: UInt32 = 0, len = 0
    var chars = [UniChar](repeating: 0, count: 4)
    let st = data.withUnsafeBytes { b in
        UCKeyTranslate(b.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), e.keyCode, UInt16(kUCKeyActionDown), 0,
                       UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
    }
    return st == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).lowercased() : raw
}
