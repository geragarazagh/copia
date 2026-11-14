// Copia's icon: the horn of plenty (variant В of round 4, his pick 2026-11-14). ./build runs it and hands the two SVGs
// to Icon Composer's format as one layer over the system's own plate (apps.md, «Icons, light and dark»; glass, shadow
// and translucency off). This file is the one source of the drawing: the app's Assets.car and AppIcon.icns,
// docs/icon.png and docs/icon-dark.png all come from it.
// Vector, not the family's light.png/dark.png: actool keeps an SVG layer as a Vector asset, so every size is drawn from
// the path itself and the 1 u hinting below stays exact (measured with assetutil 2026-11-14).
//
// Units. The SVG canvas is the plate, 1024 wide (Icon Composer draws the layer over the whole plate; on a macOS icon
// the plate is 824 of 1024, so a 32 px icon has a 26 px plate). The hinting unit u = 1024 / 26 is one device pixel of
// the 32 px icon. The family's mark is 576 of the old 824 plate = 716 here = 18.2 u; the horn is 18 u on its longer side.
// Ink: #1C1C1E on the light plate, white on the dark one, as in his other icons.
//
// The horn (Copia is the goddess, cornucopia is cornu copiae, «Copia's horn»). A horn grows as an equiangular
// (logarithmic) spiral, the cross-section scaling with the radius (D'Arcy Thompson, «On Growth and Form», ch. 11):
// centre line r = R e^(−kθ), width = c·r. From the mouth at the lower right the horn runs clockwise round the bowl
// (that is the C) and winds on inward into its tip. The mouth is the circular cross-section seen tilted: an exact
// ellipse 0.4 as deep as wide (tilt 23.6°), its rim 1 u, the hollow cut to the plate; two rings are the same
// cross-sections further down the horn, same tilt, each the front half of its ellipse, 1 u wide. Ink fitted to 18 u
// and placed by its centroid.
// Usage: icon <dir>   -> <dir>/light.svg, <dir>/dark.svg

import AppKit

let out = CommandLine.arguments[1]
let u: CGFloat = 1024 / 26

func moved(_ p: CGPath, _ dx: CGFloat, _ dy: CGFloat) -> CGPath { var t = CGAffineTransform(translationX: dx, y: dy); return p.copy(using: &t)! }

// Ink centroid, measured on a 1024 raster.
func centroid(_ p: CGPath) -> CGPoint {
    let n = 1024
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
    ctx.setFillColor(gray: 1, alpha: 1); ctx.addPath(p); ctx.fillPath()
    let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var sx = 0.0, sy = 0.0, s = 0.0
    for y in 0..<n { for x in 0..<n { let v = Double(d[y * n + x]); if v > 0 { sx += v * (Double(x) + 0.5); sy += v * (Double(n - 1 - y) + 0.5); s += v } } }
    return CGPoint(x: sx / s, y: sy / s)
}

// MARK: SVG
func svgPath(_ p: CGPath) -> String {
    // Boolean operations leave zero-size subpaths at seams; only subpaths with real extent are written.
    var s = "", sub = "", lo = CGPoint(x: 1e9, y: 1e9), hi = CGPoint(x: -1e9, y: -1e9)
    func flush() { if hi.x - lo.x > 0.5 || hi.y - lo.y > 0.5 { s += sub }; sub = ""; lo = CGPoint(x: 1e9, y: 1e9); hi = CGPoint(x: -1e9, y: -1e9) }
    func see(_ q: CGPoint) { lo = CGPoint(x: min(lo.x, q.x), y: min(lo.y, q.y)); hi = CGPoint(x: max(hi.x, q.x), y: max(hi.y, q.y)) }
    func f(_ v: CGFloat) -> String { var t = String(format: "%.2f", v); while t.hasSuffix("0") { t.removeLast() }; if t.hasSuffix(".") { t.removeLast() }; return t == "-0" ? "0" : t }
    func pt(_ q: CGPoint) -> String { "\(f(q.x)) \(f(1024 - q.y))" }   // SVG is y-down
    p.applyWithBlock { e in
        let el = e.pointee
        switch el.type {
        case .moveToPoint: flush(); see(el.points[0]); sub += "M\(pt(el.points[0]))"
        case .addLineToPoint: see(el.points[0]); sub += "L\(pt(el.points[0]))"
        case .addQuadCurveToPoint: see(el.points[1]); sub += "Q\(pt(el.points[0])) \(pt(el.points[1]))"
        case .addCurveToPoint: see(el.points[2]); sub += "C\(pt(el.points[0])) \(pt(el.points[1])) \(pt(el.points[2]))"
        case .closeSubpath: sub += "Z"
        @unknown default: break
        }
    }
    flush()
    return s
}

// MARK: the horn
func horn() -> CGPath {
    // centre line: r = R e^(−kθ), θ turned clockwise from the mouth at angle φ0; width = c·r.
    // q: the radius shrinks to a quarter per full turn; 1.85 turns of π (just under one revolution) end in the tip.
    let R: CGFloat = 300, q: CGFloat = 0.25, k = -log(q) / (2 * .pi), cw: CGFloat = 0.55
    let phi0: CGFloat = -40 * .pi / 180, thetaMax: CGFloat = 1.85 * .pi
    let n = 1400
    var C: [CGPoint] = [], Wd: [CGFloat] = []
    for i in 0...n {
        let th = thetaMax * CGFloat(i) / CGFloat(n), r = R * exp(-k * th), ph = phi0 - th
        C.append(CGPoint(x: r * cos(ph), y: r * sin(ph))); Wd.append(cw * r)
    }
    // the bell: near the mouth the horn flares, width × (1 + F (1 − s/S)²) over the first S of its length (a quadratic
    // ease, zero slope where it meets the spiral)
    var len: [CGFloat] = [0]; for i in 1...n { len.append(len[i - 1] + hypot(C[i].x - C[i - 1].x, C[i].y - C[i - 1].y)) }
    let F: CGFloat = 0.45, S = 1.8 * Wd[0]
    for i in 0...n where len[i] < S { let x = 1 - len[i] / S; Wd[i] *= 1 + F * x * x }
    var L: [CGPoint] = [], Rr: [CGPoint] = [], N: [CGVector] = []
    for i in 0...n {
        let a = C[max(0, i - 1)], b = C[min(n, i + 1)], dx = b.x - a.x, dy = b.y - a.y, d = hypot(dx, dy)
        let nx = -dy / d, ny = dx / d; N.append(CGVector(dx: nx, dy: ny))
        L.append(CGPoint(x: C[i].x + nx * Wd[i] / 2, y: C[i].y + ny * Wd[i] / 2)); Rr.append(CGPoint(x: C[i].x - nx * Wd[i] / 2, y: C[i].y - ny * Wd[i] / 2))
    }
    // The outline as cubic Béziers: every 14th sample, joined by Catmull-Rom tangents (clean paths in the SVG).
    func smooth(_ p: CGMutablePath, _ q: [CGPoint]) {
        let k = stride(from: 0, to: q.count, by: 14).map { q[$0] } + [q.last!]
        for i in 0..<(k.count - 1) {
            let p0 = k[max(0, i - 1)], p1 = k[i], p2 = k[i + 1], p3 = k[min(k.count - 1, i + 2)]
            p.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
    }
    let body = CGMutablePath(); body.move(to: L[0]); smooth(body, L); body.addLine(to: Rr[n]); smooth(body, Array(Rr.reversed())); body.closeSubpath()
    let tipCap = CGPath(ellipseIn: CGRect(x: C[n].x - Wd[n] / 2, y: C[n].y - Wd[n] / 2, width: Wd[n], height: Wd[n]), transform: nil)
    let tilt: CGFloat = 0.4
    func section(_ i: Int, rim: CGFloat = 0) -> CGPath {   // cross-section circle at C[i], radius less the rim, seen tilted
        let w = Wd[i] - 2 * rim, ang = atan2(N[i].dy, N[i].dx)
        var t = CGAffineTransform(translationX: C[i].x, y: C[i].y).rotated(by: ang)
        return CGPath(ellipseIn: CGRect(x: -w / 2, y: -w * tilt / 2, width: w, height: w * tilt), transform: &t)
    }
    var ink = body.union(tipCap).union(section(0))
    ink = ink.subtracting(section(0, rim: 1 * u))
    // A ring is the band between two cross-sections 1 u apart along the horn: the front halves (bowed toward the tip)
    // of their ellipses, exact elliptic arcs, each run out 1 u past the silhouette so the cut crosses the horn cleanly.
    func ring(_ i: Int, _ j: Int) -> CGPath {
        let p = CGMutablePath()
        for (idx, forward) in [(i, true), (j, false)] {
            let w = Wd[idx] / 2, d = Wd[idx] * tilt / 2, ang = atan2(N[idx].dy, N[idx].dx)
            let t = CGAffineTransform(translationX: C[idx].x, y: C[idx].y).rotated(by: ang)
            let a = CGPoint(x: w + u, y: 0).applying(t), b = CGPoint(x: -w - u, y: 0).applying(t)
            let e = t.scaledBy(x: w, y: d)
            if forward { p.move(to: a); p.addArc(center: .zero, radius: 1, startAngle: 0, endAngle: -.pi, clockwise: true, transform: e); p.addLine(to: b) }
            else { p.addLine(to: b); p.addArc(center: .zero, radius: 1, startAngle: -.pi, endAngle: 0, clockwise: false, transform: e); p.addLine(to: a) }
        }
        p.closeSubpath(); return p
    }
    // the rings sit 1.5 and 2.6 mouth-depths (the mouth ellipse's depth) down the horn
    for kk in [1.5, 2.6] as [CGFloat] {
        let target = kk * Wd[0] * tilt; var i = 0; while len[i] < target { i += 1 }
        var j = i; while len[j] < len[i] + 1 * u { j += 1 }
        ink = ink.subtracting(ring(i, j))
    }
    // fit: 18 u on the longer side
    let bb = ink.boundingBoxOfPath, s = 18 * u / max(bb.width, bb.height)
    var t = CGAffineTransform(scaleX: s, y: s).translatedBy(x: -bb.midX, y: -bb.midY)
    return ink.copy(using: &t)!
}

// Placed by visual mass: the ink centroid on the plate's centre.
let h = horn(), c = centroid(moved(h, 512, 512))
let d = svgPath(moved(h, 1024 - c.x, 1024 - c.y))
for (name, fill) in [("light", "#1C1C1E"), ("dark", "#FFFFFF")] {
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n<path fill=\"\(fill)\" d=\"\(d)\"/>\n</svg>\n"
    try! svg.write(toFile: "\(out)/\(name).svg", atomically: true, encoding: .utf8)
}
