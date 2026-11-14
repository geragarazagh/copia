// The running app: the history store, the clipboard monitor, the panel and its key ⌥⌘C. Nothing in the Dock or the
// menu bar; the app never posts keys and asks for no permission.
import AppKit
import Carbon.HIToolbox

/// The Carbon hot key's callback is a C function: it reaches the app through this.
nonisolated(unsafe) var hotKeyAction: (() -> Void)?

final class App: NSObject, NSApplicationDelegate {
    let store: Store
    let monitor = Monitor()
    var panel: PanelController!
    private var hotKey: EventHotKeyRef?
    private var lastOtherApp: String?
    private let prepQueue = DispatchQueue(label: "com.geragaraza.clip.prepare", qos: .utility)
    private var housekeeping: Timer?

    init(store: Store) {
        self.store = store
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Clip.cleanPasteFolder(store, all: true)
        store.purge()
        panel = PanelController(store: store, monitor: monitor)

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
                }
            }
        }
        monitor.start()

        hotKeyAction = { [weak self] in self?.panel.toggle() }
        registerHotKey()

        // Every hour: what the keep-history setting and Recently Deleted let go, and paste files older than a day.
        housekeeping = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            store.purge()
            Clip.cleanPasteFolder(store, all: false)
        }
    }

    /// Opening the app again shows the panel. Hook for later: the big window (⌘, and opening the app; clipboard.md,
    /// «His pick») takes this over.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panel.show()
        return false
    }

    /// ⌥⌘C, his key (ClipBook's, used daily). Carbon's RegisterEventHotKey needs no permission. Hook for later: the
    /// key is set in the big window, stored in the database's settings.
    @discardableResult
    func registerHotKey() -> OSStatus {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { hotKeyAction?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x434C_4950), id: 1)   // 'CLIP'
        return RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregisterHotKey() { if let h = hotKey { UnregisterEventHotKey(h); hotKey = nil } }
}
