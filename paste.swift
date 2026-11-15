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
//
// A grant made while Copia runs (his trial of 0.8, 2026-11-15: after he turned Copia on in Accessibility, Return still
// only copied until he quit and reopened it). Measured on macOS 27.2 in a test machine: a running process keeps the
// answer it got first, AXIsProcessTrusted and CGPreflightPostEventAccess both stay false and the keys it posts are
// dropped, while a process started after the grant sees it and its keys arrive. So when Copia itself is not allowed,
// it asks a fresh copy of itself (`Copia --paste-to PID`, about 70 ms, off the main thread), which checks and sends
// the ⌘V; once that copy says yes, every paste goes through it until Copia is next started. The copy borrows Copia's
// grant because Copia started it (macOS counts the starting app as responsible). Started any other way (`open -n`
// makes the copy responsible for itself and so carries Copia's grant), it could be told to press ⌘V anywhere, so it
// sends keys only when its parent process passes Copia's own code signature check (security pass 2026-11-15).
import AppKit
import Security

final class Paster {
    /// Whether macOS lets Copia send keys. Tests set it.
    /// COPIA_TRIAL_DENY=1 in a trial: as if not allowed, to see the explanation in the agents' own session (where a
    /// process started by Claude carries Claude Code's Accessibility).
    var allowed: () -> Bool = { trialDeny ? false : Paster.allowedHere() || Paster.allowedFresh }
    /// The fresh copy's answer (off the main thread). Tests set it.
    var fresh: () -> Bool = { trialDeny ? false : Paster.runFresh(pid: 0) }
    /// Sends ⌘V to the process: from Copia itself when macOS lets it, else from a fresh copy. Tests set it.
    var post: (pid_t) -> Void = { pid in
        if Paster.allowedHere() { Paster.commandV(to: pid) } else { DispatchQueue.global(qos: .userInitiated).async { _ = Paster.runFresh(pid: pid) } }
    }
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
        guard allowed() else {
            // Maybe turned on since Copia started: a fresh copy knows.
            let fresh = self.fresh
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = fresh()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if ok { Paster.allowedFresh = true; self.deliver(app) } else { self.denied() }
                }
            }
            return
        }
        deliver(app)
    }

    /// The ⌘V itself, once allowed.
    private func deliver(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        let pid = app.processIdentifier
        let go = { [weak self] in
            // Gone, or never came forward within the second: no keys (security pass 2026-11-15).
            guard !app.isTerminated, app.isActive else { return }
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

    /// Copia's own answer, as macOS gave it to this process.
    static func allowedHere() -> Bool { CGPreflightPostEventAccess() || AXIsProcessTrusted() }
    /// A fresh copy said yes since Copia started (main thread only).
    static var allowedFresh = false

    /// Starts `Copia --paste-to PID` and waits for it: true when it is allowed (and, for a PID above 0, sent the ⌘V).
    /// An empty environment: the copy needs nothing from Copia's (release.md, the STT 0.4 lesson).
    static func runFresh(pid: pid_t) -> Bool {
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--paste-to", String(pid)]
        p.environment = [:]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The fresh copy's whole work (main.swift, before anything else starts): exit 0 when allowed, after the ⌘V when
    /// a PID is given; 1 when not allowed; 2 for anything that is not one PID of a running process.
    static func freshCopy(_ rest: ArraySlice<String>) -> Int32 {
        guard rest.count == 1, let pid = pid_t(rest.first!), pid >= 0 else { return 2 }
        guard allowedHere() else { return 1 }
        if pid == 0 { return 0 }
        guard parentIsCopia(), NSRunningApplication(processIdentifier: pid) != nil, pid != getpid() else { return 2 }
        commandV(to: pid)
        return 0
    }

    /// Whether the process that started this one is Copia: it must satisfy this app's designated requirement (the same
    /// Developer ID and bundle id; for a build signed ad hoc, the same code).
    static func parentIsCopia() -> Bool {
        var me: SecCode?, mine: SecStaticCode?, req: SecRequirement?, parent: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &req) == errSecSuccess, let req,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: getppid()] as CFDictionary, [], &parent) == errSecSuccess,
              let parent else { return false }
        return SecCodeCheckValidity(parent, [], req) == errSecSuccess
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
