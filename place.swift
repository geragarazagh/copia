// Where the panel rests: one of three places on each screen, chosen by the person (his pick 2026-11-14 10:13: top,
// middle and bottom are one interface, not variants; never at the pointer, a side or anywhere random). The middle is
// the default, his «посередине». Each is computed from the screen's visible frame (what the menu bar and the Dock
// leave), so a 13-inch Air and a 16-inch Pro each get their own middle.
import AppKit

enum Place: String, CaseIterable {
    case top, middle, bottom
}

/// The panel's top edge (screen points, y upwards) when it rests at `p` with height `h` on `s`.
/// - top: Spotlight's own place, 38 pt from the top of the screen (measured on this Mac: 6 pt under the menu bar);
/// - middle: the box's centre on the visible frame's centre;
/// - bottom: its bottom edge as far from the visible frame's bottom as the top place is from the menu bar.
func restingTop(_ p: Place, height h: CGFloat, on s: NSScreen) -> CGFloat {
    let v = s.visibleFrame
    switch p {
    case .top: return min(v.maxY - screenGap, s.frame.maxY - 38)
    case .middle: return (v.midY + h / 2).rounded()
    case .bottom: return v.minY + screenGap + h
    }
}
