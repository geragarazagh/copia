// Command line interface for Copia: read/search/copy clipboard history from a terminal or an agent without launching the GUI.
// Run under the name copia-cli (symlink to Copia.app/Contents/MacOS/Copia) or as Copia with subcommands:
//
//   copia-cli list [N] [--kind K] [--include-concealed] [--json]
//   copia-cli search QUERY [--limit N] [--include-concealed] [--json]
//   copia-cli get ID [--include-concealed] [--json]
//   copia-cli copy ID... [--plain] [--include-concealed]
//   copia-cli status [--json]
//   copia-cli --version | --help
//
// Password-manager items (concealed = 1) are hidden from list/search/get/copy unless --include-concealed is passed explicitly.
// Every CLI mode refuses to run if launched as its own responsible app/launchd job (answersForItself()).

import AppKit

private let copiaCliName = "copia-cli"

private let copiaAppBundle: Bundle = {
    let real = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let appURL = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: appURL) ?? .main
}()

private func copiaAnswersForItself() -> Bool {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    let me = getpid()
    if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
        let r = unsafeBitCast(f, to: Lookup.self)(me)
        if r > 0 { return r == me }
    }
    return getppid() == 1
}

private func cliFail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

private func cliJSON(_ obj: Any) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { cliFail("Could not encode JSON.") }
    print(text)
    exit(0)
}

private func cleanOneLine(_ s: String, limit: Int = 120) -> String {
    let flat = s.replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespaces)
    if flat.count <= limit { return flat }
    return String(flat.prefix(limit - 1)) + "…"
}

private func cliRunning() -> Bool {
    guard let id = copiaAppBundle.bundleIdentifier else { return false }
    return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
}

private func stripDataFlag(_ rest: [String]) -> (dir: URL, args: [String]) {
    var out: [String] = [], custom: String? = nil
    var i = 0
    while i < rest.count {
        if rest[i] == "--data", i + 1 < rest.count { custom = rest[i + 1]; i += 2 }
        else { out.append(rest[i]); i += 1 }
    }
    let dir = custom.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/copia")
    return (dir, out)
}

private func openCliStore(_ dir: URL) -> Store {
    do { return try Store(dir: dir) } catch { cliFail("Cannot open \(dir.path): \(error)") }
}

private func entryDict(_ e: Entry, dir: URL, full: Bool = false) -> [String: Any] {
    let fmt = ISO8601DateFormatter()
    var d: [String: Any] = [
        "id": e.id,
        "copied": fmt.string(from: e.copied),
        "kind": e.kind.rawValue,
        "title": e.title,
        "bytes": e.bytes,
        "count": e.count,
        "concealed": e.concealed,
    ]
    if let app = e.app { d["app"] = app }
    if let url = e.url { d["url"] = url }
    if e.width > 0 && e.height > 0 { d["width"] = e.width; d["height"] = e.height }
    if let thumb = e.thumb {
        d["path"] = thumb.hasPrefix("/") ? thumb : dir.appendingPathComponent(thumb).path
    }
    if full { d["text"] = e.text } else { d["preview"] = cleanOneLine(e.text.isEmpty ? e.title : e.text) }
    return d
}

@MainActor func runCopiaCLI(_ rawArgs: [String]) -> Bool {
    let exe = copiaAppBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Copia"
    let named = URL(fileURLWithPath: rawArgs[0]).lastPathComponent != exe
    let (dataDir, rest) = stripDataFlag(Array(rawArgs.dropFirst()))

    let usage = """
    Usage: \(copiaCliName) list [N] [--kind K] [--include-concealed] [--json]
           \(copiaCliName) search QUERY [--limit N] [--include-concealed] [--json]
           \(copiaCliName) get ID [--include-concealed] [--json]
           \(copiaCliName) copy ID... [--plain] [--include-concealed]
           \(copiaCliName) status [--json]
           \(copiaCliName) --version | --help

    Kinds: text, link, color, image, files, other.
    Pass --data DIR to inspect a non-default store directory.
    """

    let guiFlags: Set<String> = [
        "--login", "--background", "--open-at-login", "--paste-to", "--data", "--quit-after",
        "--display", "--show", "--browser", "--queue", "--trial", "--appearance",
    ]

    guard let cmd = rest.first else {
        if named { print(usage); exit(0) }
        return false
    }

    switch cmd {
    case "--help", "-h":
        print(usage); exit(0)
    case "--version", "-V":
        let v = copiaAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let n = copiaAppBundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Copia"
        print("\(n) \(v)"); exit(0)
    case "list", "search", "get", "copy", "status":
        break
    default:
        if named || (cmd.hasPrefix("--") && !guiFlags.contains(cmd)) { cliFail(usage) }
        return false
    }

    if copiaAnswersForItself() {
        cliFail("\(copiaCliName) runs from a terminal or script, not launched as an app or launchd job.")
    }

    let tail = Array(rest.dropFirst())
    switch cmd {
    case "status":
        let json = tail == ["--json"]
        guard tail.isEmpty || json else { cliFail(usage) }
        let version = copiaAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let running = cliRunning()
        let dbPath = dataDir.appendingPathComponent("copia.sqlite").path
        let exists = FileManager.default.fileExists(atPath: dbPath)
        var activeCount = 0, deletedCount = 0, keepVal = Keep.days30.rawValue
        if exists {
            let s = openCliStore(dataDir)
            activeCount = s.entries(deleted: false).count
            deletedCount = s.entries(deleted: true).count
            keepVal = s.keep.rawValue
        }
        if json {
            cliJSON([
                "version": version,
                "running": running,
                "dataDir": dataDir.path,
                "databaseExists": exists,
                "entries": activeCount,
                "recentlyDeleted": deletedCount,
                "keep": keepVal,
            ])
        }
        print("version: \(version)")
        print("running: \(running ? "yes" : "no")")
        print("dataDir: \(dataDir.path)")
        print("entries: \(activeCount) (deleted: \(deletedCount))")
        print("keep: \(keepVal)")
        exit(0)

    case "list":
        var limit = 20, kind: Kind? = nil, includeConcealed = false, json = false
        var i = 0
        while i < tail.count {
            switch tail[i] {
            case "--json": json = true; i += 1
            case "--include-concealed": includeConcealed = true; i += 1
            case "--kind":
                guard i + 1 < tail.count, let k = Kind(rawValue: tail[i + 1]) else { cliFail(usage) }
                kind = k; i += 2
            default:
                guard let n = Int(tail[i]), n > 0 else { cliFail(usage) }
                limit = n; i += 1
            }
        }
        let s = openCliStore(dataDir)
        var items = s.entries(deleted: false)
        if !includeConcealed { items = items.filter { !$0.concealed } }
        if let kind { items = items.filter { $0.kind == kind } }
        let slice = Array(items.prefix(limit))
        if json { cliJSON(slice.map { entryDict($0, dir: dataDir) }) }
        let fmt = ISO8601DateFormatter()
        for e in slice {
            print("\(e.id)\t\(fmt.string(from: e.copied))\t\(e.kind.rawValue)\t\(cleanOneLine(e.text.isEmpty ? e.title : e.text))")
        }
        exit(0)

    case "search":
        guard let query = tail.first, !query.hasPrefix("--") else { cliFail(usage) }
        var limit = 20, includeConcealed = false, json = false
        var i = 1
        while i < tail.count {
            switch tail[i] {
            case "--json": json = true; i += 1
            case "--include-concealed": includeConcealed = true; i += 1
            case "--limit":
                guard i + 1 < tail.count, let n = Int(tail[i + 1]), n > 0 else { cliFail(usage) }
                limit = n; i += 2
            default: cliFail(usage)
            }
        }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ё", with: "е")
        let s = openCliStore(dataDir)
        let matches = s.entries(deleted: false).filter { e in
            if !includeConcealed && e.concealed { return false }
            let hay = e.searchable(e.title).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .replacingOccurrences(of: "ё", with: "е")
            return hay.contains(needle)
        }
        let slice = Array(matches.prefix(limit))
        if json { cliJSON(slice.map { entryDict($0, dir: dataDir) }) }
        let fmt = ISO8601DateFormatter()
        for e in slice {
            print("\(e.id)\t\(fmt.string(from: e.copied))\t\(e.kind.rawValue)\t\(cleanOneLine(e.text.isEmpty ? e.title : e.text))")
        }
        exit(0)

    case "get":
        guard let idStr = tail.first, let id = Int64(idStr) else { cliFail(usage) }
        var includeConcealed = false, json = false
        for flag in tail.dropFirst() {
            switch flag {
            case "--json": json = true
            case "--include-concealed": includeConcealed = true
            default: cliFail(usage)
            }
        }
        let s = openCliStore(dataDir)
        guard let e = s.entry(id) else { cliFail("No entry with id \(id).") }
        if e.concealed && !includeConcealed { cliFail("Entry \(id) is concealed (pass --include-concealed to read it).") }
        if json { cliJSON(entryDict(e, dir: dataDir, full: true)) }
        if e.kind == .image, let thumb = e.thumb {
            print(dataDir.appendingPathComponent(thumb).path)
        } else {
            print(e.text.isEmpty ? e.title : e.text)
        }
        exit(0)

    case "copy":
        var ids: [Int64] = [], plain = false, includeConcealed = false
        for a in tail {
            switch a {
            case "--plain": plain = true
            case "--include-concealed": includeConcealed = true
            default:
                guard let id = Int64(a) else { cliFail(usage) }
                ids.append(id)
            }
        }
        guard !ids.isEmpty else { cliFail(usage) }
        let s = openCliStore(dataDir)
        var sel: [(Entry, [[Rep]])] = []
        for id in ids {
            guard let e = s.entry(id) else { cliFail("No entry with id \(id).") }
            if e.concealed && !includeConcealed { cliFail("Entry \(id) is concealed (pass --include-concealed to copy it).") }
            sel.append((e, s.reps(id)))
        }
        if plain {
            let text = Copia.plainText(sel.map(\.0))
            Copia.writePlain(text, concealed: sel.contains { $0.0.concealed })
        } else {
            Copia.write(sel, store: s)
        }
        s.touch(ids)
        print("Copied \(ids.count) \(ids.count == 1 ? "entry" : "entries").")
        exit(0)

    default:
        cliFail(usage)
    }
}
