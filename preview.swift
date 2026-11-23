// The Space preview, Quick Look's way (his word: it must grow out of its item, not appear in the middle; the films:
// Quick Look opens from the icon's rectangle in ~250 ms, most of it in the first ~85 ms, and closes back into it in
// ~130 ms; the content is scaled as one picture, never reflowed or cross-faded). It opens from the row's picture,
// over the list, on the same glass. A text is editable in place with bold and italic (⌘B, ⌘I); its footer counts
// live (characters · words · lines · ≈tokens · size, the numbers that matter for language models); «Revert to
// Original» brings the copy back as it was (ClipBook's Restore). Images, video and files show in QLPreviewView.
// Space or Esc closes; the arrows move the selection and the preview follows.
import AppKit
import Quartz
import AVKit
import UniformTypeIdentifiers

let previewWidth: CGFloat = 640
let previewFooter: CGFloat = 36

final class PreviewController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    weak var panel: PanelController?
    let store: Store
    private(set) var window: PreviewWindow?
    private(set) var entry: Entry?
    private let box = Flipped()          // the container: glass + content, its frame is what moves
    private var glass: NSView!
    private let content = LaidOut()      // the live content
    private let picture = NSImageView()  // the content as one picture while the container moves
    private var textView: NSTextView?
    private var textScroll: NSScrollView?
    private var quickLook: QLPreviewView?
    /// A video plays in AVKit's own view with the standard inline controls (play, the scrubber, time, volume), as
    /// Quick Look and QuickTime show it: Quick Look's compact view played a video but gave no scrubber (his review of
    /// 0.4, 2026-11-14).
    private var playerView: AVPlayerView?
    /// The video's first frame: what the preview shows while it grows, and the shape it takes.
    private var videoFrame: NSImage?
    private var card: NSView?            // a link's own card (link.swift), at Apple's size
    static let cardInset: CGFloat = 20
    private let facts = NSTextField(labelWithString: "")
    private let revert = NSButton(title: L("Revert to Original"), target: nil, action: nil)
    private let ticker = Ticker()
    private var edited = false
    private(set) var finalRect = NSRect.zero   // in the window
    /// Off-screen renders: the preview drawn into a given view instead of a window of its own.
    var host: NSView?

    var isOpen: Bool { entry != nil }

    init(store: Store) {
        self.store = store
        super.init()
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = panelCorner
            g.style = .regular
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .popover; v.state = .active; v.blendingMode = .behindWindow
            v.wantsLayer = true; v.layer?.cornerCurve = .continuous; v.layer?.masksToBounds = true
            glass = v
        }
        box.addSubview(glass)
        box.addSubview(content)
        box.addSubview(picture)
        picture.imageScaling = .scaleAxesIndependently
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        facts.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        facts.textColor = .secondaryLabelColor
        facts.lineBreakMode = .byTruncatingTail
        revert.bezelStyle = .rounded
        revert.controlSize = .small
        revert.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        revert.target = self
        revert.action = #selector(revertToOriginal)
    }

    // MARK: open and close

    /// Opens the preview of `e` growing out of `from` (the row's picture, in screen points), or, when one is open,
    /// shows `e` in it at once (the arrows: one frame).
    func open(_ e: Entry, from: NSRect, panelRect: NSRect, screen: NSRect) {
        if isOpen { save(); load(e); place(panelRect: panelRect, screen: screen, from: nil); return }
        load(e)
        place(panelRect: panelRect, screen: screen, from: from)
        let start = startRect(from)
        snapshot()
        setBox(start, picture: true)
        if host == nil { window?.alphaValue = 1; window?.orderFront(nil) }
        let goal = finalRect
        ticker.run { [weak self] t in
            guard let self else { return false }
            let p = Curve.quickLook(t)
            self.setBox(mix(start, goal, p), picture: p < 1)
            return p < 1
        }
    }

    /// Closes back into the row's picture (`to`, screen points; nil when the row is out of sight: then it fades
    /// with the panel's own leaving motion instead).
    func close(to: NSRect?) {
        guard isOpen else { return }
        save()
        ticker.stop()
        guard let to else { dismiss(); return }
        let from = box.frame, goal = startRect(to)
        snapshot()
        setBox(from, picture: true)
        if let w = window, w.isKeyWindow { panel?.window?.makeKey() }
        ticker.run { [weak self] t in
            guard let self else { return false }
            let d = 0.13, p = Curve.easeInOut(min(1, t / d))
            self.setBox(mix(from, goal, p), picture: true)
            if p >= 1 { self.dismiss() }
            return p < 1
        }
    }

    /// Gone in one frame (the panel is leaving, or another item took its place). Safe to call when nothing is open
    /// and any number of times: the panel's leaving motion always ends here, also after the preview closed by itself.
    func dismiss() {
        guard isOpen else { return }
        save()
        ticker.stop()
        releaseQuickLook()
        releasePlayer()
        window?.orderOut(nil)
        box.removeFromSuperview()
        entry = nil
    }

    /// Quick Look's view is closed exactly once and while it is still in its window, then let go. 0.4 crashed here
    /// (his two reports, 2026-11-14 17:38 and 17:39: -[QLPreviewView deactivate] asserting «internalState ==
    /// QLPreviewActivatedInternalState»): dismiss() took the view out of its window first, which deactivates it, then
    /// called close(), a second deactivate; and it kept the closed view, so the panel's next leaving motion, which
    /// always calls dismiss(), closed it again. QLPreviewView.close() is not idempotent.
    private func releaseQuickLook() {
        guard let ql = quickLook else { return }
        quickLook = nil
        if ql.window != nil { ql.close() }
        ql.removeFromSuperview()
    }

    private func releasePlayer() {
        guard let pv = playerView else { return }
        playerView = nil
        pv.player?.pause()
        pv.player = nil
        pv.removeFromSuperview()
    }

    /// The rectangle the preview grows from: the final shape, scaled down into the row's picture, so every frame is
    /// a smaller copy of the last (uniform scale).
    private func startRect(_ screenRect: NSRect) -> NSRect {
        let r = toBox(screenRect)
        let s = min(r.width / finalRect.width, r.height / finalRect.height)
        let w = finalRect.width * s, h = finalRect.height * s
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// The container at `r`; while moving, the content is one picture scaled with it and the corner scales too.
    private func setBox(_ r: NSRect, picture moving: Bool) {
        box.frame = r
        let local = NSRect(origin: .zero, size: r.size)
        let scale = r.width / max(1, finalRect.width)
        let corner = panelCorner * scale
        glass.frame = local
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView { g.cornerRadius = corner }
        else { glass.layer?.cornerRadius = corner }
        picture.frame = local
        picture.isHidden = !moving
        content.isHidden = moving
        if !moving { content.frame = local }
        content.layer?.cornerRadius = corner
        picture.wantsLayer = true
        picture.layer?.cornerRadius = corner
        picture.layer?.masksToBounds = true
    }

    /// The live content drawn once into a picture (Quick Look's own content is out of process and draws nothing
    /// there: an image or file stands in by its picture or icon).
    private func snapshot() {
        let size = finalRect.size
        content.frame = NSRect(origin: .zero, size: size)
        content.isHidden = false
        content.layoutSubtreeIfNeeded()
        let im = NSImage(size: size)
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            im.addRepresentation(rep)
        }
        if quickLook != nil || playerView != nil, let e = entry, let stand = standIn(e) {
            im.lockFocusFlipped(true)
            let area = NSRect(x: 0, y: 0, width: size.width, height: size.height - previewFooter).insetBy(dx: 12, dy: 12)
            let a = stand.size.width / max(1, stand.size.height)
            let w = min(area.width, area.height * a), h = w / a
            stand.draw(in: NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h))
            im.unlockFocus()
        }
        picture.image = im
    }

    private func standIn(_ e: Entry) -> NSImage? {
        guard let u = previewURL(e) else { return nil }
        if isMovie(u), let f = videoFrame { return f }
        if UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true, let i = NSImage(contentsOf: u) { return i }
        return NSWorkspace.shared.icon(forFile: u.path)
    }

    // MARK: placing

    /// Over the panel, centred on it, 640 pt wide (Spotlight's width), as tall as the content needs within the
    /// screen; the window covers both where it grows from and where it ends, with room for the shadow.
    private func place(panelRect: NSRect, screen: NSRect, from: NSRect?) {
        let h = min(idealHeight(), screen.height - 80)
        var r = NSRect(x: panelRect.midX - previewWidth / 2, y: panelRect.midY - h / 2, width: previewWidth, height: h)
        if r.maxY > screen.maxY - 20 { r.origin.y = screen.maxY - 20 - h }
        if r.minY < screen.minY + 20 { r.origin.y = screen.minY + 20 }
        let frame = (from.map { r.union($0) } ?? r).insetBy(dx: -panelMargin, dy: -panelMargin)   // room for the glass shadow, as the panel
        if let host {
            if box.superview !== host { host.addSubview(box) }
            hostOrigin = frame.origin
            finalRect = toBox(r)
            return
        }
        let w = window ?? makeWindow()
        w.setFrame(frame, display: false)
        if box.superview !== w.contentView { w.contentView?.addSubview(box) }
        finalRect = toBox(r)
        if !ticker.running { setBox(finalRect, picture: false) }
    }

    private var hostOrigin = NSPoint.zero

    /// Screen points to the container's superview (the window's flipped content view, or the render host).
    private func toBox(_ r: NSRect) -> NSRect {
        if let host {
            let p = host.convert(NSPoint(x: r.minX, y: r.maxY), from: nil)
            return NSRect(x: p.x, y: p.y, width: r.width, height: r.height)
        }
        guard let w = window, let cv = w.contentView else { return r }
        let wr = w.convertFromScreen(r)
        return cv.convert(wr, from: nil)
    }

    private func makeWindow() -> PreviewWindow {
        let w = PreviewWindow()
        w.owner = self
        w.delegate = self
        w.contentView = Flipped()
        window = w
        return w
    }

    private func idealHeight() -> CGFloat {
        guard let e = entry else { return 300 }
        if let c = card { return max(140, min(560, c.frame.height + 2 * Self.cardInset + previewFooter)) }
        if let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + 2 * tv.textContainerInset.height
            return max(140, min(560, used + 24 + previewFooter))
        }
        if e.kind == .image, e.width > 0 {
            let w = previewWidth - 24, h = w * CGFloat(e.height) / CGFloat(e.width)
            return max(200, min(560, h + 24 + previewFooter))
        }
        if playerView != nil, let f = videoFrame, f.size.width > 0 {
            let h = previewWidth * f.size.height / f.size.width
            return max(200, min(560, h + previewFooter))
        }
        return 420
    }

    // MARK: content

    private func load(_ e: Entry) {
        entry = e
        edited = false
        releaseQuickLook()   // first, while Quick Look's view is still in its window
        releasePlayer()
        videoFrame = nil
        for v in content.subviews { v.removeFromSuperview() }
        textView = nil; textScroll = nil; card = nil
        let size = NSSize(width: previewWidth, height: 400)
        content.frame = NSRect(origin: .zero, size: size)
        if let c = linkCard(e, store: store) {
            c.frame.size = c.intrinsicContentSize
            content.addSubview(c)
            card = c
        } else if [.text, .link, .color].contains(e.kind) || (e.kind == .other && !e.text.isEmpty) {
            let sv = NSTextView.scrollableTextView()
            let tv = sv.documentView as! NSTextView
            sv.drawsBackground = false
            sv.scrollerStyle = .overlay
            tv.drawsBackground = false
            tv.isRichText = true
            tv.allowsUndo = true
            tv.isEditable = e.kind == .text
            tv.textContainerInset = NSSize(width: 14, height: 12)
            tv.usesAdaptiveColorMappingForDarkAppearance = true
            tv.font = .systemFont(ofSize: 15)
            tv.textStorage?.setAttributedString(attributed(e))
            tv.delegate = self
            sv.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - previewFooter)
            tv.frame.size.width = sv.contentSize.width
            tv.autoresizingMask = [.width]
            content.addSubview(sv)
            textView = tv; textScroll = sv
        } else if let u = previewURL(e), isMovie(u) {
            let pv = AVPlayerView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - previewFooter))
            pv.controlsStyle = .inline
            pv.showsFullScreenToggleButton = false
            pv.player = AVPlayer(url: u)
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: previewWidth * 2, height: previewWidth * 2)
            videoFrame = (try? g.copyCGImage(at: .zero, actualTime: nil)).map { NSImage(cgImage: $0, size: .zero) }
            content.addSubview(pv)
            playerView = pv
        } else if let u = previewURL(e), let ql = QLPreviewView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - previewFooter), style: .compact) {
            ql.previewItem = u as NSURL
            ql.shouldCloseWithWindow = false
            content.addSubview(ql)
            quickLook = ql
        }
        content.addSubview(footLine)
        content.addSubview(facts)
        revert.sizeToFit()
        content.addSubview(revert)
        content.onLayout = { [weak self] in self?.layoutContent() }
        layoutContent()
        updateFacts()
    }

    private let footLine = Separator()

    /// The content laid out for its current size: the text or Quick Look above, the footer line at the bottom.
    private func layoutContent() {
        let w = content.bounds.width, h = content.bounds.height
        let main = NSRect(x: 0, y: 0, width: w, height: max(0, h - previewFooter))
        textScroll?.frame = main
        quickLook?.frame = main
        playerView?.frame = main
        if let c = card { c.frame.origin = NSPoint(x: ((w - c.frame.width) / 2).rounded(), y: ((main.height - c.frame.height) / 2).rounded()) }
        footLine.frame = NSRect(x: 0, y: h - previewFooter, width: w, height: 1)
        let rw = revert.frame.width
        revert.frame.origin = NSPoint(x: w - 12 - rw, y: h - previewFooter + (previewFooter - revert.frame.height) / 2)
        facts.frame = NSRect(x: 16, y: h - previewFooter + (previewFooter - 17) / 2, width: w - 32 - (revert.isHidden ? 0 : rw + 8), height: 17)
    }

    /// The stored rich text when there is one, else the plain text in the system font.
    private func attributed(_ e: Entry) -> NSAttributedString {
        let reps = store.reps(e.id).first ?? []
        if let r = reps.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }), let d = store.data(r),
           let a = NSAttributedString(rtf: d, documentAttributes: nil) { return a }
        let plain = reps.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }.flatMap(store.data)
            .flatMap { String(data: $0, encoding: .utf8) } ?? e.text
        return NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
    }

    /// A file Quick Look can show: the stored picture, or the first copied file.
    func previewURL(_ e: Entry) -> URL? {
        switch e.kind {
        case .image: return e.thumb.map { store.dir.appendingPathComponent($0) }
        case .files: return e.thumb.map { URL(fileURLWithPath: $0) }
        default: return nil
        }
    }

    /// «2 КБ · 1 162 символа · 180 слов · 3 строки · ≈ 420 токенов», live while editing; an image: its kind,
    /// size, pixels and ≈tokens.
    func updateFacts() {
        guard let e = entry else { return }
        var parts: [String] = []
        if let tv = textView {
            let t = tv.string
            let lines = t.isEmpty ? 0 : t.split(separator: "\n", omittingEmptySubsequences: false).count
            parts = [sizeText(t.utf8.count), counted(t.count, "character|characters"), counted(wordCount(t), "word|words"),
                     counted(lines, "line|lines"), "≈\u{00A0}" + counted(roundTokensUp(tokenEstimate(t)), "token|tokens")]
        } else {
            parts = [kindLabel(e)]
            if card != nil { parts.append(e.address) }   // the card names only the site; the whole address here
            if e.bytes > 0 { parts.append(sizeText(e.bytes)) }
            if e.width > 0 { parts += ["\(e.width) × \(e.height)", "≈\u{00A0}" + counted(roundTokensUp(imageTokens(e.width, e.height)), "token|tokens")] }
        }
        facts.stringValue = parts.joined(separator: "  ·  ")
        revert.isHidden = !(edited || store.hasOriginal(e.id))
        layoutContent()
    }

    // MARK: editing

    func textDidChange(_ n: Notification) {
        edited = true
        updateFacts()
    }

    /// Saves an edited text into the entry (the list shows it at once).
    func save() {
        guard edited, let e = entry, let tv = textView, let ts = tv.textStorage else { return }
        edited = false
        let styled = hasStyle(ts) || store.reps(e.id).first?.contains { $0.type == NSPasteboard.PasteboardType.rtf.rawValue } == true
        let rtf = styled ? ts.rtf(from: NSRange(location: 0, length: ts.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) : nil
        store.edit(e.id, plain: tv.string, rtf: rtf)
        entry = store.entries().first { $0.id == e.id }
        Thumbs.shared.forget(e.id)
        panel?.reload()
    }

    private func hasStyle(_ s: NSTextStorage) -> Bool {
        var found = false
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, _, stop in
            if let f = v as? NSFont, !f.fontDescriptor.symbolicTraits.intersection([.bold, .italic]).isEmpty { found = true; stop.pointee = true }
        }
        return found
    }

    @objc func revertToOriginal() {
        guard let e = entry else { return }
        edited = false
        store.revert(e.id)
        Thumbs.shared.forget(e.id)
        panel?.reload()
        if let fresh = store.entries().first(where: { $0.id == e.id }) {
            entry = fresh
            textView?.textStorage?.setAttributedString(attributed(fresh))
            updateFacts()
        }
    }

    /// ⌘B and ⌘I: the selection's bold or italic turned on, or off when all of it has it (TextEdit's rule).
    func toggle(_ trait: NSFontTraitMask) {
        guard let tv = textView, tv.isEditable, let ts = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let ranges = tv.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {   // no selection: what is typed next
            let f = (tv.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 15)
            tv.typingAttributes[.font] = fm.traits(of: f).contains(trait) ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            return
        }
        var all = true
        for r in ranges {
            ts.enumerateAttribute(.font, in: r) { v, _, _ in
                if !fm.traits(of: (v as? NSFont) ?? .systemFont(ofSize: 15)).contains(trait) { all = false }
            }
        }
        guard tv.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
        ts.beginEditing()
        for r in ranges {
            ts.enumerateAttribute(.font, in: r) { v, sub, _ in
                let f = (v as? NSFont) ?? .systemFont(ofSize: 15)
                ts.addAttribute(.font, value: all ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait), range: sub)
            }
        }
        ts.endEditing()
        tv.didChangeText()
    }

    var isEditing: Bool { window?.isKeyWindow == true && window?.firstResponder === textView }

    // A click outside both windows hides everything, as the panel alone does.
    func windowDidResignKey(_ n: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel else { return }
            if NSApp.keyWindow !== p.window && NSApp.keyWindow !== self.window { p.hide() }
        }
    }

    // Tests and renders.
    var boxFrame: NSRect { box.frame }
    var textForTest: NSTextView? { textView }
    var factsText: String { facts.stringValue }
    var revertShown: Bool { !revert.isHidden }
    var playerViewForTest: AVPlayerView? { playerView }
    func step(_ dt: Double) { Ticker.advance(dt) }
}

/// A flipped view that lays its subviews out itself on every size change (autoresizing masks in a flipped view
/// moved the footer the wrong way).
final class LaidOut: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize s: NSSize) { onLayout?() }
}

/// The preview's window: borderless, non-activating (the app in front stays in front), key only when the person
/// clicks into the text to edit it.
final class PreviewWindow: NSPanel {
    weak var owner: PreviewController?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // No window shadow: Liquid Glass draws its own, and the window server's shadow of that soft shape drew a
        // dark hairline ring ~8 pt outside the glass (on-screen trial of v0.1, 2026-11-14).
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }

    override func sendEvent(_ e: NSEvent) {
        if traceEvents, [.keyDown, .leftMouseDown].contains(e.type) {
            FileHandle.standardError.write(Data("preview \(e.type.rawValue) key=\(isKeyWindow) fr=\(String(describing: firstResponder.map { type(of: $0) }))\n".utf8))
        }
        // The first click into the text puts the caret there at once, as in Spotlight's own field: AppKit would spend
        // it on making the window key (NSTextView takes no first mouse), so the person had to click twice (a test
        // machine run, 2026-11-14).
        if e.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch (shortcutKey(e), mods) {
        case ("b", [.command]): owner?.toggle(.boldFontMask); return true
        case ("i", [.command]): owner?.toggle(.italicFontMask); return true
        default: break
        }
        // The text's own editing keys, as an Edit menu would give them (the app has no menu bar to carry them).
        guard isKeyWindow, let tv = firstResponder as? NSTextView else { return super.performKeyEquivalent(with: e) }
        switch (shortcutKey(e), mods) {
        case ("a", [.command]): tv.selectAll(nil)
        case ("c", [.command]): tv.copy(nil)
        case ("x", [.command]): tv.cut(nil)
        case ("v", [.command]): tv.paste(nil)
        case ("z", [.command]): tv.undoManager?.undo()
        case ("z", [.command, .shift]): tv.undoManager?.redo()
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }

    // Esc while editing: the edit is kept and the preview closes into its row; the panel takes the keys again.
    override func cancelOperation(_ sender: Any?) { owner?.panel?.closePreview() }
}

func isMovie(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension)?.conforms(to: .movie) == true }
