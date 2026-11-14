// Clip (working name; the name lives in ./build only): a clipboard history for macOS. Every copy is kept, any kind
// and any size, and given back one or many at once: pick several like files in Finder, ⌘C, and one ⌘V pastes them
// all, in the order they were picked. Offline: no network call of any kind. Data: ~/.local/share/clip.
//
//   --data DIR       keep the history in DIR instead (tests and trials)
//   --quit-after S   quit by itself after S seconds (a trial on a real screen must end without a person)
import AppKit

let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

// One copy at a time: two would record every copy twice.
if let me = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0 != .current }) {
    exit(0)
}

let dataDir = arg("--data").map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/clip")

let store: Store
do { store = try Store(dir: dataDir) } catch {
    FileHandle.standardError.write(Data("Cannot open \(dataDir.path): \(error)\n".utf8))
    exit(1)
}

if let s = arg("--quit-after").flatMap(Double.init) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { exit(0) }
}

let app = NSApplication.shared
let delegate = App(store: store)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
