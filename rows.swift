// One row of the list: a picture of what was copied, its text or name, when and how big, and the copying app's icon.
// Picked rows take the person's own selection colour (System Settings: accent and highlight colour), grey when the
// panel does not have the keyboard, as every Mac list does; picked in a set of two or more, they carry their paste
// order in an accent badge (ClipBook's, the one he chose).
import AppKit
import UniformTypeIdentifiers

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
        title.stringValue = e.title
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
        let u = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.title != u { p.append(u) }
    case .color: if let (r, g, b) = rgb(e.title) { p.append("RGB \(r) · \(g) · \(b)") }
    case .image:
        if e.width > 0 { p.append("\(e.width) × \(e.height)") } else { p.append(counted(e.count, "object|objects")) }
        p.append(sizeText(e.bytes))
    case .files:   // several files: the title already says how many
        if e.bytes > 0 { p.append(sizeText(e.bytes)) }
    case .other: p.append(sizeText(e.bytes))
    }
    return p.joined(separator: " · ")
}

/// The order badge: an accent circle, a white digit, a thin white ring that keeps it readable on an accent row.
final class Badge: NSView {
    var number: Int? { didSet { needsDisplay = true } }
    override func draw(_ r: NSRect) {
        guard let n = number else { return }
        let c = bounds.insetBy(dx: 0.75, dy: 0.75)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: c).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: c)
        ring.lineWidth = 1.5
        ring.stroke()
        let size = bounds.height * 0.58
        var font = NSFont.systemFont(ofSize: size, weight: .bold)
        if let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
        let s = NSAttributedString(string: String(n), attributes: [.font: font, .foregroundColor: NSColor.white])
        let z = s.size()
        s.draw(at: NSPoint(x: bounds.midX - z.width / 2, y: bounds.midY - z.height / 2))
    }
}

/// Pictures for the rows, made once per entry and kept while the app runs.
final class Thumbs {
    static let shared = Thumbs()
    private var cache: [Int64: NSImage] = [:]
    private var apps: [String: NSImage] = [:]

    func thumb(_ e: Entry, store: Store) -> NSImage {
        if let i = cache[e.id] { return i }
        let i = make(e, store: store)
        cache[e.id] = i
        return i
    }

    func app(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        if let i = apps[id] { return i }
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: u.path)
        i.size = NSSize(width: 22, height: 22)
        apps[id] = i
        return i
    }

    private func make(_ e: Entry, store: Store) -> NSImage {
        let s: CGFloat = 40
        switch e.kind {
        case .image:
            if let f = e.thumb, let cg = picture(store.dir.appendingPathComponent(f)) {
                return rounded(NSImage(cgImage: cg, size: .zero), side: s)
            }
            return icon(.image)
        case .text: return icon(.plainText)
        case .link: return icon(UTType("com.apple.web-internet-location") ?? .url)
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
            let names = e.text.components(separatedBy: "\n")
            func ic(_ i: Int) -> NSImage {
                if i == 0, let p = e.thumb, FileManager.default.fileExists(atPath: p) { return NSWorkspace.shared.icon(forFile: p) }
                let ext = (names[min(i, names.count - 1)] as NSString).pathExtension
                return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
            }
            // One picture file (a screenshot copied by Pixlift or Finder): the picture itself, as for an image.
            if e.count == 1, let p = e.thumb, UTType(filenameExtension: (p as NSString).pathExtension)?.conforms(to: .image) == true,
               let cg = picture(URL(fileURLWithPath: p)) {
                return rounded(NSImage(cgImage: cg, size: .zero), side: s)
            }
            if e.count == 1 { return ic(0) }
            // Several files: three of their icons fanned out, as a stack of papers.
            let icons = (0..<min(3, e.count)).map(ic)
            return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
                let spots: [(CGFloat, CGFloat, CGFloat)] = [(-0.16, 0.06, 8), (0.16, 0.06, -8), (0, -0.04, 0)]
                for (k, im) in icons.enumerated() {   // the last drawn, the middle one, lies on top
                    let (dx, dy, deg) = spots[icons.count == 2 ? k + 1 : k]
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform()
                    t.translateX(by: s / 2 + dx * s, yBy: s / 2 + dy * s)
                    t.rotate(byDegrees: deg)
                    t.concat()
                    im.draw(in: NSRect(x: -s * 0.4, y: -s * 0.4, width: s * 0.8, height: s * 0.8))
                    NSGraphicsContext.restoreGraphicsState()
                }
                return true
            }
        case .other: return icon(.data)
        }
    }

    private func icon(_ t: UTType) -> NSImage { NSWorkspace.shared.icon(for: t) }

    /// A small copy of a picture file (160 px: 40 pt at 2× and a margin), read without decoding the whole picture.
    private func picture(_ u: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
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
