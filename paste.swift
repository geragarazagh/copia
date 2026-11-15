// Pasting for the person (his answer 2026-11-15 ~15:35: Return pastes into the app that was in front, as Spotlight's
// clipboard does; he checked it there, «прикольно»). Until 0.8 Copia only copied and the person pressed ⌘V, so it
// needed no permission (clipboard.md, «Decided»). Now: the picks go on the clipboard in Copia's one write, the panel
// leaves, and Copia sends ⌘V to that app's process. macOS lets an app send keys only when it is turned on in Privacy &
// Security > Accessibility (the «post event» right, CGPreflightPostEventAccess); without it Return still copies, and the
// first time Copia says once why it asks and lets macOS ask.
//
// The keys go to the app's process (CGEventPostToPid), never into the session's stream: they can reach no other app,
// whatever has the focus a moment later, and a test in the agents' own session (skill mac, control.md «cs») can never
// type into the person's front app. Their source is private, so a key the person still holds (⌘ of ⌘1, ⇧ of ⇧↩) is
// not added to them; the V is the key that types «v» with ⌘ in the person's layout (PasteQueue.vKey).
import AppKit

final class Paster {
    /// Whether macOS lets Copia send keys. Tests set it.
    /// COPIA_TRIAL_DENY=1 in a trial: as if not allowed, to see the explanation in the agents' own session (where a
    /// process started by Claude carries Claude Code's Accessibility).
    var allowed: () -> Bool = { trial && ProcessInfo.processInfo.environment["COPIA_TRIAL_DENY"] != nil ? false : CGPreflightPostEventAccess() }
    /// Sends ⌘V to the process. Tests set it.
    var post: (pid_t) -> Void = { Paster.commandV(to: $0) }
    /// No permission: the app explains, once (App.explainPasting).
    var denied: () -> Void = {}
    /// A paste is over (the paste queue puts its next item back on the clipboard).
    var after: () -> Void = {}
    /// The last paste: which process, for the tests and COPIA_TRACE.
    private(set) var lastPid: pid_t?

    /// Pastes what is on the clipboard into `app`: brought to the front first when it is not (the big window's Paste),
    /// then ⌘V once it is. Nothing happens for Copia itself or a process that is gone.
    func paste(into app: NSRunningApplication?) {
        guard let app, !app.isTerminated, app.processIdentifier != getpid() else { return }
        guard allowed() else { denied(); return }
        let pid = app.processIdentifier
        let go = { [weak self] in
            self?.lastPid = pid
            if traceEvents { FileHandle.standardError.write(Data("paste ⌘V to \(pid) \(app.bundleIdentifier ?? "")\n".utf8)) }
            self?.post(pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.after() }
        }
        // The panel never takes the front (a non-activating panel): its app is still the active one, and its window
        // gets the keys back when the panel leaves. 40 ms for that hand-over.
        if app.isActive { DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: go); return }
        app.activate(options: [])
        // Up to a second for it to come forward, then the keys either way (a slow app still gets them by pid).
        var waited = 0.0
        func check() {
            if app.isActive || waited >= 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: go); return }
            waited += 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
        }
        check()
    }

    static func commandV(to pid: pid_t) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: PasteQueue.vKey, keyDown: down) else { continue }
            e.flags = .maskCommand
            e.postToPid(pid)
        }
    }

    /// Privacy & Security > Accessibility in System Settings.
    static func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }
}
