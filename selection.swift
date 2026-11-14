// Selecting like Finder: a click picks one, ⌘-click adds or removes one, ⇧-click picks the range from the last
// plain or ⌘-clicked row, ⌘A picks everything shown, the arrows move, ⇧-arrows stretch. What Finder does not have
// is the order: the selection remembers the order things were picked in, and the copy pastes them in that order
// (the badges 1…N show it). ⌘A picks in copy order, oldest first, so a pasted batch reads as it was copied.
// Pure logic, no AppKit: tested by ./test selection.

struct Selection: Equatable {
    private(set) var order: [Int64] = []
    /// Where a ⇧-range starts, and what was picked before the range (a new ⇧-click replaces only the range).
    private(set) var anchor: Int64?
    private var base: [Int64] = []
    /// The row the arrows move from: the last one clicked or reached.
    private(set) var cursor: Int64?

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }
    func contains(_ id: Int64) -> Bool { order.contains(id) }

    /// 1…N in the order of picking, shown only when two or more are picked.
    func badge(_ id: Int64) -> Int? {
        guard order.count >= 2, let i = order.firstIndex(of: id) else { return nil }
        return i + 1
    }

    mutating func clear() { self = Selection() }

    /// A plain click: only this one.
    mutating func click(_ id: Int64) {
        order = [id]; anchor = id; base = []; cursor = id
    }

    /// ⌘-click: adds at the end of the order, or takes out.
    mutating func toggle(_ id: Int64) {
        if let i = order.firstIndex(of: id) { order.remove(at: i) } else { order.append(id) }
        anchor = id; cursor = id
        base = order.filter { $0 != id }
    }

    /// ⇧-click or ⇧-arrow: the range from the anchor to `id` in the shown list, added to what was picked before it,
    /// in the direction the range was stretched.
    mutating func extend(to id: Int64, in list: [Int64]) {
        guard let a = anchor, let ia = list.firstIndex(of: a), let ib = list.firstIndex(of: id) else { click(id); return }
        let range = ia <= ib ? Array(list[ia...ib]) : Array(list[ib...ia].reversed())
        order = base + range.filter { !base.contains($0) }
        cursor = id
    }

    /// ⌘A: everything shown, in the order it was copied (`list` is newest first, as the panel shows it).
    mutating func all(_ list: [Int64]) {
        order = list.reversed(); anchor = list.first; base = []; cursor = list.first
    }

    /// ↑ ↓ (and ⇧): one step from the cursor in the shown list; with nothing picked, the first row.
    mutating func move(_ step: Int, in list: [Int64], extending: Bool) {
        guard !list.isEmpty else { return }
        let next: Int64
        if let c = cursor, let i = list.firstIndex(of: c) {
            next = list[max(0, min(list.count - 1, i + step))]
        } else {
            next = step > 0 ? list[0] : list[list.count - 1]
        }
        if extending && anchor != nil && list.contains(anchor!) { extend(to: next, in: list) } else { click(next) }
    }

    /// After a delete: the gone ones leave the order.
    mutating func remove(_ ids: Set<Int64>) {
        order.removeAll { ids.contains($0) }
        base.removeAll { ids.contains($0) }
        if let a = anchor, ids.contains(a) { anchor = order.last }
        if let c = cursor, ids.contains(c) { cursor = order.last }
    }
}
