// One row of the list: a picture of what was copied, its text or name, when and how big, and the copying app's icon.
// Picked rows take the person's own selection colour (System Settings: accent and highlight colour), grey when the
// panel does not have the keyboard, as every Mac list does; picked in a set of two or more, they carry their paste
// order in an accent badge (ClipBook's, the one he chose).
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

final class EntryCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("entry")
    private let thumb = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let appIcon = NSImageView()
    private let badge = Badge()
    private var selected = false, focused = true
    private var twoLines = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: panelSize.width, height: rowH))
        identifier = Self.id
        let x0 = listInset + 12
        thumb.frame = NSRect(x: x0, y: (rowH - 40) / 2, width: 40, height: 40)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        appIcon.frame = NSRect(x: panelSize.width - listInset - 12 - 22, y: (rowH - 22) / 2, width: 22, height: 22)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping   // a truncating mode would make it one line; the last line still ends in «…»
        title.cell?.truncatesLastVisibleLine = true
        title.isSelectable = false
        meta.font = .systemFont(ofSize: 12)
        meta.lineBreakMode = .byTruncatingTail
        for v in [thumb, title, meta, appIcon] as [NSView] { addSubview(v) }
        badge.frame = NSRect(x: x0 - 7, y: (rowH - 40) / 2 - 6, width: 20, height: 20)
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ e: Entry, store: Store) {
        thumb.image = Thumbs.shared.thumb(e, store: store)
        appIcon.image = Thumbs.shared.app(e.app)
        twoLines = e.kind == .text
        title.font = .systemFont(ofSize: 14, weight: twoLines ? .regular : .medium)
        title.maximumNumberOfLines = twoLines ? 2 : 1
        title.stringValue = shownTitle(e)
        meta.stringValue = metaText(e)
        layoutText()
    }

    private func layoutText() {
        let x = listInset + 12 + 40 + 12
        let w = appIcon.frame.minX - 8 - x
        let lineH: CGFloat = 17
        let th = twoLines ? min(2 * lineH, title.sizeThatFits(NSSize(width: w, height: 100)).height) : lineH
        let mh: CGFloat = 15, gap: CGFloat = 2
        let top = ((rowH - th - gap - mh) / 2).rounded()
        title.frame = NSRect(x: x, y: top, width: w, height: th)
        meta.frame = NSRect(x: x, y: top + th + gap, width: w, height: mh)
    }

    func update(selected s: Bool, badge n: Int?, focused f: Bool) {
        selected = s; focused = f
        let strong = s && f
        title.textColor = strong ? .alternateSelectedControlTextColor : .labelColor
        meta.textColor = strong ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        badge.number = n
        badge.isHidden = n == nil
        needsDisplay = true
    }

    override func draw(_ r: NSRect) {
        guard selected else { return }
        (focused ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: listInset, dy: 0), xRadius: 10, yRadius: 10).fill()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true; badge.needsDisplay = true }
}

/// «7:34 · 3456 × 2234 · 6,2 МБ», «7:31 · 1 162 символа», «7:27 · https://…», «7:30 · RGB 10 · 132 · 255».
func metaText(_ e: Entry) -> String {
    var p = [timeText(e.copied)]
    switch e.kind {
    case .text: p.append(counted(e.text.count, "character|characters"))
    case .link:   // the address under the page's title; a bare address is already the title
        if e.title != e.address { p.append(e.address) }
    case .color: if let (r, g, b) = rgb(e.title) { p.append("RGB \(r) · \(g) · \(b)") }
    case .image:
        if e.width > 0 { p.append("\(e.width) × \(e.height)") }   // several: the title already says how many
        p.append(sizeText(e.bytes))
    case .files:   // several files: the title already says how many
        if e.bytes > 0 { p.append(sizeText(e.bytes)) }
    case .other: p.append(sizeText(e.bytes))
    }
    return p.joined(separator: " · ")
}

/// The order badge: an accent circle, a white digit, a thin white ring that keeps it readable on an accent row. From
/// 10 on it grows into a capsule to the right, its left edge and height kept, as Apple's count badges do (on 27.2 a
/// ⌘A of 22 entries drew «22» touching the ring, 2026-11-14).
final class Badge: NSView {
    var number: Int? { didSet { needsDisplay = true; setFrameSize(frame.size) } }
    private func label(_ h: CGFloat) -> NSAttributedString {
        let size = h * 0.58
        var font = NSFont.systemFont(ofSize: size, weight: .bold)
        if let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
        return NSAttributedString(string: number.map(String.init) ?? "", attributes: [.font: font, .foregroundColor: NSColor.white])
    }
    override func setFrameSize(_ s: NSSize) {
        let w = (number ?? 0) < 10 ? s.height : max(s.height, (label(s.height).size().width + s.height * 0.6).rounded(.up))
        super.setFrameSize(NSSize(width: w, height: s.height))
    }
    override func draw(_ r: NSRect) {
        guard number != nil else { return }
        let c = bounds.insetBy(dx: 0.75, dy: 0.75)
        let shape = NSBezierPath(roundedRect: c, xRadius: c.height / 2, yRadius: c.height / 2)
        NSColor.controlAccentColor.setFill()
        shape.fill()
        NSColor.white.setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
        let s = label(bounds.height)
        let z = s.size()
        s.draw(at: NSPoint(x: bounds.midX - z.width / 2, y: bounds.midY - z.height / 2))
    }
}

/// Pictures for the rows, made once per entry and kept while the app runs.
final class Thumbs {
    static let shared = Thumbs()
    private var cache: [String: NSImage] = [:]
    private var apps: [String: NSImage] = [:]

    /// The picture of an entry at `side` points (the panel's rows: 40; the big window's icons: up to 128).
    func thumb(_ e: Entry, store: Store, side: CGFloat = 40) -> NSImage {
        let key = "\(e.id)-\(Int(side))"
        if let i = cache[key] { return i }
        let i = make(e, store: store, side: side)
        cache[key] = i
        if side >= 48 { finderThumb(e, key: key, side: side) }
        return i
    }

    /// A file copied in Finder gets Finder's own picture of it in the big window (a video's frame, a PDF's page, a
    /// document's first page), made by Quick Look off the main thread; until it comes the file's icon stands in.
    private func finderThumb(_ e: Entry, key: String, side: CGFloat) {
        guard e.kind == .files, e.count == 1, let p = e.thumb, FileManager.default.fileExists(atPath: p),
              UTType(filenameExtension: (p as NSString).pathExtension)?.conforms(to: .image) != true else { return }
        let r = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: p), size: CGSize(width: side, height: side),
                                             scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: r) { rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                self.cache[key] = rep.nsImage
                NotificationCenter.default.post(name: Thumbs.ready, object: nil)
            }
        }
    }

    static let ready = Notification.Name("ClipThumbReady")

    /// An entry changed (edited, reverted): its pictures are made again.
    func forget(_ id: Int64) { for k in cache.keys where k.hasPrefix("\(id)-") { cache[k] = nil } }

    func app(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        if let i = apps[id] { return i }
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: u.path)
        i.size = NSSize(width: 22, height: 22)
        apps[id] = i
        return i
    }

    private func make(_ e: Entry, store: Store, side s: CGFloat) -> NSImage {
        let px = Int(s * 4)
        switch e.kind {
        case .image:
            if e.count > 1 {   // several images in one copy: a small stack of the first three
                let png = NSPasteboard.PasteboardType.png.rawValue
                let pics = store.reps(e.id).compactMap { $0.first { $0.type == png }?.file }.prefix(3)
                    .compactMap { picture(store.dir.appendingPathComponent($0), px: px) }.map { NSImage(cgImage: $0, size: .zero) }
                if pics.count > 1 { return stack(pics.map { ($0, true) }, side: s) }
            }
            if let f = e.thumb, let cg = picture(store.dir.appendingPathComponent(f), px: px) {
                return rounded(NSImage(cgImage: cg, size: .zero), side: s)
            }
            return icon(.image, s)
        case .text where s >= 48: return page(e.text, side: s)
        case .text: return icon(.plainText, s)
        case .link:
            // What the copying app carried (link.swift): the site's icon in a row, the page's picture where there is
            // room for it (the big window's icons and gallery); neither carried: the system's link icon.
            let files = s >= 48 ? [e.picture, e.thumb] : [e.thumb, e.picture]
            for f in files.compactMap({ $0 }) {
                if let cg = picture(store.dir.appendingPathComponent(f), px: px) { return rounded(NSImage(cgImage: cg, size: .zero), side: s) }
            }
            return icon(UTType("com.apple.web-internet-location") ?? .url, s)
        case .color:
            let (r, g, b) = rgb(e.title) ?? (128, 128, 128)
            let c = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
                let rr = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
                let p = NSBezierPath(roundedRect: rr, xRadius: s * 0.16, yRadius: s * 0.16)
                c.setFill(); p.fill()
                NSColor.white.withAlphaComponent(0.5).setStroke(); p.lineWidth = 1; p.stroke()
                return true
            }
        case .files:
            // The first files, each as its picture when it is one (a screenshot copied in Finder) or as its icon.
            let paths = filePaths(e, store: store)
            let names = e.text.components(separatedBy: "\n")
            func card(_ i: Int) -> (NSImage, Bool) {
                if i < paths.count {
                    let p = paths[i]
                    if UTType(filenameExtension: (p as NSString).pathExtension)?.conforms(to: .image) == true,
                       let cg = picture(URL(fileURLWithPath: p), px: px) { return (NSImage(cgImage: cg, size: .zero), true) }
                    if FileManager.default.fileExists(atPath: p) { return (NSWorkspace.shared.icon(forFile: p), false) }
                }
                let ext = (names[min(i, names.count - 1)] as NSString).pathExtension
                return (NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data), false)
            }
            if e.count == 1 {
                let (im, isPicture) = card(0)
                return isPicture ? rounded(im, side: s) : im
            }
            return stack((0..<min(3, e.count)).map(card), side: s)
        case .other: return icon(.data, s)
        }
    }

    /// A text as Finder pictures a text file: a white page with its first lines in tiny type.
    private func page(_ t: String, side s: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
            let h = s * 0.94, w = h * 0.77
            let r = NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h)
            let sh = NSShadow()
            sh.shadowBlurRadius = 1.5; sh.shadowOffset = NSSize(width: 0, height: -0.5)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
            NSGraphicsContext.saveGraphicsState()
            sh.set()
            NSColor.white.setFill()
            NSBezierPath(rect: r).fill()
            NSGraphicsContext.restoreGraphicsState()
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping
            let size = max(2.2, s / 30)
            NSAttributedString(string: String(t.prefix(900)), attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(white: 0.25, alpha: 1), .paragraphStyle: p,
            ]).draw(with: r.insetBy(dx: w * 0.1, dy: h * 0.08), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }

    private func icon(_ t: UTType, _ s: CGFloat) -> NSImage { let i = NSWorkspace.shared.icon(for: t); i.size = NSSize(width: s, height: s); return i }

    /// The paths of a files entry's items, in order (from its stored file URLs).
    private func filePaths(_ e: Entry, store: Store) -> [String] {
        let furl = NSPasteboard.PasteboardType.fileURL.rawValue
        let found = store.reps(e.id).prefix(3).compactMap { $0.first { $0.type == furl } }
            .compactMap { store.data($0).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))?.path }
        return found.isEmpty ? (e.thumb.map { [$0] } ?? []) : found
    }

    /// A small stack, as Finder draws several files being dragged: the first on top, each next one a step up and to
    /// the right and a little smaller, behind it. Pictures get rounded corners, a hairline and a soft shadow so the
    /// cards stay apart; icons keep their own shapes.
    private func stack(_ cards: [(NSImage, Bool)], side s: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let step: CGFloat = 4, n = cards.count
            let span = step * CGFloat(n - 1)
            for k in stride(from: n - 1, through: 0, by: -1) {
                let (im, isPicture) = cards[k]
                let scale = 1 - 0.08 * CGFloat(k)
                let c = NSPoint(x: s / 2 - span / 2 + step * CGFloat(k), y: s / 2 - span / 2 + step * CGFloat(k))
                NSGraphicsContext.saveGraphicsState()
                if isPicture {
                    let box = s * 0.74 * scale
                    let a = im.size.width / max(1, im.size.height)
                    let w = a >= 1 ? box : box * a, h = a >= 1 ? box / a : box
                    let r = NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
                    let p = NSBezierPath(roundedRect: r, xRadius: s * 0.08, yRadius: s * 0.08)
                    let sh = NSShadow()
                    sh.shadowBlurRadius = 1.5; sh.shadowOffset = NSSize(width: 0, height: -0.5)
                    sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
                    sh.set()
                    NSColor.white.setFill(); p.fill()
                    NSShadow().set()
                    p.addClip()
                    im.draw(in: r)
                    NSColor.labelColor.withAlphaComponent(0.15).setStroke()
                    p.lineWidth = 0.5; p.stroke()
                } else {
                    let box = s * 0.84 * scale
                    im.draw(in: NSRect(x: c.x - box / 2, y: c.y - box / 2, width: box, height: box))
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    /// A small copy of a picture file (4 px per point: 2× and a margin), read without decoding the whole picture.
    private func picture(_ u: URL, px: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: px,
            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    /// A picture at 86 % of the cell, corners 16 % of the side, with a hairline edge so white screenshots keep a shape.
    private func rounded(_ im: NSImage, side s: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let a = im.size.width / max(1, im.size.height)
            let box = s * 0.86
            let w = a >= 1 ? box : box * a, h = a >= 1 ? box / a : box
            let r = NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h)
            let p = NSBezierPath(roundedRect: r, xRadius: s * 0.12, yRadius: s * 0.12)
            NSGraphicsContext.saveGraphicsState()
            p.addClip()
            im.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.labelColor.withAlphaComponent(0.15).setStroke()
            p.lineWidth = 0.5
            p.stroke()
            return true
        }
    }
}
