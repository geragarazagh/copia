// The big window's parts: the sidebar, the content area with its three views of the same items (Icons, List,
// Gallery), and the status bar. AppKit's own controls throughout (NSTableView in the source-list style,
// NSCollectionView, NSTableView with sortable columns), so selection, keyboard, scrolling and their colours are the
// system's: the person's accent and highlight colour, grey when the window is not in front.
import AppKit
import Quartz
import UniformTypeIdentifiers

/// One of the three views, as the controller drives it.
protocol ItemsView: AnyObject {
    var root: NSView { get }
    /// The view that takes the keyboard (arrows, Space, type-select).
    var keyView: NSView { get }
    func reload()
    func select(_ ids: Set<Int64>)
    func updateBadges()
    func scrollToSelection()
    /// The item's picture in screen points (Quick Look zooms from it).
    func pictureRect(for id: Int64) -> NSRect?
    func anchorView(for id: Int64?) -> NSView?
    /// The window changed size: a grid lays itself out again.
    func didResize()
    /// Quick Look's pictures of files arrived: the items on screen take them. True when the view had to reload whole
    /// (the caller then picks the selection again).
    func redrawPictures() -> Bool
}
extension ItemsView {
    func didResize() {}
    func redrawPictures() -> Bool { reload(); return true }
}

// MARK: sidebar

final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: BrowserController?
    private let table = NSTableView()
    /// nil = a gap between the history's kinds and the two places under them.
    private let rows: [Pane?] = [.all, .text, .links, .images, .video, .audio, .files, .colors, nil, .deleted, .settings]
    private var selecting = false

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none
        table.floatsGroupRows = false
        scroll.documentView = table
        view = scroll
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count + 1 }   // + the section's title

    private func pane(_ row: Int) -> Pane? { row == 0 ? nil : rows[row - 1] }

    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool { row == 0 }
    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat { row > 0 && pane(row) == nil ? 12 : 28 }
    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { pane(row) != nil }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        if row == 0 {
            let v = NSTableCellView()
            let l = NSTextField(labelWithString: L("Clipboard"))
            v.textField = l
            v.addSubview(l)
            l.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            return v
        }
        guard let p = pane(row) else { return NSView() }
        let v = NSTableCellView()
        let img = NSImageView(image: NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)!)
        let l = NSTextField(labelWithString: p.title)
        l.lineBreakMode = .byTruncatingTail
        v.imageView = img; v.textField = l
        for s in [img, l] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), img.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 20),
            l.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6), l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -4)])
        return v
    }

    func select(_ p: Pane) {
        _ = view
        guard let i = rows.firstIndex(of: p) else { return }
        selecting = true
        table.selectRowIndexes([i + 1], byExtendingSelection: false)
        selecting = false
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !selecting, let p = pane(table.selectedRow) else { return }
        owner?.open(pane: p)
    }
}

// MARK: content

final class ContentController: NSViewController {
    weak var owner: BrowserController?
    private let area = NSView()
    private let status = NSTextField(labelWithString: "")
    private let statusLine = Separator()
    private(set) var items: ItemsView?
    private var views: [ViewMode: ItemsView] = [:]
    private var settings: SettingsView?
    private var shown: NSView?
    static let statusH: CGFloat = 28

    override func loadView() {
        let v = NSView()
        v.addSubview(area)
        v.addSubview(statusLine)
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        v.addSubview(status)
        view = v
    }

    override func viewDidLayout() { super.viewDidLayout(); relayout() }

    func relayout() {
        let b = view.bounds
        let showStatus = owner?.pane != .settings
        let sh = showStatus ? Self.statusH : 0
        // Scroll views slide under the toolbar by themselves (their content insets); the gallery and settings start
        // under it.
        let top = (owner?.pane == .settings || owner?.mode == .gallery) ? view.safeAreaInsets.top : 0
        area.frame = NSRect(x: 0, y: sh, width: b.width, height: b.height - sh - top)
        statusLine.frame = NSRect(x: 0, y: sh - 1, width: b.width, height: 1)
        status.frame = NSRect(x: 16, y: (sh - 16) / 2, width: b.width - 32, height: 16)
        statusLine.isHidden = !showStatus; status.isHidden = !showStatus
        shown?.frame = area.bounds
        items?.didResize()
    }

    func setStatus(_ s: NSAttributedString) {
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
        status.attributedStringValue = m
    }

    /// The pane's view, in one frame (Finder switches views without animation).
    func show(pane: Pane, mode: ViewMode) {
        _ = view
        guard let o = owner else { return }
        let next: NSView
        if pane == .settings {
            let s = settings ?? SettingsView(owner: o)
            settings = s
            s.refresh()
            next = s
            items = nil
        } else {
            let v = views[mode] ?? {
                let made: ItemsView = switch mode {
                case .icons: IconsView(owner: o)
                case .list: ListView(owner: o)
                case .gallery: GalleryView(owner: o)
                }
                views[mode] = made
                return made
            }()
            items = v
            next = v.root
        }
        if shown !== next {
            shown?.removeFromSuperview()
            area.addSubview(next)
            shown = next
        }
        relayout()
        if pane != .settings, let k = items?.keyView, o.window?.firstResponder is NSWindow || o.window?.firstResponder == nil
            || (o.window?.firstResponder as? NSView).map({ !$0.isDescendant(of: o.searchItem?.searchField ?? NSView()) && !($0 is NSTextView) }) == true {
            o.window?.makeFirstResponder(k)
        }
    }
}

// MARK: shared bits of the item views

/// Keys the item views share: Space is Quick Look, a double click copies, the right click gives the item's menu or,
/// on empty space, the view menu (Finder's).
protocol ItemsHost: AnyObject { var owner: BrowserController? { get } }

final class Items {
    static func key(_ e: NSEvent, owner: BrowserController?) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if e.keyCode == 49 && mods.isEmpty { owner?.quickLook(nil); return true }
        return false
    }
}

/// The order badge of a picked item in the big window's grids: Apple's own ordered selection in a grid of pictures,
/// the Photos picker's numbered accent circle at the picture's bottom-right corner (PHPicker, selection .ordered).
/// The panel's rows show the order as a plain trailing number instead.
func badgeView() -> Badge { let b = Badge(); b.isHidden = true; return b }
func gridBadge(_ n: Int?) -> Int? { n }

// MARK: icons

final class IconsView: NSObject, ItemsView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    weak var owner: BrowserController?
    let scroll = NSScrollView()
    let grid = KeyGrid()
    private var sections: [(String?, [Entry])] = []
    private var syncing = false

    var root: NSView { scroll }
    var keyView: NSView { grid }

    /// Only the pictures of the items on screen change: a reload while Quick Look's pictures came in every 0.2 s ate
    /// the clicks of the first seconds in a pane of many files (his recording 2026-11-15 10:33, Recently Deleted).
    func redrawPictures() -> Bool {
        guard let st = owner?.store else { return false }
        for case let it as IconItem in grid.visibleItems() { it.redrawPicture(store: st) }
        return false
    }

    init(owner: BrowserController) {
        self.owner = owner
        super.init()
        let flow = NSCollectionViewFlowLayout()
        flow.minimumInteritemSpacing = 8
        flow.minimumLineSpacing = 12
        flow.sectionInset = NSEdgeInsets(top: 8, left: 20, bottom: 16, right: 20)
        flow.headerReferenceSize = NSSize(width: 100, height: 34)
        grid.collectionViewLayout = flow
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.backgroundColors = [.clear]
        grid.owner = owner
        grid.register(IconItem.self, forItemWithIdentifier: IconItem.id)
        grid.register(DayHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: DayHeader.id)
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = true
    }

    func reload() {
        guard let o = owner else { return }
        didResize()   // the icon size may have changed (View Options)
        // Day headers when the order is by date, as the panel and Photos group a history; otherwise one plain run.
        if o.sort == .date {
            var out: [(String?, [Entry])] = []
            for e in o.shown {
                let d = dayText(Calendar.current.startOfDay(for: e.copied))
                if out.last?.0 == d { out[out.count - 1].1.append(e) } else { out.append((d, [e])) }
            }
            sections = out
        } else {
            sections = o.shown.isEmpty ? [] : [(nil, o.shown)]
        }
        (grid.collectionViewLayout as? NSCollectionViewFlowLayout)?.headerReferenceSize = NSSize(width: 100, height: o.sort == .date ? 34 : 0)
        grid.reloadData()
    }

    private func path(_ id: Int64) -> IndexPath? {
        for (s, sec) in sections.enumerated() { if let i = sec.1.firstIndex(where: { $0.id == id }) { return IndexPath(item: i, section: s) } }
        return nil
    }
    private func id(_ p: IndexPath) -> Int64 { sections[p.section].1[p.item].id }

    func select(_ ids: Set<Int64>) {
        syncing = true
        grid.selectionIndexPaths = Set(ids.compactMap(path))
        syncing = false
        updateBadges()
    }

    func updateBadges() {
        guard let o = owner else { return }
        for case let it as IconItem in grid.visibleItems() {
            if let p = grid.indexPath(for: it) { it.badge(gridBadge(o.order.count > 1 ? o.order.firstIndex(of: id(p)).map { $0 + 1 } : nil)) }
        }
    }

    func scrollToSelection() {
        guard let o = owner, let c = o.order.last, let p = path(c) else { return }
        grid.scrollToItems(at: [p], scrollPosition: .nearestHorizontalEdge)
    }

    func pictureRect(for id: Int64) -> NSRect? {
        guard let p = path(id), let it = grid.item(at: p) as? IconItem, let w = grid.window else { return nil }
        return w.convertToScreen(it.picture.convert(it.picture.bounds, to: nil))
    }

    func anchorView(for id: Int64?) -> NSView? { id.flatMap(path).flatMap { grid.item(at: $0)?.view } }

    /// Photos' way, not Finder's (his review of 0.4: «no empty space… at any size, up to full screen»): the columns
    /// fill the width exactly. The icon size of View Options sets how many fit; the cells then grow to share the
    /// rest, so a wider window gives a little bigger pictures until one more column fits, and the right edge is
    /// never a strip of nothing. Pictures are drawn at a size rounded up to 16 pt, so resizing makes no new ones.
    private(set) var cell = NSSize(width: 112, height: 142)
    private(set) var cellSide: CGFloat = 64
    static let spacing: CGFloat = 8, inset: CGFloat = 20

    static func columns(width w: CGFloat, iconSize: CGFloat) -> Int {
        let base = IconItem.size(side: iconSize).width
        return max(1, Int((w - 2 * inset + spacing) / (base + spacing)))
    }

    /// The width a grid of `n` columns needs at this icon size (the window's default and minimum come from it).
    static func width(columns n: Int, iconSize: CGFloat) -> CGFloat {
        2 * inset + CGFloat(n) * IconItem.size(side: iconSize).width + CGFloat(n - 1) * spacing
    }

    func didResize() {
        guard let o = owner else { return }
        let w = scroll.contentView.bounds.width
        guard w > 0 else { return }
        let base = IconItem.size(side: o.iconSize).width
        let n = Self.columns(width: w, iconSize: o.iconSize)
        let cw = floor((w - 2 * Self.inset - CGFloat(n - 1) * Self.spacing) / CGFloat(n))
        let side = floor(o.iconSize * cw / base)
        let size = NSSize(width: cw, height: IconItem.size(side: side).height)
        guard size != cell else { return }
        cell = size; cellSide = side
        (grid.collectionViewLayout as? NSCollectionViewFlowLayout)?.minimumInteritemSpacing = Self.spacing
        grid.collectionViewLayout?.invalidateLayout()
        for case let it as IconItem in grid.visibleItems() { it.resize(side: side) }
    }

    func numberOfSections(in c: NSCollectionView) -> Int { sections.count }
    func collectionView(_ c: NSCollectionView, numberOfItemsInSection s: Int) -> Int { sections[s].1.count }

    func collectionView(_ c: NSCollectionView, itemForRepresentedObjectAt p: IndexPath) -> NSCollectionViewItem {
        let it = c.makeItem(withIdentifier: IconItem.id, for: p) as! IconItem
        if let o = owner {
            let e = sections[p.section].1[p.item]
            it.show(e, store: o.store, side: cellSide, deleted: o.pane == .deleted)
            it.badge(gridBadge(o.order.count > 1 ? o.order.firstIndex(of: e.id).map { $0 + 1 } : nil))
        }
        return it
    }

    func collectionView(_ c: NSCollectionView, viewForSupplementaryElementOfKind k: NSCollectionView.SupplementaryElementKind, at p: IndexPath) -> NSView {
        let h = c.makeSupplementaryView(ofKind: k, withIdentifier: DayHeader.id, for: p) as! DayHeader
        h.label.stringValue = sections[p.section].0 ?? ""
        return h
    }

    func collectionView(_ c: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt p: IndexPath) -> NSSize {
        cell
    }

    func collectionView(_ c: NSCollectionView, didSelectItemsAt p: Set<IndexPath>) { changed() }
    func collectionView(_ c: NSCollectionView, didDeselectItemsAt p: Set<IndexPath>) { changed() }

    private func changed() {
        guard !syncing else { return }
        let ids = Set(grid.selectionIndexPaths.map(id))
        owner?.selectionChanged(to: ids, cursor: grid.lastClicked.map(id))
    }
}

final class KeyGrid: NSCollectionView {
    weak var owner: BrowserController?
    var lastClicked: IndexPath?
    override func keyDown(with e: NSEvent) { if !Items.key(e, owner: owner) { super.keyDown(with: e) } }
    override func mouseDown(with e: NSEvent) {
        let p = indexPathForItem(at: convert(e.locationInWindow, from: nil))
        lastClicked = p
        if e.clickCount == 2, p != nil { owner?.copy(nil); return }
        // A plain press on an item: Finder's way, a drag takes the picks out as files (drag.swift), a click picks.
        if let p, e.modifierFlags.intersection([.command, .shift]).isEmpty, let w = window {
            if !selectionIndexPaths.contains(p) {
                let gone = selectionIndexPaths
                selectionIndexPaths = [p]
                if !gone.isEmpty { delegate?.collectionView?(self, didDeselectItemsAt: gone) }
                delegate?.collectionView?(self, didSelectItemsAt: [p])
            }
            let start = convert(e.locationInWindow, from: nil)
            while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
                let q = convert(ev.locationInWindow, from: nil)
                if ev.type == .leftMouseDragged, hypot(q.x - start.x, q.y - start.y) >= 3 { owner?.dragOut(from: self, event: ev, at: q); return }
                if ev.type == .leftMouseUp { break }
            }
            if selectionIndexPaths.count > 1 {   // a plain click on one of several picks leaves that one (Finder)
                let gone = selectionIndexPaths.subtracting([p])
                selectionIndexPaths = [p]
                delegate?.collectionView?(self, didDeselectItemsAt: gone)
            }
            return
        }
        let plain = e.modifierFlags.intersection([.command, .shift]).isEmpty
        let many = p.map { selectionIndexPaths.contains($0) && selectionIndexPaths.count > 1 } ?? false
        super.mouseDown(with: e)
        // A plain click on one of several picked items leaves only that one picked, as in Finder (NSCollectionView
        // keeps them all: seen in a test machine run, 2026-11-14).
        if plain, many, let p, selectionIndexPaths.count > 1 {
            let gone = selectionIndexPaths.subtracting([p])
            selectionIndexPaths = [p]
            delegate?.collectionView?(self, didDeselectItemsAt: gone)
        }
    }
    override func menu(for e: NSEvent) -> NSMenu? {
        guard let o = owner else { return nil }
        if let p = indexPathForItem(at: convert(e.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(p) {
                selectionIndexPaths = [p]
                delegate?.collectionView?(self, didSelectItemsAt: [p])
            }
            return o.itemMenu()
        }
        return o.emptyMenu()
    }
    // ⌘A goes through the controller: picking everything is the order of copying.
    override func selectAll(_ sender: Any?) { owner?.selectAll(sender) }
}

final class DayHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("day")
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); label.frame = NSRect(x: 22, y: 6, width: bounds.width - 44, height: 17) }
}

/// One icon: the picture, under it the title (two lines) and one line of facts; picked, a rounded grey plate behind
/// the picture and the title on the accent colour, as Finder's icon view draws a selection.
final class IconItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("icon")
    let picture = NSImageView()
    private let plate = Plate()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let titleBack = Plate()
    private let meta = NSTextField(labelWithString: "")
    private let badgeV = badgeView()
    private var side: CGFloat = 64

    static func size(side s: CGFloat) -> NSSize { NSSize(width: max(112, s + 48), height: s + 16 + 6 + 34 + 16 + 6) }

    override func loadView() {
        let v = FlippedView()
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byWordWrapping
        name.cell?.truncatesLastVisibleLine = true
        name.font = .systemFont(ofSize: 12)
        name.isSelectable = false
        meta.alignment = .center
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        picture.imageScaling = .scaleProportionallyUpOrDown
        plate.radius = 8
        titleBack.radius = 4
        for s in [plate, picture, titleBack, name, meta, badgeV] as [NSView] { v.addSubview(s) }
        view = v
    }

    private(set) var entry: Entry?
    func redrawPicture(store: Store) {
        if let e = entry { picture.image = Thumbs.shared.thumb(e, store: store, side: (side / 16).rounded(.up) * 16) }
    }
    func show(_ e: Entry, store: Store, side s: CGFloat, deleted: Bool) {
        entry = e
        side = s
        picture.image = Thumbs.shared.thumb(e, store: store, side: (s / 16).rounded(.up) * 16)
        name.stringValue = shownTitle(e)
        // In Recently Deleted each item says how long it stays, as Photos and Notes count the days down there.
        meta.stringValue = deleted ? daysLeft(e) : metaFacts(e, short: true)
        layout()
        update()
    }

    func badge(_ n: Int?) { badgeV.number = n; badgeV.isHidden = n == nil }

    /// A new cell size while the window is resized: the same picture scaled, laid out again.
    func resize(side s: CGFloat) { side = s; layout() }

    private func layout() {
        let w = view.bounds.width > 0 ? view.bounds.width : IconItem.size(side: side).width
        plate.frame = NSRect(x: (w - side - 16) / 2, y: 0, width: side + 16, height: side + 16)
        picture.frame = plate.frame.insetBy(dx: 8, dy: 8)
        let tw = w - 12
        let fit = name.sizeThatFits(NSSize(width: tw, height: 40))
        let th = min(32, ceil(fit.height))
        let lw = min(tw, ceil(fit.width) + 2)   // the widest line: the text wraps the same in it
        name.frame = NSRect(x: (w - lw) / 2, y: side + 16 + 6, width: lw, height: th)
        titleBack.frame = name.frame.insetBy(dx: -4, dy: -1)
        meta.frame = NSRect(x: 2, y: name.frame.maxY + 2, width: w - 4, height: 14)
        badgeV.frame = NSRect(x: plate.frame.maxX - 22, y: plate.frame.maxY - 22, width: 20, height: 20)
    }

    override var isSelected: Bool { didSet { update() } }
    override func viewDidLayout() { super.viewDidLayout(); layout() }

    private func update() {
        let key = view.window?.isKeyWindow ?? true
        plate.color = isSelected ? NSColor.labelColor.withAlphaComponent(0.1) : nil
        titleBack.color = isSelected ? (key ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor) : nil
        name.textColor = isSelected && key ? .alternateSelectedControlTextColor : .labelColor
    }
}

/// «3456 × 2234 · 6,2 МБ», «1 162 символа», «RGB 10 · 132 · 255»: what an icon or a list row says under its name.
func metaFacts(_ e: Entry, short: Bool = false) -> String {
    switch e.kind {
    case .text: return counted(e.text.count, "character|characters")
    case .link:
        return URL(string: e.address)?.host ?? e.address
    case .color: return rgb(e.title).map { "RGB \($0.0) · \($0.1) · \($0.2)" } ?? ""
    case .image:   // an icon has room for one fact: the pixels, as Finder's «Show item info»
        if short { return e.width > 0 ? "\(e.width) × \(e.height)" : sizeText(e.bytes) }
        return ([e.width > 0 ? "\(e.width) × \(e.height)" : nil, sizeText(e.bytes)] as [String?]).compactMap { $0 }.joined(separator: " · ")
    case .files: return e.bytes > 0 ? sizeText(e.bytes) : ""
    case .other: return sizeText(e.bytes)
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// «29 дней»: what Recently Deleted keeps of an entry before it is removed for good.
func daysLeft(_ e: Entry, now: Date = Date()) -> String {
    guard let d = e.deleted else { return "" }
    let left = Int(ceil((d.timeIntervalSince1970 + recentlyDeletedDays * 86400 - now.timeIntervalSince1970) / 86400))
    return counted(max(1, min(Int(recentlyDeletedDays), left)), "day|days")
}

final class Plate: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 6
    override func draw(_ r: NSRect) {
        guard let c = color else { return }
        c.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: list

final class ListView: NSObject, ItemsView, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: BrowserController?
    let scroll = NSScrollView()
    let table = KeyTable()
    private var syncing = false

    var root: NSView { scroll }
    var keyView: NSView { table }

    init(owner: BrowserController) {
        self.owner = owner
        super.init()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.dataSource = self
        table.delegate = self
        table.owner = owner
        table.doubleAction = #selector(doubleClick)
        table.target = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        buildColumns()
    }

    @objc private func doubleClick() { if table.clickedRow >= 0 { owner?.copy(nil) } }

    /// Name first, then the columns View Options shows, each sorting by its own key when its header is clicked.
    func buildColumns() {
        guard let o = owner else { return }
        for c in table.tableColumns { table.removeTableColumn(c) }
        for k in [SortKey.name] + o.columns {
            let c = NSTableColumn(identifier: .init(k.rawValue))
            c.title = k.title
            c.sortDescriptorPrototype = NSSortDescriptor(key: k.rawValue, ascending: k.ascendingFirst)
            switch k {
            case .name: c.width = 360; c.minWidth = 160
            case .date: c.width = 170; c.minWidth = 100
            case .size: c.width = 90; c.minWidth = 60
            case .kind: c.width = 110; c.minWidth = 60
            case .app: c.width = 130; c.minWidth = 60
            }
            table.addTableColumn(c)
        }
        syncSortIndicator()
    }

    private func syncSortIndicator() {
        guard let o = owner else { return }
        syncing = true
        table.sortDescriptors = [NSSortDescriptor(key: o.sort.rawValue, ascending: o.ascending)]
        syncing = false
    }

    func reload() {
        if let o = owner, table.tableColumns.map(\.identifier.rawValue) != ([SortKey.name] + o.columns).map(\.rawValue) { buildColumns() }
        syncSortIndicator()
        table.reloadData()
    }

    func tableView(_ t: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard !syncing, let o = owner, let d = t.sortDescriptors.first, let k = d.key.flatMap(SortKey.init) else { return }
        o.setSort(k, ascending: d.ascending)
    }

    func select(_ ids: Set<Int64>) {
        guard let o = owner else { return }
        syncing = true
        table.selectRowIndexes(IndexSet(o.shown.indices.filter { ids.contains(o.shown[$0].id) }), byExtendingSelection: false)
        syncing = false
        updateBadges()
    }

    func updateBadges() {
        guard let o = owner else { return }
        table.enumerateAvailableRowViews { rv, row in
            let n = gridBadge(o.order.count > 1 ? o.order.firstIndex(of: o.shown[row].id).map { $0 + 1 } : nil)
            (rv.view(atColumn: 0) as? NameCell)?.badge.number = n
            (rv.view(atColumn: 0) as? NameCell)?.badge.isHidden = n == nil
        }
    }

    func scrollToSelection() {
        guard let o = owner, let c = o.order.last, let r = o.shown.firstIndex(where: { $0.id == c }) else { return }
        table.scrollRowToVisible(r)
    }

    func pictureRect(for id: Int64) -> NSRect? {
        guard let o = owner, let r = o.shown.firstIndex(where: { $0.id == id }), let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? NameCell,
              let w = table.window else { return nil }
        return w.convertToScreen(cell.icon.convert(cell.icon.bounds, to: nil))
    }

    func anchorView(for id: Int64?) -> NSView? {
        guard let o = owner, let id, let r = o.shown.firstIndex(where: { $0.id == id }) else { return nil }
        return table.rowView(atRow: r, makeIfNecessary: false)
    }

    func numberOfRows(in t: NSTableView) -> Int { owner?.shown.count ?? 0 }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        guard let o = owner, let c else { return nil }
        let e = o.shown[row]
        let k = SortKey(rawValue: c.identifier.rawValue) ?? .name
        if k == .name {
            let cell = t.makeView(withIdentifier: NameCell.id, owner: nil) as? NameCell ?? NameCell()
            cell.icon.image = Thumbs.shared.thumb(e, store: o.store, side: 16)
            cell.textField?.stringValue = shownTitle(e).replacingOccurrences(of: "\n", with: " ")
            cell.badge.number = gridBadge(o.order.count > 1 ? o.order.firstIndex(of: e.id).map { $0 + 1 } : nil)
            cell.badge.isHidden = cell.badge.number == nil
            return cell
        }
        let cell = t.makeView(withIdentifier: .init("t"), owner: nil) as? NSTableCellView ?? {
            let v = NSTableCellView()
            v.identifier = .init("t")
            let l = NSTextField(labelWithString: "")
            l.lineBreakMode = .byTruncatingTail
            l.textColor = .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(l); v.textField = l
            NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                                         l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
                                         l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            return v
        }()
        switch k {
        case .date:
            let f = DateFormatter(); f.locale = uiLocale; f.doesRelativeDateFormatting = true; f.dateStyle = .medium; f.timeStyle = .short
            cell.textField?.stringValue = o.pane == .deleted ? daysLeft(e) : f.string(from: e.copied)
        case .size: cell.textField?.stringValue = e.bytes > 0 ? sizeText(e.bytes) : "—"
        case .kind: cell.textField?.stringValue = kindName(e)
        case .app: cell.textField?.stringValue = appName(e.app)
        case .name: break
        }
        cell.textField?.alignment = k == .size ? .right : .left
        return cell
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !syncing, let o = owner else { return }
        let ids = Set(table.selectedRowIndexes.map { o.shown[$0].id })
        let c = table.clickedRow >= 0 ? o.shown[table.clickedRow].id : (table.selectedRow >= 0 ? o.shown[table.selectedRow].id : nil)
        o.selectionChanged(to: ids, cursor: c)
    }
}

final class KeyTable: NSTableView {
    weak var owner: BrowserController?
    override func mouseDown(with e: NSEvent) {
        let start = convert(e.locationInWindow, from: nil)
        let r = row(at: start)
        guard r >= 0, e.clickCount == 1, e.modifierFlags.intersection([.command, .shift]).isEmpty, let w = window else { return super.mouseDown(with: e) }
        if !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let q = convert(ev.locationInWindow, from: nil)
            if ev.type == .leftMouseDragged, hypot(q.x - start.x, q.y - start.y) >= 3 { owner?.dragOut(from: self, event: ev, at: q); return }
            if ev.type == .leftMouseUp { break }
        }
        selectRowIndexes([r], byExtendingSelection: false)
    }
    override func keyDown(with e: NSEvent) { if !Items.key(e, owner: owner) { super.keyDown(with: e) } }
    override func menu(for e: NSEvent) -> NSMenu? {
        guard let o = owner else { return nil }
        let r = row(at: convert(e.locationInWindow, from: nil))
        guard r >= 0 else { return o.emptyMenu() }
        if !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        return o.itemMenu()
    }
    override func selectAll(_ sender: Any?) { owner?.selectAll(sender) }
}

final class NameCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("name")
    let icon = NSImageView()
    let badge = badgeView()
    init() {
        super.init(frame: .zero)
        identifier = Self.id
        let l = NSTextField(labelWithString: "")
        l.lineBreakMode = .byTruncatingTail
        textField = l
        for v in [icon, l, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            l.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), l.centerYAnchor.constraint(equalTo: centerYAnchor),
            l.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            badge.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -1), badge.centerYAnchor.constraint(equalTo: icon.bottomAnchor, constant: -1),
            badge.widthAnchor.constraint(equalToConstant: 14), badge.heightAnchor.constraint(equalToConstant: 14)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: gallery

/// Finder's Gallery: the item under the cursor large, a strip of all of them below.
final class GalleryView: NSObject, ItemsView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    weak var owner: BrowserController?
    let box = FlippedLayout()
    let stage = NSView()
    let stripScroll = NSScrollView()
    let strip = KeyGrid()
    private var syncing = false
    private var stageView: NSView?
    private var stageID: Int64?
    static let stripH: CGFloat = 96

    var root: NSView { box }
    var keyView: NSView { strip }

    init(owner: BrowserController) {
        self.owner = owner
        super.init()
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.itemSize = NSSize(width: 72, height: 72)
        flow.minimumLineSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        strip.collectionViewLayout = flow
        strip.dataSource = self
        strip.delegate = self
        strip.isSelectable = true
        strip.allowsMultipleSelection = true
        strip.backgroundColors = [.clear]
        strip.owner = owner
        strip.register(StripItem.self, forItemWithIdentifier: StripItem.id)
        stripScroll.documentView = strip
        stripScroll.drawsBackground = false
        stripScroll.hasHorizontalScroller = true
        stripScroll.autohidesScrollers = true
        box.addSubview(stage)
        box.addSubview(stripScroll)
        box.onLayout = { [weak self] in self?.layout() }
    }

    private func layout() {
        let b = box.bounds
        stage.frame = NSRect(x: 24, y: 16, width: b.width - 48, height: max(0, b.height - Self.stripH - 24))
        stripScroll.frame = NSRect(x: 0, y: b.height - Self.stripH, width: b.width, height: Self.stripH)
        stageView?.frame = stage.bounds
    }

    func reload() {
        strip.reloadData()
        showStage()
    }

    /// The stage shows the last picked item (the cursor), or the first one when nothing is picked.
    func showStage() {
        guard let o = owner else { return }
        let e = o.order.last.flatMap(o.entry) ?? o.shown.first
        guard e?.id != stageID || stageView == nil else { return }
        stageID = e?.id
        stageView?.removeFromSuperview()
        stageView = nil
        guard let e else { return }
        let v: NSView
        switch e.kind {
        case .link where linkCard(e, store: o.store) != nil:
            // The link's own card at Apple's size, in the middle of the stage (link.swift).
            let c = linkCard(e, store: o.store)!
            c.frame.size = c.intrinsicContentSize
            let holder = FlippedLayout()
            holder.addSubview(c)
            holder.onLayout = { [weak holder] in
                guard let h = holder else { return }
                c.frame.origin = NSPoint(x: ((h.bounds.width - c.frame.width) / 2).rounded(), y: ((h.bounds.height - c.frame.height) / 2).rounded())
            }
            v = holder
        case .text, .link, .other:
            let sv = NSTextView.scrollableTextView()
            let tv = sv.documentView as! NSTextView
            tv.isEditable = false
            tv.drawsBackground = false
            sv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 24, height: 20)
            tv.font = .systemFont(ofSize: 16)
            tv.textColor = .labelColor
            tv.string = e.text
            v = sv
        case .color:
            let (r, g, b) = rgb(e.title) ?? (128, 128, 128)
            let sw = Plate()
            sw.radius = 18
            sw.color = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            let holder = FlippedLayout()
            holder.addSubview(sw)
            holder.onLayout = { [weak holder] in
                guard let h = holder else { return }
                let s = min(h.bounds.width, h.bounds.height) * 0.6
                sw.frame = NSRect(x: (h.bounds.width - s) / 2, y: (h.bounds.height - s) / 2, width: s, height: s)
            }
            v = holder
        case .image, .files:
            let ql = QLPreviewView(frame: stage.bounds, style: .normal)!
            ql.shouldCloseWithWindow = false
            ql.previewItem = entryFiles(e, store: o.store, forOpening: true).first as NSURL?
            v = ql
        }
        v.frame = stage.bounds
        stage.addSubview(v)
        stageView = v
    }

    func select(_ ids: Set<Int64>) {
        guard let o = owner else { return }
        syncing = true
        strip.selectionIndexPaths = Set(o.shown.indices.filter { ids.contains(o.shown[$0].id) }.map { IndexPath(item: $0, section: 0) })
        syncing = false
        updateBadges()
        showStage()
    }

    func updateBadges() {
        guard let o = owner else { return }
        for case let it as StripItem in strip.visibleItems() {
            if let p = strip.indexPath(for: it) {
                let n = gridBadge(o.order.count > 1 ? o.order.firstIndex(of: o.shown[p.item].id).map { $0 + 1 } : nil)
                it.badgeV.number = n; it.badgeV.isHidden = n == nil
            }
        }
        showStage()
    }

    func scrollToSelection() {
        guard let o = owner, let c = o.order.last, let i = o.shown.firstIndex(where: { $0.id == c }) else { return }
        strip.scrollToItems(at: [IndexPath(item: i, section: 0)], scrollPosition: .centeredHorizontally)
    }

    func pictureRect(for id: Int64) -> NSRect? {
        guard let o = owner, let i = o.shown.firstIndex(where: { $0.id == id }), let it = strip.item(at: IndexPath(item: i, section: 0)), let w = strip.window else { return nil }
        return w.convertToScreen(it.view.convert(it.view.bounds, to: nil))
    }

    func anchorView(for id: Int64?) -> NSView? { stage }

    func collectionView(_ c: NSCollectionView, numberOfItemsInSection s: Int) -> Int { owner?.shown.count ?? 0 }

    func collectionView(_ c: NSCollectionView, itemForRepresentedObjectAt p: IndexPath) -> NSCollectionViewItem {
        let it = c.makeItem(withIdentifier: StripItem.id, for: p) as! StripItem
        if let o = owner {
            let e = o.shown[p.item]
            it.picture.image = Thumbs.shared.thumb(e, store: o.store, side: 56)
            let n = gridBadge(o.order.count > 1 ? o.order.firstIndex(of: e.id).map { $0 + 1 } : nil)
            it.badgeV.number = n; it.badgeV.isHidden = n == nil
        }
        return it
    }

    func collectionView(_ c: NSCollectionView, didSelectItemsAt p: Set<IndexPath>) { changed() }
    func collectionView(_ c: NSCollectionView, didDeselectItemsAt p: Set<IndexPath>) { changed() }

    private func changed() {
        guard !syncing, let o = owner else { return }
        let ids = Set(strip.selectionIndexPaths.map { o.shown[$0.item].id })
        o.selectionChanged(to: ids, cursor: strip.lastClicked.map { o.shown[$0.item].id })
        showStage()
    }
}

final class StripItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("strip")
    let picture = NSImageView()
    private let plate = Plate()
    let badgeV = badgeView()
    override func loadView() {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: 72, height: 72))
        plate.radius = 8
        plate.frame = v.bounds
        picture.frame = v.bounds.insetBy(dx: 8, dy: 8)
        picture.imageScaling = .scaleProportionallyUpOrDown
        badgeV.frame = NSRect(x: 54, y: 54, width: 16, height: 16)
        for s in [plate, picture, badgeV] as [NSView] { v.addSubview(s) }
        view = v
    }
    override var isSelected: Bool {
        didSet {
            let key = view.window?.isKeyWindow ?? true
            plate.color = isSelected ? (key ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.85) : .unemphasizedSelectedContentBackgroundColor) : nil
        }
    }
}

/// A flipped view that lays its subviews out itself on every size change.
class FlippedLayout: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func resizeSubviews(withOldSize s: NSSize) { onLayout?() }
}
