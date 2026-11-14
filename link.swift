// A link's title and pictures, taken only from what the copying app itself put on the pasteboard: Copia makes no
// network call, ever (his word, 2026-11-14: previews only «if no network call per link is needed», else links stay
// text). Measured 2026-11-14 on macOS 27.2 in the agents' own session (cs), real Safari bytes in tests/links/:
// - Safari's address bar (⌘L ⌘C) writes com.apple.linkpresentation.metadata: an archived LPLinkMetadata with the
//   page's title (og:title before <title>) and, when Safari has them, the site's icon and the og:image as bytes
//   inside the archive (github.com: a 120 px PNG icon and a 1024 × 537 JPEG, 62 KB in all). Read with the network
//   denied (sandbox-exec deny network*), both load in under a millisecond: nothing is fetched. A picture Safari had
//   not loaded is only an address in the archive, and its provider is nil, so it is never fetched either.
// - Safari's «Copy Link» writes public.url-name (the link's text) beside public.url.
// - A link selected on a page (WebKit, Chromium, Telegram's hidden links) writes public.html holding one <a href>
//   whose text is the whole selection; Telegram's plain text is then «text (address)».
// - Notes writes public.url-name equal to the address itself: that is no title.
import AppKit
import LinkPresentation
import UniformTypeIdentifiers

/// What a copied link carries: its address, its title when the app gave one, the site's icon and the page's picture.
struct LinkInfo: Equatable {
    var url: String
    var title: String?
    var icon: Data?
    var image: Data?
}

extension NSPasteboard.PasteboardType {
    static let linkMetadata = Self("com.apple.linkpresentation.metadata")
}

/// The link one pasteboard item carries, or nil when the item is not a link: either its plain text is one web
/// address (titled by the metadata, else by public.url-name), or its HTML is one link and nothing else.
func linkInfo(_ reps: [Rep], plain: String) -> LinkInfo? {
    func str(_ t: String) -> String? {
        reps.first { $0.type == t }?.data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let one = plain.trimmingCharacters(in: .whitespacesAndNewlines)
    if isWebAddress(one) {
        var info = LinkInfo(url: one)
        if let d = reps.first(where: { $0.type == NSPasteboard.PasteboardType.linkMetadata.rawValue })?.data,
           let m = linkMetadata(d) {
            info.title = m.title; info.icon = m.icon; info.image = m.image
        }
        if info.title == nil { info.title = str(NSPasteboard.PasteboardType.urlName.rawValue) }
        if let t = info.title, t.isEmpty || sameAddress(t, one) { info.title = nil }
        return info
    }
    guard let h = str(NSPasteboard.PasteboardType.html.rawValue), let (href, text) = soleLink(h), !text.isEmpty else { return nil }
    // The plain text must be that link's text (WebKit, Chromium) or Telegram's «text (address)»: a copy whose
    // plain text says something else is a text that happens to carry a link.
    guard one == text || one == "\(text) (\(href))" else { return nil }
    return LinkInfo(url: href, title: sameAddress(text, href) ? nil : text)
}

func isWebAddress(_ s: String) -> Bool {
    guard !s.isEmpty, !s.contains(where: \.isWhitespace), let u = URL(string: s), let sc = u.scheme?.lowercased(),
          ["http", "https"].contains(sc), u.host != nil else { return false }
    return true
}

/// «https://www.github.com/» and «github.com» are the same address as a title: no title at all.
func sameAddress(_ a: String, _ b: String) -> Bool {
    func bare(_ s: String) -> String {
        var t = s.lowercased()
        for p in ["https://", "http://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }
    return bare(a) == bare(b)
}

/// The title and the pictures inside Safari's archived LPLinkMetadata. Its providers hold the bytes from the
/// archive; a load that has not answered in a second is given up (it never needed one when measured).
func linkMetadata(_ d: Data) -> (title: String?, icon: Data?, image: Data?)? {
    guard let m = try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: d) else { return nil }
    func load(_ p: NSItemProvider?) -> Data? {
        guard let p, p.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        var out: Data?
        let done = DispatchSemaphore(value: 0)
        _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in out = data; done.signal() }
        guard done.wait(timeout: .now() + 1) == .success, let out,
              let src = CGImageSourceCreateWithData(out as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        return out
    }
    let t = m.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t?.isEmpty == false ? t : nil, load(m.iconProvider), load(m.imageProvider))
}

/// The one <a href="http…"> of an HTML fragment and its text, when that text is all the fragment shows.
func soleLink(_ html: String) -> (String, String)? {
    var h = html
    for tag in ["head", "style", "script", "title"] {   // what a browser does not show
        h = h.replacingOccurrences(of: "<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
    }
    h = h.replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
    let anchor = try! NSRegularExpression(pattern: "<a\\b([^>]*)>(.*?)</a\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    let found = anchor.matches(in: h, range: NSRange(h.startIndex..., in: h))
    guard found.count == 1, let attrs = Range(found[0].range(at: 1), in: h), let inner = Range(found[0].range(at: 2), in: h) else { return nil }
    let href = try! NSRegularExpression(pattern: "\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: .caseInsensitive)
    let a = String(h[attrs])
    guard let m = href.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)),
          let r = (1...3).lazy.compactMap({ Range(m.range(at: $0), in: a) }).first else { return nil }
    let url = entities(String(a[r])).trimmingCharacters(in: .whitespacesAndNewlines)
    guard isWebAddress(url) else { return nil }
    let text = visible(String(h[inner]))
    guard visible(h) == text else { return nil }
    return (url, text)
}

/// The text a fragment shows: tags out, entities decoded, runs of white space folded to one space.
private func visible(_ s: String) -> String {
    let t = entities(s.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression))
    return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func entities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var t = s
    for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
        t = t.replacingOccurrences(of: k, with: v)
    }
    let num = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
    for m in num.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
        guard let r = Range(m.range, in: t), let hexR = Range(m.range(at: 1), in: t), let vR = Range(m.range(at: 2), in: t),
              let v = UInt32(t[vR], radix: t[hexR].isEmpty ? 10 : 16), let u = Unicode.Scalar(v) else { continue }
        t.replaceSubrange(r, with: String(Character(u)))
    }
    return t.replacingOccurrences(of: "&amp;", with: "&")
}

/// An image carried by a link, kept like copied images: one file named by its content, in its own format (a JPEG
/// stays a JPEG: as PNG it would be several times bigger).
func keepPicture(_ d: Data, dir: URL) -> String? {
    guard let src = CGImageSourceCreateWithData(d as CFData, nil), let t = CGImageSourceGetType(src) as String?,
          let ext = UTType(t)?.preferredFilenameExtension else { return nil }
    let name = "images/" + sha(d) + "." + ext
    let url = dir.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) { try? d.write(to: url, options: .atomic) }
    return name
}

/// Apple's own link card, LPLinkView, as Messages, Notes and the share sheet draw a link: the page's picture at its
/// own aspect over a caption tinted from it, with the title and the site. Made from the archived LPLinkMetadata the
/// copying app put on the pasteboard (kept with the entry for pasting), so it holds the picture's bytes and size and
/// draws in the first frame; LPLinkView itself never loads anything (drawn with the network denied, 2026-11-14). Shown
/// at Apple's own size, its intrinsicContentSize: 350 pt wide for github.com, the picture 1.91 : 1 under a caption of
/// 44-56 pt. Only for a link that carried a picture: one with an icon alone stays its text, as before.
func linkCard(_ e: Entry, store: Store) -> LPLinkView? {
    guard e.kind == .link, e.picture != nil,
          let r = store.reps(e.id).first?.first(where: { $0.type == NSPasteboard.PasteboardType.linkMetadata.rawValue }),
          let d = store.data(r),
          let m = try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: d) else { return nil }
    return LPLinkView(metadata: m)
}
