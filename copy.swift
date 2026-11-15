// Copying a selection back: the whole selection in ONE pasteboard write, and the person presses ⌘V where they want
// (Pasteboard report, A4; proved by the prototype 2026-11-14 in Telegram, Finder, Notes, Messages), so no app can read a
// half-changed clipboard between several pastes (the race that lost his images in ClipBook: rounds of clear, one image,
// ⌘V). Copia's own paste (Return, since 0.8: paste.swift) makes the same one write first, then sends one ⌘V.
import AppKit

enum Copia {
    /// The items of one write, in the order of the selection.
    /// - several entries that are all text: ONE item, their plain texts joined by a new line (his example: a dictated
    ///   message, then ten pages, pasted as one text);
    /// - otherwise every stored item of every entry, in order: an image as a real file URL + PNG + TIFF (Telegram takes
    ///   several images in one paste only as files, Qt reads an image only from TIFF, text views take the PNG); a file
    ///   as the copying app wrote it (Finder's own layout); a text with all its types, so rich text stays rich.
    static func items(_ sel: [(Entry, [[Rep]])], store: Store, providers: inout [TIFFProvider]) -> [NSPasteboardItem] {
        var out: [NSPasteboardItem] = []
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let texts = sel.compactMap { e, items -> String? in
            guard [.text, .link, .color].contains(e.kind) else { return nil }
            return items.first { $0.contains { $0.type == plain } }?.first { $0.type == plain }.flatMap(store.data)
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        if sel.count > 1 && texts.count == sel.count {
            let it = NSPasteboardItem()
            it.setString(texts.joined(separator: "\n"), forType: .string)
            out.append(it)
        } else {
            let images = sel.reduce(0) { $0 + $1.1.filter(isImage).count }
            let folder = store.dir.appendingPathComponent("paste").appendingPathComponent(UUID().uuidString)
            var k = 0
            for (_, items) in sel {
                for reps in items {
                    if isImage(reps), let r = reps.first(where: { $0.type == NSPasteboard.PasteboardType.png.rawValue }), let f = r.file {
                        k += 1
                        let src = store.dir.appendingPathComponent(f)
                        // A real file that outlives the paste: Telegram reads it only when Send is pressed, maybe
                        // minutes later. Named readably, since Telegram shows names when sending as files. On APFS
                        // the copy is a clone: instant, no extra space.
                        let dst = folder.appendingPathComponent((images == 1 ? L("Image") : "\(L("Image")) \(k)") + ".png")
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try? FileManager.default.copyItem(at: src, to: dst)
                        let it = NSPasteboardItem()
                        it.setString(dst.standardizedFileURL.absoluteString, forType: .fileURL)   // absolute: a relative URL writes nothing
                        if let d = try? Data(contentsOf: src) { it.setData(d, forType: .png) }
                        let p = TIFFProvider(png: src)
                        it.setDataProvider(p, forTypes: [.tiff])   // made only when an app asks: a 5K screenshot is 60 MB as TIFF
                        providers.append(p)
                        out.append(it)
                    } else {
                        let it = NSPasteboardItem()
                        for r in reps where r.type != NSPasteboard.PasteboardType.source.rawValue {
                            it.setData(store.data(r) ?? Data(), forType: .init(r.type))
                        }
                        // A picture copied with its file (a screenshot tool, Pixlift, the test CLI: file URL + PNG +
                        // TIFF) was read without the TIFF (the same picture as the PNG, often made on request and
                        // several times bigger). It goes back with one again, made when asked, since Qt apps read an
                        // image only from TIFF (the v0 trial 2026-11-14 found it missing).
                        let tiff = NSPasteboard.PasteboardType.tiff.rawValue
                        if !reps.contains(where: { $0.type == tiff }),
                           let r = reps.first(where: { $0.type == NSPasteboard.PasteboardType.png.rawValue }) {
                            let p = r.file.map { TIFFProvider(png: store.dir.appendingPathComponent($0)) } ?? TIFFProvider(data: r.data ?? Data())
                            it.setDataProvider(p, forTypes: [.tiff])
                            providers.append(p)
                        }
                        out.append(it)
                    }
                }
            }
        }
        // A password manager's copy goes back marked as it came (nspasteboard.org's concealed marker, which capture
        // keeps in the entry, not as a stored type), so other clipboard tools skip it (security pass 2026-11-15).
        let concealed = sel.contains { $0.0.concealed }
        for it in out {
            if concealed { it.setString("", forType: .concealed) }
            it.setString("1", forType: .own)   // inside the same item: a marker item of its own would paste as an extra
            it.setString(Bundle.main.bundleIdentifier ?? "com.geragaraza.copia", forType: .source)
        }
        return out
    }

    /// The picks as plain text: every text, link, colour and file name, joined by a new line; pictures give nothing.
    /// Copy as Plain Text and Paste as Plain Text in both windows, and the paste queue's plain items.
    static func plainText(_ es: [Entry]) -> String {
        es.map { $0.kind == .image ? "" : $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Plain text in one write, marked as Copia's own; returns the pasteboard's count after it (the monitor skips it).
    @discardableResult
    static func writePlain(_ t: String, concealed: Bool = false, to pb: NSPasteboard = .general) -> Int {
        clear(pb, concealed: concealed)
        let it = NSPasteboardItem()
        it.setString(t, forType: .string)
        if concealed { it.setString("", forType: .concealed) }
        it.setString("1", forType: .own)
        it.setString(Bundle.main.bundleIdentifier ?? "com.geragaraza.copia", forType: .source)
        pb.writeObjects([it])
        return pb.changeCount
    }

    /// A new write; a concealed one stays on this Mac (Universal Clipboard would carry a password to the iPhone).
    static func clear(_ pb: NSPasteboard, concealed: Bool) {
        if concealed { pb.prepareForNewContents(with: .currentHostOnly) } else { pb.clearContents() }
    }

    static func isImage(_ reps: [Rep]) -> Bool {
        !reps.contains { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }
            && reps.contains { $0.type == NSPasteboard.PasteboardType.png.rawValue && $0.file != nil }
    }

    /// Writes the selection; returns the pasteboard's count after the write (the monitor skips it) and how many
    /// file URLs came through. The file URLs are counted after writing and the write is made once more if any is
    /// missing: once in the prototype the third of three images arrived without its URL, and every repeat was fine.
    @discardableResult
    static func write(_ sel: [(Entry, [[Rep]])], store: Store, to pb: NSPasteboard = .general) -> (count: Int, urls: Int, expected: Int) {
        var expected = 0, got = 0
        for attempt in 0..<2 {
            var providers: [TIFFProvider] = []
            let items = items(sel, store: store, providers: &providers)
            expected = items.filter { $0.types.contains(.fileURL) }.count
            clear(pb, concealed: sel.contains { $0.0.concealed })
            pb.writeObjects(items)
            TIFFProvider.live = providers
            got = (pb.pasteboardItems ?? []).filter { $0.types.contains(.fileURL) }.count
            if got >= expected || attempt == 1 { break }
        }
        return (pb.changeCount, got, expected)
    }

    /// Temporary paste files live 24 h; all of them go at launch (nothing can still be waiting to paste them).
    static func cleanPasteFolder(_ store: Store, all: Bool, now: Date = Date()) {
        let root = store.dir.appendingPathComponent("paste")
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let made = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if all || now.timeIntervalSince(made) > 24 * 3600 { try? fm.removeItem(at: d) }
        }
    }
}

/// Gives the TIFF of an image when an app asks for it.
final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    /// The providers of the current clipboard content, kept alive until the next write replaces them.
    nonisolated(unsafe) static var live: [TIFFProvider] = []
    let png: URL?, data: Data?
    init(png: URL) { self.png = png; data = nil }
    init(data: Data) { png = nil; self.data = data }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let src = png.map({ CGImageSourceCreateWithURL($0 as CFURL, nil) }) ?? data.map({ CGImageSourceCreateWithData($0 as CFData, nil) }),
              let src else { return }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.tiff" as CFString, 1, nil) else { return }
        CGImageDestinationAddImageFromSource(dst, src, 0, nil)
        if CGImageDestinationFinalize(dst) { item.setData(out as Data, forType: .tiff) }
    }
}
