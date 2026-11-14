// Copia (the name lives in ./build only; Clip until 2026-11-14): a clipboard history for macOS. Every copy is kept, any kind
// and any size, and given back one or many at once: pick several like files in Finder, ⌘C, and one ⌘V pastes them
// all, in the order they were picked. Offline: the one network call is Sparkle's daily update check (updates.swift),
// which asks before installing anything. Data: ~/.local/share/copia.
//
// Opened by a person it shows the big window; started at login (--login, from the agent in the bundle) or with
// --background it shows nothing and waits for ⌥⌘C.
//   --data DIR       keep the history in DIR instead (tests and trials)
//   --quit-after S   quit by itself after S seconds (a trial on a real screen must end without a person)
// Trial flags (Claude's checks on a virtual display of its own, never on the person's screen):
//   --display ID     windows open on the screen of this CGDirectDisplayID instead of the one with the pointer
//   --show           open the panel at launch; --browser [PANE] opens the big window (all, text, …, settings)
//   --trial          no hot key, no clipboard watching, no login item change: nothing that touches the person's Mac
//   --appearance light|dark
import AppKit

let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

// Open at Login: launchd starts this copy with --login; it starts the app through `open -g … --background` and exits,
// because launchd kills what it started when the agent is unregistered (dev/apps.md, «Open at Login»).
if args.contains("--login") {
    if let me = Bundle.main.bundleIdentifier,
       !NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0 != .current }) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", Bundle.main.bundlePath, "--args", "--background"]
        try? p.run()
        p.waitUntilExit()
    }
    exit(0)
}

// One copy at a time: two would record every copy twice.
if let me = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0 != .current }) {
    exit(0)
}

if let a = arg("--appearance") { NSApplication.shared.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }

let dataDir = arg("--data").map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/copia")

let store: Store
do { store = try Store(dir: dataDir) } catch {
    FileHandle.standardError.write(Data("Cannot open \(dataDir.path): \(error)\n".utf8))
    exit(1)
}

if let s = arg("--quit-after").flatMap(Double.init) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { exit(0) }
}

// Sparkle lives in updates.swift, which the tests do not build: the app reaches it through these.
updater = Updater(start: { MainActor.assumeIsolated { _ = Updates.shared } },
                  check: { MainActor.assumeIsolated { Updates.shared.check() } },
                  opened: { MainActor.assumeIsolated { Updates.shared.appOpened() } })

let app = NSApplication.shared
let delegate = App(store: store)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
