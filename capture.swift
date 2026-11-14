// Watching the clipboard. macOS has no notification for a new copy, so changeCount is polled every 0.25 s (it costs
// nothing and reads no content; Paste does the same). Only a changed count leads to a read, and the read runs off the
// main thread, one at a time: reading data another app promised waits for that app (ClipBook's lesson, its
// PasteboardMonitor). macOS 15.4+ can make a programmatic read ask the person (NSPasteboard.accessBehavior, «Paste from
// Other Apps»; not enforced on 27.2.1): reading only after a change keeps that to one read per copy.
import AppKit

enum ReadResult {
    case copy(Snapshot)
    case empty      // nothing yet: Chromium-based apps clear the pasteboard first and write later without a new count
    case own        // our own write, marked inside its items
    case skip       // transient or auto-generated: no person copied it
    case changed    // the count moved during the read; the next poll reads the newer copy
}

final class Monitor {
    let pb: NSPasteboard
    var onCopy: ((Snapshot) -> Void)?
    /// The app in front when the copy was seen; the copying app's own declaration (org.nspasteboard.source) wins.
    var frontApp: () -> String? = { nil }
    /// The count our own last write produced: seen again, it is skipped without reading (Pesty's way); the marker type
    /// inside every item we write catches what this misses.
    var ownCount = -1
    private(set) var lastCount: Int
    private(set) var denied = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.geragaraza.clip.read", qos: .userInitiated)
    private var reading = false
    private var waiting: (Int, Date, String?)?

    init(_ pb: NSPasteboard = .general) {
        self.pb = pb
        lastCount = pb.changeCount   // what is on the clipboard at launch was copied before, not now
    }

    func start(interval: TimeInterval = 0.25) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)   // .common: keeps polling while a menu or a drag tracks the mouse
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        let c = pb.changeCount
        guard c != lastCount else { return }
        lastCount = c
        if c == ownCount { return }
        if #available(macOS 15.4, *), pb.name == .general {
            // «Never» in Paste from Other Apps: a read would only be refused; the panel says where to change it.
            denied = pb.accessBehavior == .alwaysDeny
            if denied { return }
        }
        // An empty read is tried again for 3 s (ClipBook waits 30 polls of 100 ms for Chromium's late writes).
        request(c, Date().addingTimeInterval(3), frontApp())
    }

    private func request(_ count: Int, _ deadline: Date, _ front: String?) {
        if reading { waiting = (count, deadline, front); return }
        reading = true
        let pb = pb
        queue.async {
            let r = Monitor.read(pb, count: count)
            DispatchQueue.main.async { self.finished(r, count, deadline, front) }
        }
    }

    private func finished(_ r: ReadResult, _ count: Int, _ deadline: Date, _ front: String?) {
        reading = false
        if let w = waiting { waiting = nil; request(w.0, w.1, w.2); return }   // a newer copy replaces this one
        switch r {
        case .copy(var s):
            if s.source == nil { s.source = front }
            onCopy?(s)
        case .empty:
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if self.pb.changeCount == count && !self.reading { self.request(count, deadline, front) }
            }
        case .own, .skip, .changed:
            return
        }
    }

    /// Every item and every type, as the copying app wrote them, except what the system makes up by itself.
    static func read(_ pb: NSPasteboard, count: Int) -> ReadResult {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return .empty }
        var out: [[Rep]] = []
        var concealed = false
        var source: String?
        for it in items {
            let types = it.types.map(\.rawValue)
            if types.contains(NSPasteboard.PasteboardType.own.rawValue) { return .own }
            if types.contains(where: skipMarkers.contains) { return .skip }
            if types.contains(NSPasteboard.PasteboardType.concealed.rawValue) { concealed = true }
            if source == nil, let s = it.string(forType: .source), !s.isEmpty { source = s }
            let hasPNG = types.contains(NSPasteboard.PasteboardType.png.rawValue)
            var reps: [Rep] = []
            for t in types where !isSynthesized(t) {
                // A TIFF beside a PNG is the same picture, often made on request and several times bigger: not read.
                if hasPNG && t == NSPasteboard.PasteboardType.tiff.rawValue { continue }
                if let d = it.data(forType: .init(t)) { reps.append(Rep(type: t, data: d)) }
            }
            if !reps.isEmpty { out.append(reps) }
        }
        if pb.changeCount != count { return .changed }
        let marks: Set<String> = [NSPasteboard.PasteboardType.source.rawValue, NSPasteboard.PasteboardType.concealed.rawValue]
        if out.allSatisfy({ $0.allSatisfy { ($0.data?.isEmpty ?? true) || marks.contains($0.type) } }) { return .empty }
        return .copy(Snapshot(items: out, source: source, concealed: concealed))
    }
}
