// Slides for 강의 받아쓰기: notices when the lecture's picture turns to a new slide, keeps one image
// per slide, and makes a PDF with every slide and what was said while it was on screen.
// Sources: the lecture window on a Mac (ScreenSlides.swift) or the video track of an imported file.

import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Comparing frames

/// A 320×180 grayscale thumbnail of a frame, compared tile by tile (16 × 9 tiles of 20×20 pixels) and pixel by
/// pixel — fine enough that body text shows, so two slides with the same layout but different words differ.
struct Signature: Sendable {
    static let w = 320, h = 180, tw = 20, th = 20, cols = 16, rows = 9
    static let tiles = cols * rows
    let px: [UInt8]
    let tileBG: [Int]                          // each tile's background: its most common brightness
    let contrast: Double                       // a blank (black or single-colour) frame has none

    init(px: [UInt8], tileBG: [Int], contrast: Double) { self.px = px; self.tileBG = tileBG; self.contrast = contrast }

    init?(_ image: CGImage) {
        var buf = [UInt8](repeating: 0, count: Signature.w * Signature.h)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: Signature.w, height: Signature.h, bitsPerComponent: 8,
                                      bytesPerRow: Signature.w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: Signature.w, height: Signature.h))
            return true
        }
        guard ok else { return nil }
        px = buf
        var bgs = [Int]()
        for r in 0..<Signature.rows {
            for c in 0..<Signature.cols {
                var hist = [Int](repeating: 0, count: 32), sums = [Int](repeating: 0, count: 32)
                for y in r * Signature.th..<(r + 1) * Signature.th {
                    for x in c * Signature.tw..<(c + 1) * Signature.tw { let v = Int(buf[y * Signature.w + x]); hist[v >> 3] += 1; sums[v >> 3] += v }
                }
                let m = hist.indices.max { hist[$0] < hist[$1] }!
                bgs.append(sums[m] / max(1, hist[m]))
            }
        }
        tileBG = bgs
        let mean = Double(buf.reduce(0) { $0 + Int($1) }) / Double(buf.count)
        contrast = (buf.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(buf.count)).squareRoot()
    }
}

/// How a picture differs from an earlier one, over the tiles we trust. Every strongly changed pixel is one of:
/// added (background before, ink now), removed (ink before, background now), faded (the same ink, paler — an earlier
/// bullet dimmed as the next one appears) or altered (ink replaced by other ink, or the background itself changed).
/// Judged against each tile's own background, so it doesn't matter how lines of text fall into tiles.
struct FrameDiff {
    var changed = [Bool](repeating: false, count: Signature.tiles)
    var tileMeanDiff = [Double](repeating: 0, count: Signature.tiles)   // even faint changes (a fade, compression noise)
    var tiles = 0
    var added = 0, removed = 0, altered = 0, faded = 0
    var meanAbs = 0.0
    var total: Int { added + removed + altered }
    /// Only new content on empty space, nothing taken away: a slide being built up (bullets appearing one by one).
    var grew: Bool { added > 0 && removed <= max(2, min(added / 12, 20)) && altered <= max(3, total / 8) }
    /// Only content taken away, nothing new: an earlier step of the same slide.
    var shrank: Bool { removed > 0 && added <= max(2, min(removed / 12, 20)) && altered <= max(3, total / 8) }

    init(_ old: Signature, _ new: Signature, trusted: [Bool]) {
        let n = Signature.tw * Signature.th
        var sumAll = 0, pixels = 0
        for r in 0..<Signature.rows {
            for c in 0..<Signature.cols {
                let i = r * Signature.cols + c
                guard trusted[i] else { continue }
                let bg = old.tileBG[i], bgMoved = abs(bg - new.tileBG[i]) > 16
                var sum = 0, strong = 0
                for y in r * Signature.th..<(r + 1) * Signature.th {
                    for x in c * Signature.tw..<(c + 1) * Signature.tw {
                        let k = y * Signature.w + x, a = Int(old.px[k]), b = Int(new.px[k]), d = abs(a - b)
                        sum += d
                        guard d > 28 else { continue }
                        strong += 1
                        if bgMoved { altered += 1; continue }
                        let da = abs(a - bg), db = abs(b - bg)
                        if da <= 18 && db > 18 { added += 1 } else if da > 18 && db <= 18 { removed += 1 }
                        else if db < da - 10 && (a - bg) * (b - bg) > 0 { faded += 1 } else { altered += 1 }
                    }
                }
                sumAll += sum; pixels += n
                tileMeanDiff[i] = Double(sum) / Double(n)
                if Double(sum) / Double(n) > 4 || strong * 50 >= n { changed[i] = true; tiles += 1 }     // a colour change, or ≥ 2% sharp
            }
        }
        meanAbs = pixels > 0 ? Double(sumAll) / Double(pixels) : 0
    }

    /// One patch of strongly changed pixels (8-connected).
    struct Blob { var size = 0, added = 0, removed = 0, x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min; var pixels: [Int] = [] }

    /// The patches of strongly changed pixels (ignoring specks under 3 pixels), at most `limit` of them.
    static func blobs(_ old: Signature, _ new: Signature, trusted: [Bool], limit: Int = 120) -> [Blob] {
        let w = Signature.w, h = Signature.h
        var kind = [Int8](repeating: 0, count: w * h)                  // 0 none, 1 added, 2 removed, 3 other
        for y in 0..<h {
            for x in 0..<w {
                let i = (y / Signature.th) * Signature.cols + x / Signature.tw
                guard trusted[i] else { continue }
                let k = y * w + x, a = Int(old.px[k]), b = Int(new.px[k])
                guard abs(a - b) > 28 else { continue }
                let bg = old.tileBG[i], da = abs(a - bg), db = abs(b - bg)
                kind[k] = da <= 18 && db > 18 ? 1 : (da > 18 && db <= 18 ? 2 : 3)
            }
        }
        var out: [Blob] = [], stack: [Int] = []
        for k0 in 0..<(w * h) where kind[k0] != 0 {
            var b = Blob()
            stack.append(k0)
            var seen = [k0]; let first = kind[k0]; kind[k0] = -first
            while let k = stack.popLast() {
                let x = k % w, y = k / w
                b.size += 1; b.pixels.append(k)
                if -kind[k] == 1 { b.added += 1 } else if -kind[k] == 2 { b.removed += 1 }
                b.x0 = min(b.x0, x); b.x1 = max(b.x1, x); b.y0 = min(b.y0, y); b.y1 = max(b.y1, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let j = ny * w + nx
                        if kind[j] > 0 { kind[j] = -kind[j]; stack.append(j); seen.append(j) }
                    }
                }
            }
            _ = seen
            if b.size >= 3 { out.append(b); if out.count >= limit { break } }
        }
        return out
    }
}

extension Signature {
    /// This picture with some tiles taken from another one.
    func merged(with other: Signature, tiles take: [Bool]) -> Signature {
        var p = px, bg = tileBG
        for r in 0..<Signature.rows {
            for c in 0..<Signature.cols where take[r * Signature.cols + c] {
                bg[r * Signature.cols + c] = other.tileBG[r * Signature.cols + c]
                for y in r * Signature.th..<(r + 1) * Signature.th {
                    let row = y * Signature.w
                    for x in c * Signature.tw..<(c + 1) * Signature.tw { p[row + x] = other.px[row + x] }
                }
            }
        }
        return Signature(px: p, tileBG: bg, contrast: contrast)
    }
}

// MARK: - Clean capture (깔끔하게 담기)

/// 깔끔하게 담기: the part of the lecture window that holds the slide, so the browser's bars, the site's and the player's
/// controls and black borders stay out of the PDF. Those look the same from slide to slide; the slide doesn't. So the
/// places that changed when the slide turned — leaving out the lecturer's camera and specks like a clock — mark the
/// slide, and that region is grown out to the edges of the panel it sits in, so a margin or a logo that never changes
/// still comes along. Worked out again with every slide: a place that starts changing later widens it.
enum CleanCapture {
    private static let w = Signature.w, h = Signature.h, cell = 8
    private static let cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell

    /// Tests: explains each step.
    nonisolated(unsafe) static var trace: ((String) -> Void)?

    /// A patch of change between two pictures: its cells, and the box around its changed pixels.
    struct Patch { var cells: [Int]; var x0: Int, x1: Int, y0: Int, y1: Int; var boxes: [(Int, Int, Int, Int)] = [] }

    /// The part to keep (0–1, top-left origin) for pictures of one size, given in the order they were kept — or nil while
    /// it isn't clear yet (one slide so far) or there's nothing worth leaving out. `cameras`: where the lecturer's camera
    /// was. `image`: one of the full pictures, to find the panel's exact edges.
    static func area(_ sigs: [Signature], cameras: [CGRect] = [], moving: [[Bool]] = [], image: CGImage? = nil) -> CGRect? {
        guard sigs.count >= 2 else { return nil }
        let cam = mask(cameras)
        var votes = [Int](repeating: 0, count: cw * ch)
        var seen: [Patch] = []
        for k in 1..<sigs.count {
            // what was moving when either picture was kept (a camera the finder missed, participants, a video) isn't a
            // slide change either — but it doesn't stop the growing below: a video can play inside a slide
            let skip = k < moving.count ? masked(cam, moving[k - 1], moving[k]) : cam
            for patch in changes(sigs[k - 1].px, sigs[k].px, skip) { for c in patch.cells { votes[c] += 1 }; seen.append(patch) }
        }
        // a place that changed at two slide turns (one, early on): one-off flickers — a status line, the player's bar
        // shown once — don't count
        let pairs = sigs.count - 1
        var need = pairs >= 3 ? 2 : 1
        var seed = votes.indices.filter { votes[$0] >= need }
        if seed.count * 1000 < cw * ch * 15, need > 1 { need = 1; seed = votes.indices.filter { votes[$0] >= 1 } }
        trace?("pairs \(pairs), need \(need), seed cells \(seed.count), patches \(seen.count)")
        guard seed.count * 1000 >= cw * ch * 15 else { return nil }        // under 1.5 % of the picture: not yet
        // the changed pixels themselves, not their cells: a cell can reach past the slide's edge into a black border,
        // and growing from there would run on through the black
        var inSeed = [Bool](repeating: false, count: cw * ch)
        for c in seed { inSeed[c] = true }
        var x0 = w, x1 = 0, y0 = h, y1 = 0
        for p in seen {
            for (c, b) in zip(p.cells, p.boxes) where inSeed[c] { x0 = min(x0, b.0); x1 = max(x1, b.1); y0 = min(y0, b.2); y1 = max(y1, b.3) }
        }
        guard x1 > x0, y1 > y0 else { return nil }
        trace?("seed box x \(x0)…\(x1) y \(y0)…\(y1)")
        let ref = reference(sigs)
        (x0, x1, y0, y1) = grow(ref, x0, x1, y0, y1, skip: cam)
        trace?("grown x \(x0)…\(x1) y \(y0)…\(y1)")
        // a strip of the same panel that changed only once — a title bar whose title changed once — comes along when it
        // lines up with the box and touches it; a flicker out in a black border grows into the whole border, which doesn't
        for _ in 0..<4 {
            var merged = false
            for p in seen where p.x1 <= x0 || p.x0 >= x1 || p.y1 <= y0 || p.y0 >= y1 {
                let g = grow(ref, p.x0, p.x1, p.y0, p.y1, skip: cam)
                let t = 3
                let vertical = abs(g.0 - x0) <= t && abs(g.1 - x1) <= t && (abs(g.3 - y0) <= t || abs(g.2 - y1) <= t)
                    && (g.3 - g.2) * 10 <= (y1 - y0) * 4
                let sideways = abs(g.2 - y0) <= t && abs(g.3 - y1) <= t && (abs(g.1 - x0) <= t || abs(g.0 - x1) <= t)
                    && (g.1 - g.0) * 10 <= (x1 - x0) * 4
                guard vertical || sideways else { trace?("  patch x \(p.x0)…\(p.x1) y \(p.y0)…\(p.y1) → grows to x \(g.0)…\(g.1) y \(g.2)…\(g.3): apart"); continue }
                trace?("strip x \(g.0)…\(g.1) y \(g.2)…\(g.3) joins")
                x0 = min(x0, g.0); x1 = max(x1, g.1); y0 = min(y0, g.2); y1 = max(y1, g.3)
                merged = true
            }
            if !merged { break }
        }
        var r = CGRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h), width: Double(x1 - x0) / Double(w), height: Double(y1 - y0) / Double(h))
        if let image { r = snap(r, image) }
        let share = r.width * r.height
        trace?(String(format: "area %.3f %.3f %.3f %.3f (%.0f%%)", r.minX, r.minY, r.width, r.height, share * 100))
        guard share <= 0.94, share >= 0.05, r.width / r.height * Double(w) / Double(h) < 4.5,
              r.height / r.width * Double(h) / Double(w) < 4.5 else { return nil }
        return r
    }

    /// Does this picture show more than its usual surroundings outside `area` — a wider slide, a title screen? Then that
    /// page keeps the whole picture: nothing of a slide is ever cut away.
    static func extends(_ sig: Signature, beyond area: CGRect, reference ref: [UInt8], cameras: [CGRect] = [], moving: [Bool] = []) -> Bool {
        var cam = masked(mask(cameras), moving)
        let ax0 = Int(area.minX * Double(w)), ax1 = Int((area.maxX * Double(w)).rounded(.up))
        let ay0 = Int(area.minY * Double(h)), ay1 = Int((area.maxY * Double(h)).rounded(.up))
        for y in max(0, ay0 - 1)..<min(h, ay1 + 1) { for x in max(0, ax0 - 1)..<min(w, ax1 + 1) { cam[y * w + x] = true } }
        let more = changes(ref, sig.px, cam).reduce(0) { $0 + $1.cells.count }
        if more * 100 >= cw * ch * 4 { return true }
        // a slide that runs on past the area (a wider one, a dark one whose edge is faint) shows up right at its border,
        // however little of it there is: a ring of pixels 2–5 outside the area, against the usual picture
        let camOnly = masked(mask(cameras), moving)
        var ring = 0, hits = 0
        for y in max(0, ay0 - 5)..<min(h, ay1 + 5) {
            for x in max(0, ax0 - 5)..<min(w, ax1 + 5) {
                let dx = x < ax0 ? ax0 - x : (x >= ax1 ? x - ax1 + 1 : 0), dy = y < ay0 ? ay0 - y : (y >= ay1 ? y - ay1 + 1 : 0)
                guard max(dx, dy) >= 2, !camOnly[y * w + x] else { continue }
                ring += 1
                if abs(Int(ref[y * w + x]) - Int(sig.px[y * w + x])) > 16 { hits += 1 }
            }
        }
        return ring > 0 && hits * 100 >= ring * 3 && hits >= 6
    }

    /// Content a page shows outside `area` that the other pages don't — the edge of a wider slide, however small (a
    /// near-black wide slide is only seen by its text). Places that differ on many pages (a clock, a progress bar, a
    /// camera the finder missed) and thin bands across the picture (the player's controls shown) don't count.
    static func pageSpecific(_ sigs: [Signature], area: CGRect, reference ref: [UInt8], cameras: [CGRect] = [], moving: [[Bool]] = []) -> [Bool] {
        let n = sigs.count
        guard n >= 2, ref.count == w * h else { return Array(repeating: false, count: n) }
        let ax0 = Int(area.minX * Double(w)) - 1, ax1 = Int((area.maxX * Double(w)).rounded(.up)) + 1
        let ay0 = Int(area.minY * Double(h)) - 1, ay1 = Int((area.maxY * Double(h)).rounded(.up)) + 1
        let cam = mask(cameras)
        var often = [Int](repeating: 0, count: w * h)
        var strong: [[Bool]] = []
        for (k, sig) in sigs.enumerated() {
            let skip = k < moving.count ? masked(cam, moving[k]) : cam
            var m = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w where !(x >= ax0 && x < ax1 && y >= ay0 && y < ay1) {
                    let i = y * w + x
                    if !skip[i] && abs(Int(ref[i]) - Int(sig.px[i])) > 40 { m[i] = true; often[i] += 1 }
                }
            }
            strong.append(m)
        }
        let volatile = max(2, Int((Double(n) * 0.4).rounded(.up)))
        return strong.map { m in
            var count = [Int](repeating: 0, count: cw * ch)
            for i in 0..<(w * h) where m[i] && often[i] < volatile { count[(i / w / cell) * cw + (i % w) / cell] += 1 }
            var pixels = 0
            for p in cellPatches(count.map { $0 >= 2 }) where p.cells.count >= 3 && !(p.r1 - p.r0 <= 1 && (p.c1 - p.c0 + 1) * 10 >= cw * 4) {
                pixels += p.cells.reduce(0) { $0 + count[$1] }
            }
            return pixels >= 30
        }
    }

    /// Connected patches of cells (8-neighbours), with their bounds in cells.
    private static func cellPatches(_ on: [Bool]) -> [(cells: [Int], c0: Int, c1: Int, r0: Int, r1: Int)] {
        var left = on, out: [(cells: [Int], c0: Int, c1: Int, r0: Int, r1: Int)] = []
        for start in left.indices where left[start] {
            var cells: [Int] = [], stack = [start]
            left[start] = false
            var c0 = cw, c1 = 0, r0 = ch, r1 = 0
            while let c = stack.popLast() {
                cells.append(c)
                let cx = c % cw, cy = c / cw
                c0 = min(c0, cx); c1 = max(c1, cx); r0 = min(r0, cy); r1 = max(r1, cy)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < cw, ny >= 0, ny < ch, left[ny * cw + nx] else { continue }
                        left[ny * cw + nx] = false
                        stack.append(ny * cw + nx)
                    }
                }
            }
            out.append((cells, c0, c1, r0, r1))
        }
        return out
    }

    /// Each pixel's middle value over (up to nine of) the pictures: what the window usually looks like.
    static func reference(_ sigs: [Signature]) -> [UInt8] {
        guard sigs.count > 2 else { return sigs.last?.px ?? [] }
        let pick = (0..<min(9, sigs.count)).map { sigs[$0 * (sigs.count - 1) / max(1, min(9, sigs.count) - 1)].px }
        var out = [UInt8](repeating: 0, count: w * h), vals = [UInt8](repeating: 0, count: pick.count)
        for i in 0..<(w * h) {
            for (k, p) in pick.enumerated() { vals[k] = p[i] }
            vals.sort()
            out[i] = vals[vals.count / 2]
        }
        return out
    }

    /// A pixel mask with the given tiles (16 × 9, the slide detector's) added.
    private static func masked(_ base: [Bool], _ tileSets: [Bool]...) -> [Bool] {
        var out = base
        for tiles in tileSets where tiles.count == Signature.tiles {
            for (i, on) in tiles.enumerated() where on {
                let tx = (i % Signature.cols) * Signature.tw, ty = (i / Signature.cols) * Signature.th
                for y in ty..<ty + Signature.th { for x in tx..<tx + Signature.tw { out[y * w + x] = true } }
            }
        }
        return out
    }

    /// Pixels a camera rectangle covers, with the same margin the slide detector gives it.
    private static func mask(_ cameras: [CGRect]) -> [Bool] {
        var cam = [Bool](repeating: false, count: w * h)
        for r in cameras {
            let g = r.insetBy(dx: -0.015, dy: -0.02)
            let x0 = max(0, Int(g.minX * Double(w))), x1 = min(w, Int((g.maxX * Double(w)).rounded(.up)))
            let y0 = max(0, Int(g.minY * Double(h))), y1 = min(h, Int((g.maxY * Double(h)).rounded(.up)))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { cam[y * w + x] = true } }
        }
        return cam
    }

    /// The patches (cells of 8×8 pixels) that changed between two pictures and are big enough to be slide content: at
    /// least 1 % of the picture and two cells high and wide — a clock, a progress bar or a pointer never are — and not
    /// a thin band across the picture (the player's control bar showing up, a line of subtitles).
    private static func changes(_ a: [UInt8], _ b: [UInt8], _ cam: [Bool]) -> [Patch] {
        var count = [Int](repeating: 0, count: cw * ch)
        var bx0 = [Int](repeating: w, count: cw * ch), bx1 = [Int](repeating: 0, count: cw * ch)
        var by0 = [Int](repeating: h, count: cw * ch), by1 = [Int](repeating: 0, count: cw * ch)
        for y in 0..<h {
            let row = y * w, crow = (y / cell) * cw
            for x in 0..<w where !cam[row + x] && abs(Int(a[row + x]) - Int(b[row + x])) > 28 {
                let c = crow + x / cell
                count[c] += 1
                bx0[c] = min(bx0[c], x); bx1[c] = max(bx1[c], x + 1); by0[c] = min(by0[c], y); by1[c] = max(by1[c], y + 1)
            }
        }
        var changed = count.map { $0 >= 3 }
        var out: [Patch] = []
        for start in changed.indices where changed[start] {
            var patch: [Int] = [], stack = [start]
            changed[start] = false
            var c0 = cw, c1 = 0, r0 = ch, r1 = 0
            while let c = stack.popLast() {
                patch.append(c)
                let cx = c % cw, cy = c / cw
                c0 = min(c0, cx); c1 = max(c1, cx); r0 = min(r0, cy); r1 = max(r1, cy)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < cw, ny >= 0, ny < ch, changed[ny * cw + nx] else { continue }
                        changed[ny * cw + nx] = false
                        stack.append(ny * cw + nx)
                    }
                }
            }
            let band = r1 - r0 <= 1 && (c1 - c0 + 1) * 10 >= cw * 4
            guard patch.count * 100 >= cw * ch, c1 > c0, r1 > r0, !band else { continue }
            var p = Patch(cells: patch, x0: w, x1: 0, y0: h, y1: 0)
            for c in patch {
                p.x0 = min(p.x0, bx0[c]); p.x1 = max(p.x1, bx1[c]); p.y0 = min(p.y0, by0[c]); p.y1 = max(p.y1, by1[c])
                p.boxes.append((bx0[c], bx1[c], by0[c], by1[c]))
            }
            out.append(p)
        }
        return out
    }

    /// Grows a box out to the edges of the panel it sits in: a side moves out while the line beyond it looks like the
    /// line inside it (judged by each line's middle brightness, so text crossing a line doesn't stop it), and stops at a
    /// border — the slide's edge against the black, the bar above the player.
    private static func grow(_ ref: [UInt8], _ ax0: Int, _ ax1: Int, _ ay0: Int, _ ay1: Int, skip: [Bool]) -> (Int, Int, Int, Int) {
        var x0 = ax0, x1 = ax1, y0 = ay0, y1 = ay1
        /// A line's middle brightness, and whether it is one even tone (a black border, a bar, a plain margin) — a row
        /// through text isn't, so text never passes for an edge. The camera's pixels don't count; a line that is mostly
        /// camera blocks the way (the camera isn't slide).
        typealias Line = (m: Int, even: Bool, camera: Bool)
        func line(_ vals: [UInt8], of total: Int) -> Line {
            guard vals.count * 5 >= total * 2, !vals.isEmpty else { return (0, false, true) }
            let m = median(vals)
            return (m, vals.filter { abs(Int($0) - m) <= 12 }.count * 4 >= vals.count * 3, false)
        }
        func col(_ x: Int) -> Line { line((y0..<y1).compactMap { skip[$0 * w + x] ? nil : ref[$0 * w + x] }, of: y1 - y0) }
        func row(_ y: Int) -> Line { line((x0..<x1).compactMap { skip[y * w + $0] ? nil : ref[y * w + $0] }, of: x1 - x0) }
        // a border: two even-toned lines clearly different (a margin against a black border or a bar) — or near-black
        // after anything lighter (a dark slide against black is a small step; a photo reaching the edge isn't even)
        func border(_ o: Line, _ i: Line) -> Bool {
            o.camera || (o.even && ((i.even && abs(o.m - i.m) > 28) || (o.m <= 10 && i.m >= o.m + 12)))
        }
        // first each side settles onto a border just inside it: changed pixels can spill a pixel past a slide's edge, and
        // growing from the black side would run on through the black
        for _ in 0..<4 {
            if x1 - x0 > 8, let p = (x0 + 1...x0 + 3).first(where: { border(col($0 - 1), col($0)) }) { x0 = p }
            if x1 - x0 > 8, let p = (x1 - 3...x1 - 1).reversed().first(where: { border(col($0), col($0 - 1)) }) { x1 = p }
            if y1 - y0 > 8, let p = (y0 + 1...y0 + 3).first(where: { border(row($0 - 1), row($0)) }) { y0 = p }
            if y1 - y0 > 8, let p = (y1 - 3...y1 - 1).reversed().first(where: { border(row($0), row($0 - 1)) }) { y1 = p }
        }
        func px(_ x: Int, _ y: Int) -> Int? {
            guard x >= 0, x < w, y >= 0, y < h, !skip[y * w + x] else { return nil }
            return Int(ref[y * w + x])
        }
        /// Past a border, is the band beyond still the slide's? A band of the slide's own template — a footer, a banner,
        /// a sidebar, a rule over footer text, the margin above a table — ends where the slide ends, before the picture's
        /// edges; a browser's or a site's bar runs on to them. A full-width band followed by a black border is the
        /// video's own (the lecture letterboxed in the player), so it belongs too. Near-black is never the slide's.
        func slideRow(_ y: Int, away dy: Int) -> Bool {
            let o = row(y)
            guard o.even, o.m > 24 else { return false }
            var lo = x0, hi = x1 - 1
            while lo > 0, let v = px(lo - 1, y), abs(v - o.m) <= 20 { lo -= 1 }
            while hi < w - 1, let v = px(hi + 1, y), abs(v - o.m) <= 20 { hi += 1 }
            if lo > 1 && hi < w - 2 { return true }
            var yy = y
            while yy >= 0, yy < h, abs(row(yy).m - o.m) <= 16 { yy += dy }
            guard yy >= 0, yy < h, yy + dy >= 0, yy + dy < h else { return false }
            let b1 = row(yy), b2 = row(yy + dy)
            return b1.even && b1.m <= 24 && b2.even && b2.m <= 24
        }
        func slideCol(_ x: Int, away dx: Int) -> Bool {
            let o = col(x)
            guard o.even, o.m > 24 else { return false }
            var lo = y0, hi = y1 - 1
            while lo > 0, let v = px(x, lo - 1), abs(v - o.m) <= 20 { lo -= 1 }
            while hi < h - 1, let v = px(x, hi + 1), abs(v - o.m) <= 20 { hi += 1 }
            if lo > 1 && hi < h - 2 { return true }
            var xx = x
            while xx >= 0, xx < w, abs(col(xx).m - o.m) <= 16 { xx += dx }
            guard xx >= 0, xx < w, xx + dx >= 0, xx + dx < w else { return false }
            let b1 = col(xx), b2 = col(xx + dx)
            return b1.even && b1.m <= 24 && b2.even && b2.m <= 24
        }
        for _ in 0..<8 {
            var moved = false
            while x0 > 0, !border(col(x0 - 1), col(x0)) || slideCol(x0 - 1, away: -1) { x0 -= 1; moved = true }
            while x1 < w, !border(col(x1), col(x1 - 1)) || slideCol(x1, away: 1) { x1 += 1; moved = true }
            while y0 > 0, !border(row(y0 - 1), row(y0)) || slideRow(y0 - 1, away: -1) { y0 -= 1; moved = true }
            while y1 < h, !border(row(y1), row(y1 - 1)) || slideRow(y1, away: 1) { y1 += 1; moved = true }
            if !moved { break }
        }
        return (x0, x1, y0, y1)
    }

    private static func median(_ v: [UInt8]) -> Int {                // counted, not sorted: it runs for every line tried
        guard !v.isEmpty else { return 0 }
        var hist = [Int](repeating: 0, count: 256)
        for x in v { hist[Int(x)] += 1 }
        var seen = 0
        for (value, n) in hist.enumerated() { seen += n; if seen > v.count / 2 { return value } }
        return 255
    }

    /// The box's sides moved onto the exact edges, looking at the full picture (a few pixels either way).
    private static func snap(_ r: CGRect, _ image: CGImage) -> CGRect {
        let gw = min(960, image.width), gh = max(1, Int(Double(image.height) * Double(gw) / Double(image.width)))
        var g = [UInt8](repeating: 0, count: gw * gh)
        let ok: Bool = g.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: gw, height: gh))
            return true
        }
        guard ok else { return r }
        var x0 = Int(r.minX * Double(gw)), x1 = Int(r.maxX * Double(gw)), y0 = Int(r.minY * Double(gh)), y1 = Int(r.maxY * Double(gh))
        let reach = Int((Double(gw) / Double(w) * 2).rounded(.up)) + 1
        func col(_ x: Int) -> Int { median((y0..<y1).map { g[$0 * gw + x] }) }
        func row(_ y: Int) -> Int { median((x0..<x1).map { g[y * gw + $0] }) }
        // each side goes to the strongest step between neighbouring lines nearby (staying put if there is none)
        func best(_ around: Int, _ lo: Int, _ hi: Int, _ line: (Int) -> Int) -> Int {
            var at = around, top = 24
            for p in max(lo, around - reach)...min(hi, around + reach) {
                let s = abs(line(p) - line(p - 1))
                if s > top { top = s; at = p }
            }
            return at
        }
        guard x1 - x0 > 2 * reach, y1 - y0 > 2 * reach else { return r }
        x0 = best(x0, 1, gw - 1, col); x1 = best(x1, 1, gw - 1, col)
        y0 = best(y0, 1, gh - 1, row); y1 = best(y1, 1, gh - 1, row)
        guard x1 > x0, y1 > y0 else { return r }
        return CGRect(x: Double(x0) / Double(gw), y: Double(y0) / Double(gh), width: Double(x1 - x0) / Double(gw), height: Double(y1 - y0) / Double(gh))
    }
}

// MARK: - Detecting slides

/// Decides when the picture shows a new slide. Feed it frames in time order (live: twice a second;
/// files: once a second). A picture counts once it has held still for `settle` seconds, so transitions, fades,
/// animations and scrolling don't make pages. Each new picture is compared with the current slide's fullest picture:
/// content only added (a bullet appearing) updates the page, content only taken away is an earlier step of it, and
/// anything else — however small, like one revised number — is another slide, unless it is one of the things that
/// change on their own: a pointer that moved, the lecturer's camera, subtitles, a clock, a chat, a playing video
/// (parts that keep moving are ignored until they have been still for a few seconds). A return to an earlier slide is
/// recognised rather than captured twice.
final class SlideDetector {
    enum Event: Equatable { case new(Int, Double), again(Int, Double), update(Int) }

    let settle: Double
    private var slides: [Signature] = []                  // each slide's fullest picture
    private var current: Int?
    /// The current slide as it should look now: its fullest picture, with what we decided to ignore (a camera, a pointer,
    /// a clock) as it is now.
    private var ref: Signature?
    private var last: Signature?
    private var lastT = 0.0
    private var candidate: (sig: Signature, since: Double)?
    private var streak = [Int](repeating: 0, count: Signature.tiles)            // consecutive frames each tile moved
    private var movedAt = [Double](repeating: -1000, count: Signature.tiles)  // when a tile last moved like a camera or video
    private var ticks = [[Double]](repeating: [], count: Signature.tiles)     // when each tile had tiny changes (a clock?)
    private var spots: [(box: Box, t: Double, since: Double)] = []            // recent small, local changes (and their picture)
    private var subtitlesSeen = -1000.0                                       // when subtitles at the bottom last changed
    private var recent: [(t: Double, sig: Signature)] = []                    // the last 30 s of frames
    private var noise = 0.0, speckNoise = 0.0                                 // frame-to-frame jitter of a still picture
    private var pointerSeen = -1000.0                                         // when a pointer was last seen moving
    private var now = 0.0
    /// The motion going on now: when it started, the still picture before it, frames during it, scrolling frames, the
    /// tiles that moved, and what had been learned before it.
    private var episode: (start: Double, from: Signature, frames: [Signature], scrolls: Int, tiles: Set<Int>, movedAt: [Double])?
    private let hold = 6.0                                                    // seconds a moving part stays ignored after it stops
    /// The lecturer's camera: the compact rectangle that keeps changing (CameraFinder). Its tiles are left out of every
    /// comparison — a face turning is never a new slide — and the app shows it on the live preview.
    private let cameraFinder = CameraFinder(aspect: Double(Signature.w) / Double(Signature.h))
    private(set) var cameraRect: CGRect?
    private var cameraTiles = [Bool](repeating: false, count: Signature.tiles)
    private var cameraAt = [Double](repeating: -1000, count: Signature.tiles)  // when the camera last covered each tile

    init(settle: Double) { self.settle = settle }

    /// Tests: explains each decision.
    var trace: ((String) -> Void)?

    private var trusted: [Bool] { (0..<Signature.tiles).map { now - movedAt[$0] > hold && !cameraTiles[$0] } }
    /// The tiles that are moving now — a camera, a strip of participants, a playing video — which 깔끔하게 담기 doesn't
    /// take for slide changes.
    var moving: [Bool] { trusted.map { !$0 } }

    /// The tiles a camera rectangle covers, with a small margin: its edge bleeds into the tiles around it when the frame is
    /// shrunk, so a tile goes with the camera once 5 % of it is inside.
    static func tiles(in rect: CGRect?) -> [Bool] {
        var out = [Bool](repeating: false, count: Signature.tiles)
        guard let r = rect?.insetBy(dx: -0.015, dy: -0.02) else { return out }
        let tw = 1.0 / Double(Signature.cols), th = 1.0 / Double(Signature.rows)
        for i in 0..<Signature.tiles {
            let tile = CGRect(x: Double(i % Signature.cols) * tw, y: Double(i / Signature.cols) * th, width: tw, height: th)
            let o = tile.intersection(r)
            if !o.isNull, Double(o.width * o.height) >= 0.05 * tw * th { out[i] = true }
        }
        return out
    }

    func step(_ t: Double, _ sig: Signature) -> Event? {
        now = t
        cameraRect = cameraFinder.add(gray: sig.px, width: Signature.w, height: Signature.h, at: t)?.rect
        for (i, on) in SlideDetector.tiles(in: cameraRect).enumerated() where on { cameraAt[i] = t }
        cameraTiles = cameraAt.map { t - $0 < hold }      // where the camera just was stays left out a while: it may have moved
        defer { last = sig; lastT = t }
        recent.append((t, sig))
        if let f = recent.first, t - f.t > 30 { recent.removeFirst() }
        guard let prev = last else { candidate = (sig, t); return nil }
        let all = [Bool](repeating: true, count: Signature.tiles)
        let moving = FrameDiff(prev, sig, trusted: all)
        // a camera or a video moves as one or two compact patches while the rest holds still; a fade, a scroll or a
        // transition touches many separate lines at once (if only faintly) — that must not teach us to ignore those places
        // — or, in a video call, as several small ones (a strip of participants' cameras)
        let faint = moving.tileMeanDiff.map { $0 > max(0.8, noise * 2) }
        let faintPatches = SlideDetector.patches(faint), faintShare = Double(faint.filter { $0 }.count) / Double(Signature.tiles)
        var local = faintShare < 0.6 && (faintPatches.count <= 2 || (faintShare < 0.2 && faintPatches.allSatisfy { $0.count <= 12 }))
        let scroll = moving.tiles > 0 && SlideDetector.scrolled(prev, sig, moving.changed)    // a document scrolling: nothing to learn
        if scroll { local = false }
        // a pointer moving about (the presenter's cursor, a laser) is not a moving part to learn: it would hide the slide
        // wherever it went. Looked for where nothing is known to move (a camera beside it keeps moving too).
        let known = trusted
        let free = FrameDiff(prev, sig, trusted: known)
        var pointerTiles = Set<Int>()
        if free.total > 0, free.total < 500, free.tiles <= 4 {
            let marks = FrameDiff.blobs(prev, sig, trusted: known)
            if SlideDetector.pointerOnly(marks, free, moved: true) {
                pointerSeen = t
                for b in marks { for k in b.pixels { pointerTiles.insert((k / Signature.w / Signature.th) * Signature.cols + (k % Signature.w) / Signature.tw) } }
            }
        }
        // A camera or a video moves in frame after frame; a cut to the next slide moves once. Only what keeps moving is
        // learned (and ignored until it has been still for a few seconds) — once the motion proves not to be a transition:
        // it goes on longer than any transition, or it stops without having been a blend from one picture to the next.
        // A fade, a wipe or a scroll between two slides is forgotten.
        for i in 0..<Signature.tiles { streak[i] = moving.changed[i] && local && !pointerTiles.contains(i) ? streak[i] + 1 : 0 }
        if moving.total > 0, moving.total < 80, moving.tiles <= 2 {      // a tiny change: a clock ticking, maybe
            for i in 0..<Signature.tiles where moving.changed[i] { ticks[i] = (ticks[i] + [t]).suffix(3) }
        }
        let persistent = Set((0..<Signature.tiles).filter { streak[$0] >= 2 })
        if moving.tiles > 0 {
            if episode == nil { episode = (t, prev, [], 0, [], movedAt) }
            if episode!.frames.count < 12 { episode!.frames.append(sig) }
            if scroll { episode!.scrolls += 1 }
            episode!.tiles.formUnion(persistent)
            if t - episode!.start >= 3.5 { learnMoving(t, persistent) }   // only what is moving now
        } else if let ep = episode, ep.frames.count >= 2 {               // (one moving frame: too short to tell or to learn)
            episode = nil
            let tr = ep.scrolls * 2 >= ep.frames.count || (t - ep.start < 6 && SlideDetector.transition(from: ep.from, through: ep.frames, to: sig))
            if tr { movedAt = ep.movedAt } else { learnMoving(t, ep.tiles) }
        } else { episode = nil }
        guard sig.contrast > 6 else { candidate = nil; return nil }      // black / blank frame (a transition)
        let mask = trusted
        let usable = mask.filter { $0 }.count
        guard usable >= 30 else { candidate = nil; return nil }          // mostly moving video: not slides
        let motion = FrameDiff(prev, sig, trusted: mask)
        let movedShare = Double(motion.tiles) / Double(usable)
        if movedShare < 0.03 {
            noise = noise == 0 ? motion.meanAbs : noise * 0.95 + motion.meanAbs * 0.05
            speckNoise = speckNoise * 0.95 + Double(motion.total) * 0.05
        }
        let calm = max(1.2, noise * 2.2), specks = max(6, speckNoise * 3)
        let still = movedShare < 0.03 && motion.meanAbs < calm && Double(motion.total) < specks

        let cand: (sig: Signature, since: Double)
        if let c = candidate {
            let d = FrameDiff(c.sig, sig, trusted: mask)
            cand = Double(d.tiles) / Double(usable) < 0.03 && d.meanAbs < calm * 1.5 && Double(d.total) < specks ? c : (sig, t)
        } else { cand = (sig, t) }
        candidate = cand
        guard still, t - cand.since >= settle else { return nil }

        guard var r = ref, let ci = current else { return accept(sig, cand.since, mask) }   // the first steady picture
        // a camera, a person beside the slide: what changed there while it moved is part of the picture now — but not
        // when a big part was moving (a video filling the window may have been replaced by the next slide meanwhile)
        let hidden = Signature.tiles - usable
        if hidden > 0, Double(hidden) < 0.5 * Double(Signature.tiles) { r = r.merged(with: sig, tiles: mask.map { !$0 }) }
        ref = r
        let d = FrameDiff(r, sig, trusted: mask)
        let box = bounds(d)
        let blobs = d.total < 2500 ? FrameDiff.blobs(r, sig, trusted: mask) : []
        func why(_ reason: String) {
            let line = String(format: "t=%.1f tiles=%d added=%d removed=%d altered=%d faded=%d box=%@ → %@", t, d.tiles, d.added, d.removed,
                              d.altered, d.faded, box.map { "r\($0.r0)-\($0.r1) c\($0.c0)-\($0.c1)" } ?? "-", reason)
            trace?(line)
        }
        func absorb(_ reason: String) -> Event? {                         // not a slide change: it is part of the picture now
            var touched = d.changed                                       // every tile the change touched, faint edges too
            for b in blobs { for k in b.pixels { touched[(k / Signature.w / Signature.th) * Signature.cols + (k % Signature.w) / Signature.tw] = true } }
            ref = r.merged(with: sig, tiles: touched)
            candidate = nil
            why(reason)
            return nil
        }
        // the same picture — unless a few coherent marks changed (one word in small text is only a handful of pixels,
        // but several glyphs; noise makes no such patches)
        if d.total < 8 && d.tiles <= 1 && blobs.count < 3 {
            candidate = nil
            return nil
        }
        if SlideDetector.movedObject(blobs, d) { return absorb("a pointer moved") }
        if SlideDetector.pointerOnly(blobs, d, moved: t - pointerSeen > 30) { return absorb("a pointer came, went or moved") }
        // captions (a band whose text is replaced) or a chat (a narrow column at the side) changing again within seconds
        let spot = box.map { (SlideDetector.band($0) && !d.grew) || SlideDetector.sideColumn($0) } ?? false
        if spot, let b = box {
            if spots.contains(where: { t - $0.t < 8 && $0.since != cand.since && SlideDetector.sameSpot($0.box, b) }) {
                spots.append((b, t, cand.since))
                return absorb("changes again in the same place")
            }
            if !spots.contains(where: { $0.since == cand.since }) { spots.append((b, t, cand.since)) }
        }
        // ink taken away somewhere while ink was added: something was replaced (a number, a word) — an edit, not a build
        let replaced = blobs.contains { $0.removed >= 3 } && blobs.contains { $0.added >= 3 }
        if d.grew, !replaced, d.added >= 20 || blobs.count >= 2 {        // built up: the page keeps the fuller picture
            slides[ci] = sig
            ref = sig
            candidate = nil
            why("update")
            return .update(ci)
        }
        if d.shrank, !replaced, d.removed >= 30 { candidate = nil; why("an earlier step"); return nil }   // stepped back: the fuller one stays
        if cameraOnly(d) { return absorb("camera") }                     // the lecturer's camera: someone else, or moved
        guard let b = box else { candidate = nil; return nil }
        if subtitles(b) { subtitlesSeen = t; return absorb("subtitles") }
        if d.total < 150 {                                                // small: a clock or counter — or a real edit
            let changed = (0..<Signature.tiles).filter { d.changed[$0] }
            let ticking = changed.contains { i in ticks[i].filter { t - $0 < 6 }.count >= 2 }    // changed twice within seconds
            if clockPlace(b) || ticking { return absorb("clock") }
        }
        // only a band or a column changed, away from the title: wait a while before calling it a slide — a player's
        // controls, a notification or a chat line come and go again (a real slide change is still dated to when it came)
        if spot, let b = box, !(b.r0 <= 2 && b.c0 < Signature.cols * 2 / 3), t - cand.since < 5.5 { return nil }
        spots.removeAll { t - $0.t > 30 }
        why("accept")
        return accept(sig, cand.since, mask)                              // the content really changed: another slide
    }

    private struct Box { let r0: Int, r1: Int, c0: Int, c1: Int }

    /// The 4-connected patches of changed tiles.
    private static func patches(_ changed: [Bool]) -> [[Int]] {
        var seen = [Bool](repeating: false, count: Signature.tiles), out: [[Int]] = []
        for start in 0..<Signature.tiles where changed[start] && !seen[start] {
            var stack = [start], tiles: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                tiles.append(i)
                let r = i / Signature.cols, c = i % Signature.cols
                for (rr, cc) in [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)]
                where rr >= 0 && rr < Signature.rows && cc >= 0 && cc < Signature.cols {
                    let j = rr * Signature.cols + cc
                    if changed[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
            out.append(tiles)
        }
        return out
    }

    /// Ignore what moved until it has been still for `hold` seconds, with a tile's margin (a person gesturing reaches
    /// a little further).
    private func learnMoving(_ t: Double, _ tiles: Set<Int>) {
        for i in tiles {
            let r = i / Signature.cols, c = i % Signature.cols
            for rr in max(0, r - 1)...min(Signature.rows - 1, r + 1) {
                for cc in max(0, c - 1)...min(Signature.cols - 1, c + 1) { movedAt[rr * Signature.cols + cc] = t }
            }
        }
    }

    /// Did the picture (its largest changed part) move up or down as a whole — a page or a document scrolling? The
    /// earlier frame, shifted by up to 60 of its 180 rows, then matches far better than unshifted.
    static func scrolled(_ a: Signature, _ b: Signature, _ changed: [Bool]) -> Bool {
        guard let main = patches(changed).max(by: { $0.count < $1.count }), main.count >= 4 else { return false }
        let cols = main.map { $0 % Signature.cols }, rows = main.map { $0 / Signature.cols }
        let x0 = cols.min()! * Signature.tw, x1 = (cols.max()! + 1) * Signature.tw
        let y0 = rows.min()! * Signature.th, y1 = (rows.max()! + 1) * Signature.th
        func agree(_ dy: Int) -> Double {
            let lo = max(y0, -dy), hi = min(y1, Signature.h - dy)
            guard lo < hi else { return 0 }
            var ok = 0, n = 0
            for y in lo..<hi {
                let row = y * Signature.w, from = (y + dy) * Signature.w
                for x in stride(from: x0, to: x1, by: 2) { if abs(Int(b.px[row + x]) - Int(a.px[from + x])) <= 10 { ok += 1 }; n += 1 }
            }
            return n > 0 ? Double(ok) / Double(n) : 0
        }
        let base = agree(0)
        guard base < 0.97 else { return false }
        var best = 0.0
        for dy in -60...60 where dy != 0 { best = max(best, agree(dy)) }
        return best >= 0.85 && (1 - best) <= 0.35 * (1 - base)
    }

    /// Was this motion a transition from one picture to another — every frame in between a blend of the two (a fade),
    /// or passing through a blank frame (a fade through black)? A camera, a video or a person wanders instead: somewhere
    /// they change what is the same before and after.
    static func transition(from a: Signature, through frames: [Signature], to b: Signature) -> Bool {
        if frames.contains(where: { $0.contrast <= 8 }) { return true }
        var idx: [Int] = [], same: [Int] = [], span = 0.0
        for k in 0..<a.px.count {
            let d = abs(Int(a.px[k]) - Int(b.px[k]))
            if d > 20 { idx.append(k); span += Double(d) } else if d <= 6 { same.append(k) }
        }
        guard idx.count >= 50 else { return false }                       // it came back to where it was: a gesture, not a transition
        span /= Double(idx.count)
        for f in frames.dropLast() {
            var excess = 0
            for k in idx {
                let x = Int(f.px[k]), p = Int(a.px[k]), q = Int(b.px[k])
                excess += abs(x - p) + abs(x - q) - abs(p - q)
            }
            if Double(excess) / Double(idx.count) > 0.25 * span + 4 { return false }
            let strayed = same.reduce(0) { $0 + (abs(Int(f.px[$1]) - Int(a.px[$1])) > 30 ? 1 : 0) }
            if strayed > max(30, same.count / 2000) { return false }
        }
        return true
    }

    /// A pointer (cursor, highlight ring, laser, annotation arrow) that moved: what disappeared in one place appeared,
    /// with the same shape, in another — nothing else changed.
    static func movedObject(_ blobs: [FrameDiff.Blob], _ d: FrameDiff) -> Bool {
        guard blobs.count >= 2, blobs.count < 120 else { return false }
        let gone = blobs.filter { $0.removed * 10 >= $0.size * 6 }, came = blobs.filter { $0.removed * 10 < $0.size * 3 }
        guard !gone.isEmpty, !came.isEmpty, gone.count + came.count >= blobs.count - 1 else { return false }
        func extent(_ bs: [FrameDiff.Blob]) -> (x0: Int, x1: Int, y0: Int, y1: Int, size: Int) {
            (bs.map(\.x0).min()!, bs.map(\.x1).max()!, bs.map(\.y0).min()!, bs.map(\.y1).max()!, bs.reduce(0) { $0 + $1.size })
        }
        let g = extent(gone), c = extent(came)
        guard g.size >= 6, g.size <= 2500, Double(c.size) / Double(g.size) > 0.5, Double(c.size) / Double(g.size) < 2 else { return false }
        let gw = g.x1 - g.x0 + 1, gh = g.y1 - g.y0 + 1, cw = c.x1 - c.x0 + 1, ch = c.y1 - c.y0 + 1
        guard abs(gw - cw) <= max(3, max(gw, cw) / 3), abs(gh - ch) <= max(3, max(gh, ch) / 3) else { return false }
        let apart = g.x1 < c.x0 || c.x1 < g.x0 || g.y1 < c.y0 || c.y1 < g.y0
        guard apart else { return false }                                // in the same place: replaced, not moved
        // the same shape: overlay the two, each from its own corner
        let gp = Set(gone.flatMap(\.pixels).map { ($0 % Signature.w - g.x0) * 1000 + ($0 / Signature.w - g.y0) })
        let cp = Set(came.flatMap(\.pixels).map { ($0 % Signature.w - c.x0) * 1000 + ($0 / Signature.w - c.y0) })
        let common = gp.intersection(cp).count
        let alike = abs(g.size - c.size) * 4 <= max(g.size, c.size) && abs(gw - cw) * 4 <= max(gw, cw) + 4 && abs(gh - ch) * 4 <= max(gh, ch) + 4
        return Double(common) / Double(max(1, gp.union(cp).count)) >= (alike ? 0.15 : 0.35)
    }

    private func bounds(_ d: FrameDiff) -> Box? {
        let on = (0..<Signature.tiles).filter { d.changed[$0] }
        guard !on.isEmpty else { return nil }
        let rows = on.map { $0 / Signature.cols }, cols = on.map { $0 % Signature.cols }
        return Box(r0: rows.min()!, r1: rows.max()!, c0: cols.min()!, c1: cols.max()!)
    }

    /// A band one or two lines high (captions).
    private static func band(_ b: Box) -> Bool { b.r1 - b.r0 + 1 <= 2 }

    /// A narrow column in the right third (a chat panel).
    private static func sideColumn(_ b: Box) -> Bool { b.c1 - b.c0 + 1 <= 5 && b.c0 >= Signature.cols * 2 / 3 }

    /// Only a small mark vanished somewhere and/or appeared somewhere else, each compact and square or upright (not a
    /// wide word): a cursor, a laser dot, a highlight ring — even where the new spot shows it only faintly.
    /// `moved`: it must have moved (vanished in one place, appeared in another) — a mark that only appears is taken for a
    /// pointer only while one has been seen moving recently (otherwise it may be a changed digit or a quiz answer).
    static func pointerOnly(_ blobs: [FrameDiff.Blob], _ d: FrameDiff, moved: Bool = false) -> Bool {
        guard !blobs.isEmpty, blobs.count < 120, d.total < 500, d.tiles <= 8 else { return false }
        let gone = blobs.filter { $0.removed * 10 >= $0.size * 6 }, came = blobs.filter { $0.removed * 10 < $0.size * 6 }
        func compact(_ bs: [FrameDiff.Blob]) -> Bool {
            guard !bs.isEmpty else { return true }
            let w = bs.map(\.x1).max()! - bs.map(\.x0).min()! + 1, h = bs.map(\.y1).max()! - bs.map(\.y0).min()! + 1
            return w <= 32 && h <= 32 && h >= 3 && Double(w) <= 1.5 * Double(h)
        }
        guard compact(gone), compact(came) else { return false }
        guard !gone.isEmpty, !came.isEmpty else { return !moved }
        // both: it must have moved somewhere else — in the same place it was replaced (a "?" turning into "③")
        let gx0 = gone.map(\.x0).min()!, gx1 = gone.map(\.x1).max()!, gy0 = gone.map(\.y0).min()!, gy1 = gone.map(\.y1).max()!
        let cx0 = came.map(\.x0).min()!, cx1 = came.map(\.x1).max()!, cy0 = came.map(\.y0).min()!, cy1 = came.map(\.y1).max()!
        return gx1 + 8 < cx0 || cx1 + 8 < gx0 || gy1 + 8 < cy0 || cy1 + 8 < gy0
    }

    /// The same place again: for a chat, the same column (new messages land lower down); for captions, the same band.
    private static func sameSpot(_ a: Box, _ b: Box) -> Bool {
        if sideColumn(a) && sideColumn(b) {
            let w = min(a.c1, b.c1) - max(a.c0, b.c0) + 1
            return Double(w) >= 0.5 * Double(min(a.c1 - a.c0 + 1, b.c1 - b.c0 + 1))
        }
        return overlap(a, b) >= 0.5
    }

    /// How much two boxes overlap, as a share of the smaller one.
    private static func overlap(_ a: Box, _ b: Box) -> Double {
        let h = min(a.r1, b.r1) - max(a.r0, b.r0) + 1, w = min(a.c1, b.c1) - max(a.c0, b.c0) + 1
        guard h > 0, w > 0 else { return 0 }
        let smaller = min((a.r1 - a.r0 + 1) * (a.c1 - a.c0 + 1), (b.r1 - b.r0 + 1) * (b.c1 - b.c0 + 1))
        return Double(h * w) / Double(smaller)
    }

    /// Only the lecturer's camera changed (someone else in it, or it moved to another corner): every patch of changed
    /// tiles is a compact box in a corner (a camera, or a person standing beside the slide) — not the top-left, where
    /// titles and logos live — mostly changed, at most 12% of the picture each.
    private func cameraOnly(_ d: FrameDiff) -> Bool {
        let found = SlideDetector.patches(d.changed)
        return !found.isEmpty && found.allSatisfy(cameraPatch)
    }

    private func cameraPatch(_ tiles: [Int]) -> Bool {
        let rows = tiles.map { $0 / Signature.cols }, cols = tiles.map { $0 % Signature.cols }
        let b = Box(r0: rows.min()!, r1: rows.max()!, c0: cols.min()!, c1: cols.max()!)
        let w = b.c1 - b.c0 + 1, h = b.r1 - b.r0 + 1
        // within a tile of the edges: an inset camera has a margin, and the person moving in it may not reach its border
        let top = b.r0 <= 1, bottom = b.r1 >= Signature.rows - 2, left = b.c0 <= 1, right = b.c1 >= Signature.cols - 2
        let aspect = Double(w) / Double(h)
        return (top || bottom) && (left || right) && !(top && left) && Double(w * h) / Double(Signature.tiles) <= 0.12 &&
            aspect >= 0.5 && aspect <= 2.4 && Double(tiles.count) >= 0.5 * Double(w * h)
    }

    /// Subtitles at the bottom of the picture, across the middle. (Captions elsewhere — inside a player in a browser
    /// window — are recognised by changing again and again in the same band.)
    private func subtitles(_ b: Box) -> Bool {
        b.r0 >= Signature.rows - 2 && b.c0 <= Signature.cols / 2 && b.c1 >= Signature.cols / 2 - 1
    }

    /// Where a clock, a timer or a page number sits: the top-right corner, the bottom row, the bottom-right corner.
    private func clockPlace(_ b: Box) -> Bool {
        (b.r1 <= 1 && b.c0 >= Signature.cols - 4) || b.r0 >= Signature.rows - 1 || (b.r0 >= Signature.rows - 2 && b.c0 >= Signature.cols - 4)
    }

    private func accept(_ sig: Signature, _ settled: Double, _ mask: [Bool]) -> Event {
        candidate = nil
        let since = shownSince(sig, settled, mask)
        // back to an earlier slide: the same picture, or an earlier step of it — give or take what changes on its own
        // (the camera, a cursor or laser resting elsewhere, a ticking timer, subtitles)
        var m = mask
        for i in 0..<Signature.tiles where ticks[i].count >= 2 {          // a timer: ticks seconds apart, lately
            let k = ticks[i]
            if now - k[k.count - 1] < 60, k[k.count - 1] - k[k.count - 2] < 6 { m[i] = false }
        }
        if now - subtitlesSeen < 60 {
            for r in (Signature.rows - 2)..<Signature.rows { for c in 0..<Signature.cols { m[r * Signature.cols + c] = false } }
        }
        var best: (i: Int, total: Int)?
        for (i, s) in slides.enumerated() {                              // (the current one too: a camera back where it was)
            let d = FrameDiff(s, sig, trusted: m)
            let blobs = d.total < 2500 ? FrameDiff.blobs(s, sig, trusted: m) : []
            let same = (d.total < 8 && d.tiles <= 1 && blobs.count < 3) || cameraOnly(d) || incidentalOnly(d, blobs)
            let earlierStep = d.shrank && d.removed >= 30                 // a whole bullet or more missing, nothing new
            if same || earlierStep, best == nil || d.total < best!.total { best = (i, d.total) }
        }
        if let b = best {
            current = b.i
            ref = slides[b.i]
            return .again(b.i, since)
        }
        slides.append(sig)
        current = slides.count - 1
        ref = sig
        return .new(slides.count - 1, since)
    }

    /// When the new picture really came: the earliest of the latest frames that already show it, give or take a cursor
    /// still moving about — which delays the decision, not the moment the slide changed.
    private func shownSince(_ sig: Signature, _ settled: Double, _ mask: [Bool]) -> Double {
        guard let old = ref else { return settled }
        var since = settled
        for f in recent.reversed() {
            if f.t >= settled { continue }
            let toNew = FrameDiff(f.sig, sig, trusted: mask)
            let identical = toNew.total == 0 && toNew.tiles == 0 && toNew.meanAbs < 0.1
            if !identical {                                               // otherwise only a pointer elsewhere, in a calm frame
                guard toNew.meanAbs <= max(1.2, noise * 2.2), toNew.total >= 8 || toNew.tiles > 1 else { break }
                let marks = toNew.total < 500 ? FrameDiff.blobs(f.sig, sig, trusted: mask) : []
                guard !marks.isEmpty, SlideDetector.pointerOnly(marks, toNew) || SlideDetector.movedObject(marks, toNew) else { break }
            }
            guard FrameDiff(f.sig, old, trusted: mask).total > max(40, toNew.total * 4) else { break }   // not the slide before
            since = f.t
        }
        return since
    }

    /// Every difference is something that changes on its own: inside a camera in a corner, or a pointer resting elsewhere
    /// (while a pointer has been about) — at most two compact groups of marks, one where it was and one where it is,
    /// each only vanished or only appeared. Never lines of text, never something replaced in place (a revised digit).
    private func incidentalOnly(_ d: FrameDiff, _ blobs: [FrameDiff.Blob]) -> Bool {
        guard !blobs.isEmpty, blobs.count < 120 else { return false }
        let cam = Set(SlideDetector.patches(d.changed).filter(cameraPatch).flatMap { $0 })
        var groups: [(x0: Int, x1: Int, y0: Int, y1: Int, came: Bool)] = []
        for b in blobs {
            let tiles = Set(b.pixels.map { ($0 / Signature.w / Signature.th) * Signature.cols + ($0 % Signature.w) / Signature.tw })
            if tiles.isSubset(of: cam) { continue }
            let came = b.removed * 10 < b.size * 3, gone = b.removed * 10 >= b.size * 6
            guard now - pointerSeen < 120, came || gone else { return false }
            if let k = groups.firstIndex(where: { $0.came == came && $0.x0 - 4 <= b.x1 && b.x0 <= $0.x1 + 4 && $0.y0 - 4 <= b.y1 && b.y0 <= $0.y1 + 4 }) {
                let g = groups[k]
                groups[k] = (min(g.x0, b.x0), max(g.x1, b.x1), min(g.y0, b.y0), max(g.y1, b.y1), came)
            } else { groups.append((b.x0, b.x1, b.y0, b.y1, came)) }
            guard groups.count <= 2 else { return false }
        }
        guard groups.allSatisfy({ $0.x1 - $0.x0 < 32 && $0.y1 - $0.y0 < 32 }) else { return false }
        if groups.count == 2, groups[0].came != groups[1].came {          // vanished where something appeared: replaced
            let a = groups[0], b = groups[1]
            if a.x0 <= b.x1 + 2 && b.x0 <= a.x1 + 2 && a.y0 <= b.y1 + 2 && b.y0 <= a.y1 + 2 { return false }
        }
        return true
    }
}

// MARK: - Collecting a session's slides

/// One session's slides: runs the detector, keeps each slide as a JPEG in the app's own folder as soon
/// as it's found (so a crash loses nothing), and remembers which slide was on screen when.
final class SlideCollector: @unchecked Sendable {
    let dir: URL
    var onCount: (@Sendable (Int) -> Void)?
    /// About once a second: the frame as a JPEG (base64), the lecturer's camera if one was found, and the part 깔끔하게
    /// 담기 keeps once it is clear (both 0–1, top-left).
    var onPreview: (@Sendable (String, CGRect?, CGRect?) -> Void)?
    private var lastPreview = Date.distantPast
    private let detector: SlideDetector
    private let queue = DispatchQueue(label: "lecture.slides", qos: .utility)
    /// Each slide's text is read as it is kept (titles for the PDF), on a queue of its own: the first reading loads
    /// Apple's text recognition, which can take half a minute — during the lecture, not when it is saved.
    private let reader = DispatchQueue(label: "lecture.slides.titles", qos: .background)
    private let readLock = NSLock()
    private var read: [Int: [SlideTitles.Found]] = [:]
    private var timeline: [(slide: Int, from: Double, sound: Double?)] = []
    /// Live: each frame's time on the session's clock (what the detector runs on — it must move even when no sound comes
    /// in) and on the sound's clock (what the transcript and the PDF use); `heard`: some sound came in at all.
    private var clock: [(t: Double, sound: Double)] = []
    private var heard = false
    private var count = 0
    private var closed = false
    /// Each kept slide in small, its size, where the camera was and what was moving then: 깔끔하게 담기 works out the
    /// slide's part from these — live for the preview, and again from the saved files for the PDF.
    private struct Kept { let sig: Signature; let width: Int, height: Int; let camera: CGRect?; let moving: [Bool] }
    private var kept: [Int: Kept] = [:]
    private var clean: CGRect?

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LectureScribe/Slides")
    }

    /// `transcript`: the session's .txt, so a crash-left folder can still become a PDF later.
    init(settle: Double, transcript: URL) throws {
        detector = SlideDetector(settle: settle)
        dir = SlideCollector.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(transcript.path.utf8).write(to: dir.appendingPathComponent("transcript.path"))
    }

    /// Any thread; frames are handled in order on the collector's own queue. `t`: the session's time (files: the video's);
    /// `sound`: live, the sound's time then — a slide is dated by it in the PDF, like the transcript; with no sound at all
    /// (a lecture video without sound), by the session's time.
    func add(_ image: CGImage, at t: Double, sound: Double? = nil) {
        queue.async { [self] in
            guard !closed, let sig = Signature(image) else { return }
            if let sound {
                clock.append((t, sound))
                if sound > 0 { heard = true }
                if clock.count > 4000 { clock.removeFirst(1000) }          // the last half hour at 2 fps
            }
            let ev = detector.step(t, sig)
            if let ev {
                switch ev {
                case .new(let i, let since):
                    save(image, i, sig)
                    timeline.append((i, since, soundTime(since)))
                    count += 1
                    onCount?(count)
                case .again(let i, let since):
                    if timeline.last?.slide != i { timeline.append((i, since, soundTime(since))) }
                case .update(let i):
                    save(image, i, sig)
                }
                writeTimeline()
            }
            if let preview = onPreview, Date().timeIntervalSince(lastPreview) >= 1, let jpeg = SlideCollector.previewJPEG(image) {
                lastPreview = Date()
                preview(jpeg, detector.cameraRect, clean)
            }
            writeTimeline()
        }
    }

    /// A JPEG of a frame, base64 (about 60 KB): what the live preview shows — big enough for its large view.
    static func previewJPEG(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled(image, max: 960), [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }

    private func save(_ image: CGImage, _ i: Int, _ sig: Signature) {
        let url = dir.appendingPathComponent(String(format: "%04d.jpg", i + 1))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        let stored = scaled(image, max: 1920)
        CGImageDestinationAddImage(dest, stored, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
        kept[i] = Kept(sig: sig, width: stored.width, height: stored.height, camera: detector.cameraRect, moving: detector.moving)
        writeKept()
        // the slide's part as it looks now, for pictures of this size (a resized window starts again)
        let same = kept.keys.sorted().compactMap { kept[$0] }.filter { $0.width == stored.width && $0.height == stored.height }
        clean = CleanCapture.area(same.map(\.sig), cameras: same.compactMap(\.camera), moving: same.map(\.moving), image: stored)
        reader.async { [weak self] in                                    // a fuller picture later reads again
            let lines = SlideTitles.lines(image)
            guard let self else { return }
            self.readLock.lock(); self.read[i] = lines; self.readLock.unlock()
        }
    }

    /// The sound's time at a time on the session's clock (the frame then, or the first one).
    private func soundTime(_ t: Double) -> Double? {
        guard !clock.isEmpty else { return nil }
        return (clock.last { $0.t <= t } ?? clock[0]).sound
    }

    private func writeTimeline() {
        let rows = timeline.map { "\($0.slide)\t\(heard ? ($0.sound ?? $0.from) : $0.from)" }.joined(separator: "\n")
        try? Data(rows.utf8).write(to: dir.appendingPathComponent("timeline.tsv"), options: .atomic)
    }

    /// kept.tsv: slide, the camera (x,y,w,h or -) and the moving tiles (0/1 × 144) when it was kept.
    private func writeKept() {
        let rows = kept.keys.sorted().map { i -> String in
            let k = kept[i]!
            let cam = k.camera.map { String(format: "%.4f,%.4f,%.4f,%.4f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-"
            return "\(i)\t\(cam)\t" + String(k.moving.map { $0 ? "1" : "0" })
        }
        try? Data(rows.joined(separator: "\n").utf8).write(to: dir.appendingPathComponent("kept.tsv"), options: .atomic)
    }

    /// Slides turned off mid-session: stop and throw away what was collected (a PDF being written is not kept).
    func discard() {
        queue.sync { closed = true; discarded = true }
        try? FileManager.default.removeItem(at: dir)
    }
    private var discarded = false
    private var isDiscarded: Bool { queue.sync { discarded } }

    /// Stops taking frames and waits for the last ones. Returns how many slides were found.
    func close() -> Int {
        queue.sync { closed = true; return count }
    }

    /// Writes "<name>.pdf" next to the transcript; then the working folder goes. Returns the slide count.
    @discardableResult
    func makePDF(transcript: URL, lines: [(Double, Double, String)], end: Double, layout: String, clean: Bool = false) -> Int {
        let n = close()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard n > 0 else { return 0 }
        reader.sync {}                                                    // the last readings
        readLock.lock(); let known = read; readLock.unlock()
        return SlidesPDF.build(from: dir, transcript: transcript, lines: lines, end: end, layout: layout, clean: clean, known: known,
                               cancelled: { [weak self] in self?.isDiscarded ?? false })
    }
}

private func scaled(_ image: CGImage, max side: Int) -> CGImage {
    let w = image.width, h = image.height
    guard Swift.max(w, h) > side else { return image }
    let k = Double(side) / Double(Swift.max(w, h))
    let nw = Int(Double(w) * k), nh = Int(Double(h) * k)
    guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    return ctx.makeImage() ?? image
}

// MARK: - Slides from a video file

enum VideoSlides {
    /// Does the file have a picture at all?
    static func hasVideo(_ url: URL) async -> Bool {
        ((try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []).isEmpty == false
    }

    /// Does it have sound? (A lecture video without sound gets its slides only.)
    static func hasAudio(_ url: URL) async -> Bool {
        ((try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
    }

    static func duration(_ url: URL) async -> Double {
        let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return d.isFinite ? d : 0
    }

    /// Reads one frame per second into the collector, up to `until()` seconds (중지 part-way: as far as it was transcribed).
    /// `progress` gets 0…1.
    static func extract(_ url: URL, into collector: SlideCollector, until: @escaping @Sendable () -> Double = { .infinity },
                        progress: @escaping @Sendable (Double) -> Void) async {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let times = stride(from: 0.5, to: duration, by: 1.0).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var done = 0
        for await result in gen.images(for: times) {
            if Task.isCancelled { break }
            done += 1
            if case .success(_, let image, let actual) = result {
                if actual.seconds > until() { break }
                collector.add(image, at: actual.seconds)
            }
            if done % 10 == 0 { progress(Double(done) / Double(times.count)) }
        }
        progress(1)
    }
}

// MARK: - The PDF

/// A4 pages: a cover, then for each slide its picture, when it was shown, and the sentences said
/// while it was on screen (sentences before the first slide go with the first one).
enum SlidesPDF {
    private static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 50
    private static let ink = CGColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1)
    private static let muted = CGColor(srgbRed: 0.45, green: 0.47, blue: 0.53, alpha: 1)
    private static let accent = CGColor(srgbRed: 0.62, green: 0.49, blue: 0.24, alpha: 1)
    private static let hairline = CGColor(srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 1)

    /// The UI's Pretendard, so the PDF looks like the app (falls back to the system font).
    private static let fontsReady: Bool = {
        let dirs = [env["LECTURE_DEV_DIR"].map { $0 + "/ui/fonts" }, Bundle.main.resourcePath.map { $0 + "/ui/fonts" }].compactMap { $0 }
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".otf") {
                CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: d + "/" + f) as CFURL, .process, nil)
            }
        }
        return true
    }()

    /// Pretendard (or the system's Korean font), without contextual alternates: Pretendard swaps % ( ) = − for
    /// alternates next to Hangul, and those glyphs have no Unicode in the PDF — copied or searched text would lose them.
    private static func font(_ size: CGFloat, _ weight: String) -> CTFont {
        _ = fontsReady
        let name = "Pretendard-\(weight)"
        let found = CTFontCreateWithName(name as CFString, size, nil)
        let f = (CTFontCopyPostScriptName(found) as String) == name ? found : CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, size, nil)
        let off: [[CFString: Any]] = ["calt", "case"].map { [kCTFontOpenTypeFeatureTag: $0 as CFString, kCTFontOpenTypeFeatureValue: 0] }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: off] as CFDictionary)
        return CTFontCreateCopyWithAttributes(f, size, nil, desc)
    }

    private static func text(_ s: String, _ f: CTFont, _ color: CGColor, kern: CGFloat = 0, line: CGFloat = 1.0) -> NSAttributedString {
        var spacing = CTFontGetSize(f) * (line - 1)
        let para = withUnsafePointer(to: &spacing) { p in
            let settings = [CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: p)]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        let out = NSMutableAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        ])
        // Pretendard's glyphs for most symbols get no Unicode in a PDF (copy and search would lose them): only what it
        // carries is drawn with it, everything else with the fallback font in the same weight.
        if (CTFontCopyPostScriptName(f) as String).hasPrefix("Pretendard") {
            let weight = (CTFontCopyPostScriptName(f) as String).replacingOccurrences(of: "Pretendard-", with: "")
            let (sys, latin, all) = fallback(weight, CTFontGetSize(f))
            let han = hanFont(s, weight, CTFontGetSize(f))
            let ns = s as NSString
            for i in 0..<ns.length where all ? !hangul(ns.character(at: i)) : !pretendardKeeps(ns.character(at: i)) {
                let c = ns.character(at: i)
                out.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: cjk(c) ? han ?? sys : latin ?? sys,
                                 range: NSRange(location: i, length: 1))
            }
        }
        return out
    }

    /// What draws what Pretendard doesn't carry into a PDF, by the app's language: the system's Korean font (Korean,
    /// English); Chinese and Japanese in their own fonts (the Korean font would draw Korean forms of Han characters);
    /// for the others Helvetica Neue draws everything but Hangul (`all`) — an "é" from another typeface would stand out.
    /// (Chinese and Japanese: their font draws only Han/kana/CJK punctuation; Latin punctuation such as "-" comes from
    /// Helvetica Neue — PingFang's hyphen looks like an en dash.)
    private static func fallback(_ weight: String, _ size: CGFloat) -> (font: CTFont, latin: CTFont?, all: Bool) {
        let w = weight == "ExtraLight" ? 0 : weight == "Light" ? 1 : 2
        let helvetica = ["HelveticaNeue-UltraLight", "HelveticaNeue-Light", "HelveticaNeue"]
        let (names, latin, all): ([String], [String]?, Bool) = switch appLanguage.value {
        case "ko", "en": (["AppleSDGothicNeo-UltraLight", "AppleSDGothicNeo-Light", "AppleSDGothicNeo-" + weight], nil, false)
        case "zh-Hans": (["PingFangSC-Thin", "PingFangSC-Light", "PingFangSC-Regular"], helvetica, false)
        case "zh-Hant": (["PingFangTC-Thin", "PingFangTC-Light", "PingFangTC-Regular"], helvetica, false)
        case "ja": (["HiraginoSans-W2", "HiraginoSans-W3", "HiraginoSans-W4"], helvetica, false)
        default: (helvetica, nil, true)
        }
        return (CTFontCreateWithName(names[w] as CFString, size, nil), latin.map { CTFontCreateWithName($0[w] as CFString, size, nil) }, all)
    }

    /// A transcript's Han characters in the font of the language they're written in, whatever the app's language (the
    /// Korean font draws the Korean forms of them): kana → Japanese; Han without Hangul → Chinese, Traditional or
    /// Simplified by the characters it uses (a tie: the app's). nil: no Han, or Korean with Hanja — the app's fallback.
    private static func hanFont(_ s: String, _ weight: String, _ size: CGFloat) -> CTFont? {
        let u = s.unicodeScalars
        guard u.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }) else { return nil }
        let w = weight == "ExtraLight" ? 0 : weight == "Light" ? 1 : 2
        let names: [String]
        if u.contains(where: { (0x3040...0x30FF).contains($0.value) }) {
            names = ["HiraginoSans-W2", "HiraginoSans-W3", "HiraginoSans-W4"]
        } else if u.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
            return nil
        } else {
            let trad = u.filter { hant.contains($0) }.count, simp = u.filter { hans.contains($0) }.count
            names = trad > simp || (trad == simp && appLanguage.value == "zh-Hant")
                ? ["PingFangTC-Thin", "PingFangTC-Light", "PingFangTC-Regular"] : ["PingFangSC-Thin", "PingFangSC-Light", "PingFangSC-Regular"]
        }
        return CTFontCreateWithName(names[w] as CFString, size, nil)
    }
    /// Common characters written one way in Traditional Chinese and another in Simplified (each list holds its own forms).
    private static let hant = Set("們這個來說時會為學國對開關現樣點後從還過麼裡長問題經實發動機體種東車書語話頭電聽見覺讓給認識歷處應該當與無幾邊進總結構義區傳統環變價錢買賣號飛氣門間網際數據資產業權華優質報導讀詞寫類級".unicodeScalars)
    private static let hans = Set("们这个来说时会为学国对开关现样点从还过么长问题经实发动体种东车书语话头电听见觉让给认识历处应该当与无边进总结构义区传统环变价钱买卖号飞气门间网际数资产业权华优质报导读词写类级".unicodeScalars)

    /// Han, kana, CJK punctuation and full-width forms.
    private static func cjk(_ c: unichar) -> Bool {
        (0x2E80...0x9FFF).contains(c) || (0xF900...0xFAFF).contains(c) || (0xFE30...0xFE4F).contains(c) || (0xFF00...0xFFEF).contains(c)
    }

    private static func hangul(_ c: unichar) -> Bool {
        (0xAC00...0xD7A3).contains(c) || (0x1100...0x11FF).contains(c) || (0x3130...0x318F).contains(c)
    }

    /// What Pretendard carries into a PDF's text layer (checked character by character): Hangul, ASCII letters and
    /// digits, a little punctuation, circled numbers and Roman numerals.
    private static func pretendardKeeps(_ c: unichar) -> Bool {
        switch c {
        case 0x09, 0x0A, 0x20, 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x21, 0x23, 0x2A, 0x2C, 0x2E, 0x2F, 0x3A, 0x3B, 0x3F, 0x5C: return true      // ! # * , . / : ; ? \
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: return true             // Hangul
        case 0x00B7, 0x2022, 0x2026, 0x203B, 0x2460...0x2473, 0x2160...0x216B: return true // · • … ※ ①–⑳ Ⅰ–Ⅻ
        default: return false
        }
    }

    /// At most `max` characters, cut at a space where possible, with "…".
    private static func shortened(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let head = String(s.prefix(max - 1))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return (cut.count >= max / 2 ? cut : head).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `title` in at most `lines` lines of `width`, broken between words (a Korean word is never split in two, unless
    /// it alone is wider than a line) and cut with "…" when it doesn't fit.
    private static func fitted(_ title: String, width: CGFloat, lines maxLines: Int,
                               _ make: (String) -> NSAttributedString) -> NSAttributedString {
        func w(_ s: String) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(make(s) as CFAttributedString), nil, nil, nil))
        }
        let room = width - 1
        var words = title.split(separator: " ").map(String.init), lines: [String] = [], cur = "", i = 0
        while i < words.count, lines.count < maxLines {
            let next = cur.isEmpty ? words[i] : cur + " " + words[i]
            if w(next) <= room { cur = next; i += 1; continue }
            if cur.isEmpty {                                          // one word wider than a line: split it
                var head = ""
                for ch in words[i] { if w(head + String(ch)) > room { break }; head.append(ch) }
                if head.isEmpty { head = String(words[i].prefix(1)) }
                lines.append(head)
                words[i] = String(words[i].dropFirst(head.count))
            } else { lines.append(cur); cur = "" }
        }
        if !cur.isEmpty, lines.count < maxLines { lines.append(cur); cur = "" }
        if i < words.count || !cur.isEmpty, var last = lines.last {   // more left: end the last line with "…"
            while w(last + "…") > room, let sp = last.lastIndex(of: " ") { last = String(last[..<sp]) }
            while w(last + "…") > room, last.count > 1 { last.removeLast() }
            lines[lines.count - 1] = last.trimmingCharacters(in: .whitespaces) + "…"
        }
        return make(lines.joined(separator: "\n"))
    }

    private static func flow(_ ctx: CGContext, _ s: NSAttributedString, from start: Int, in rect: CGRect) -> Int {
        let setter = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        let seen = CTFrameGetVisibleStringRange(frame)
        return seen.location + seen.length
    }

    private static func line(_ ctx: CGContext, _ s: NSAttributedString, at p: CGPoint, alignRight: Bool = false) {
        let l = CTLineCreateWithAttributedString(s as CFAttributedString)
        let w = CTLineGetTypographicBounds(l, nil, nil, nil)
        ctx.textPosition = CGPoint(x: alignRight ? p.x - w : p.x, y: p.y)
        CTLineDraw(l, ctx)
    }

    private static func footer(_ ctx: CGContext, _ title: String, _ n: Int, in box: CGRect = page, margin m: CGFloat = margin) {
        let f = font(7.5, "Light")
        let full = CTLineCreateWithAttributedString(text("\(L("Arc 강의 받아쓰기", "Arc Lecture Transcriber")) · \(title)", f, muted, kern: 0.3) as CFAttributedString)
        let room = Double(box.width - m * 2 - 40)                            // a long title stops short of the page number
        let l = CTLineGetTypographicBounds(full, nil, nil, nil) <= room ? full
            : CTLineCreateTruncatedLine(full, room, .end, CTLineCreateWithAttributedString(text("…", f, muted) as CFAttributedString)) ?? full
        ctx.textPosition = CGPoint(x: m, y: 30)
        CTLineDraw(l, ctx)
        line(ctx, text("\(n)", f, muted), at: CGPoint(x: box.width - m, y: 30), alignRight: true)
    }

    /// Splits each line into sentences, each with an estimated start (by its position in the line):
    /// the recognizer often returns several sentences as one line, spanning a slide change.
    static func sentences(_ lines: [(Double, Double, String)]) -> [(Double, String)] {
        var out: [(Double, String)] = []
        for (k, l) in lines.enumerated() {
            let stop = l.1 > l.0 ? l.1 : (k + 1 < lines.count ? max(lines[k + 1].0, l.0) : l.0 + 1)
            let parts = l.2.replacingOccurrences(of: #"([.?!。])\s+"#, with: "$1\n", options: .regularExpression)
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let total = max(1, parts.reduce(0) { $0 + $1.count })
            let next = k + 1 < lines.count ? max(l.0, lines[k + 1].0) : Double.infinity    // times never run backwards
            var at = 0
            for p in parts {
                out.append((min(l.0 + (stop - l.0) * Double(at) / Double(total), next), p))
                at += p.count
            }
        }
        return out
    }

    /// One session's slides, ready to be laid out: each slide's picture, when it first showed, what was said while it was
    /// up, and its name ("슬라이드 3 · 수요와 공급" — the title read off the slide, when there is one).
    struct Deck {
        struct Slide { let image: CGImage; let shown: Double?; let lines: [(Double, String)]; let name: String; var text: [SlideText.Line] = [] }
        let title: String, header: String, said: Int, end: Double
        let slides: [Slide]
    }

    /// Builds the slide PDF from a collector's folder, in the layout chosen in 설정 (`landscape`: every slide filling a
    /// landscape page with what was said on the next; `split`: a PDF of the slides and a second one of the transcript;
    /// `classic`: A4, a slide and its sentences per page). Returns the number of slides.
    /// `lines`: (start, end, text); end 0 = unknown.
    static func build(from dir: URL, transcript: URL, lines rawLines: [(Double, Double, String)], end: Double,
                      layout: String = "landscape", clean: Bool = false, known: [Int: [SlideTitles.Found]] = [:],
                      cancelled: () -> Bool = { false }) -> Int {
        let lines = sentences(rawLines)
        let fm = FileManager.default
        let images: [(Int, CGImage)] = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
            .compactMap { name in
                guard let n = Int(name.prefix(4)), let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(name) as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return (n - 1, img)
            }
        guard !images.isEmpty else { return 0 }
        // when each slide was on screen
        let rows = (try? String(contentsOf: dir.appendingPathComponent("timeline.tsv"), encoding: .utf8)) ?? ""
        var timeline: [(Int, Double)] = rows.split(separator: "\n").compactMap { r in
            let f = r.split(separator: "\t")
            guard f.count == 2, let i = Int(f[0]), let t = Double(f[1]) else { return nil }
            return (i, t)
        }
        if timeline.isEmpty { timeline = images.map { ($0.0, 0) } }
        // A slide is seen a moment after it appears (frames are sampled), and lecturers start talking as
        // they click: a sentence starting up to a second before a slide is spotted belongs to it.
        let lead = 1.0
        var spans: [Int: [(Double, Double)]] = [:]
        for (k, entry) in timeline.enumerated() {
            let from = k == 0 ? 0 : entry.1 - lead                          // talk before the first slide goes with it
            let to = k + 1 < timeline.count ? timeline[k + 1].1 - lead : max(end, entry.1) + 1
            spans[entry.0, default: []].append((from, to))
        }
        let firstShown = Dictionary(timeline.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        let header = (try? String(contentsOf: transcript, encoding: .utf8))?.components(separatedBy: "\n").first ?? ""
        let name = transcript.deletingPathExtension().lastPathComponent.nfc
        let crops = clean ? cleanAreas(dir, images) : [:]                      // 깔끔하게 담기: each slide cut to its part
        let pictures = images.map { entry in crops[entry.0].flatMap { entry.1.cropping(to: pixels($0, entry.1)) } ?? entry.1 }
        let titles = SlideTitles.read(images.map { known[$0.0] ?? SlideTitles.lines($0.1) },   // read while recording, or now
                                      within: images.map { crops[$0.0] })
        let started = Date()
        let languages = SlideText.languages(for: Settings.load().language)
        let texts = pictures.map { cancelled() ? [] : SlideText.read($0, languages: languages) }   // searchable in the PDF
        log("slides pdf: read the text of \(pictures.count) slides in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        let deck = Deck(title: coverTitle(name: name, header: header, file: transcript), header: header,
                        said: rawLines.filter { !$0.2.isEmpty }.count, end: end,     // as the transcript counts them
                        slides: images.enumerated().map { n, entry in
                            Deck.Slide(image: pictures[n], shown: firstShown[entry.0],
                                       lines: lines.filter { l in (spans[entry.0] ?? []).contains { l.0 >= $0.0 && l.0 < $0.1 } },
                                       name: [L("슬라이드 \(n + 1)", "Slide \(n + 1)"), titles[n]].compactMap { $0 }.joined(separator: " · "),
                                       text: texts[n])
                        })

        let pdfURL = transcript.deletingPathExtension().appendingPathExtension("pdf")
        func part(_ u: URL) -> URL { u.deletingLastPathComponent().appendingPathComponent(".\(u.lastPathComponent).part") }
        var made: [(part: URL, dest: URL, marks: [(String, Int)])] = []
        let ok: Bool
        let quiet = deck.said == 0              // nothing was said at all (a lecture video without sound): the slides alone
        switch layout {
        case "split":
            let text = transcriptPDF(for: transcript)
            if let a = writeLandscape(deck, to: part(pdfURL), withText: false) { made.append((part(pdfURL), pdfURL, a)) }
            if !quiet, let b = writeTranscript(deck, to: part(text)) { made.append((part(text), text, b)) }
            ok = made.count == (quiet ? 1 : 2)
        case "classic":
            if let a = writeClassic(deck, to: part(pdfURL)) { made.append((part(pdfURL), pdfURL, a)) }
            ok = made.count == 1
        default:
            if let a = writeLandscape(deck, to: part(pdfURL), withText: !quiet, cover: true) { made.append((part(pdfURL), pdfURL, a)) }
            ok = made.count == 1
        }
        if !ok || cancelled() {                                             // 슬라이드 PDF was turned off meanwhile
            made.forEach { try? fm.removeItem(at: $0.part) }
            return 0
        }
        for m in made {
            do {
                let dest = unused(m.dest)                                     // never replace a PDF that's already there
                try fm.moveItem(at: m.part, to: dest)
            } catch {
                log("slides pdf: \(error)")
                try? fm.removeItem(at: m.part)
                return 0
            }
        }
        return images.count
    }

    /// 깔끔하게 담기 for the PDF, from the collector's files: pictures of one size share one area (a resized window gets
    /// its own); a picture that shows more than its usual surroundings outside it — a wider slide — keeps everything.
    static func cleanAreas(_ dir: URL, _ images: [(Int, CGImage)]) -> [Int: CGRect] {
        var cams: [Int: CGRect] = [:], moving: [Int: [Bool]] = [:]
        let rows = (try? String(contentsOf: dir.appendingPathComponent("kept.tsv"), encoding: .utf8)) ?? ""
        for r in rows.split(separator: "\n") {
            let f = r.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3, let i = Int(f[0]) else { continue }
            let v = f[1].split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { cams[i] = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
            if f[2].count == Signature.tiles { moving[i] = f[2].map { $0 == "1" } }
        }
        var out: [Int: CGRect] = [:]
        var sizes: [String] = []
        for e in images where !sizes.contains("\(e.1.width)x\(e.1.height)") { sizes.append("\(e.1.width)x\(e.1.height)") }
        for size in sizes {
            let group = images.filter { "\($0.1.width)x\($0.1.height)" == size }
            let sigs = group.compactMap { Signature($0.1) }
            guard sigs.count == group.count, group.count >= 2 else { continue }
            let cameras = group.compactMap { cams[$0.0] }, movings = group.map { moving[$0.0] ?? [] }
            guard let area = CleanCapture.area(sigs, cameras: cameras, moving: movings, image: group.last?.1) else { continue }
            let ref = CleanCapture.reference(sigs)
            let specific = CleanCapture.pageSpecific(sigs, area: area, reference: ref, cameras: cameras, moving: movings)
            var kept = 0
            for (k, e) in group.enumerated() where !specific[k] && !CleanCapture.extends(sigs[k], beyond: area, reference: ref, cameras: cameras, moving: movings[k]) {
                out[e.0] = area; kept += 1
            }
            log(String(format: "slides: clean area %.3f %.3f %.3f %.3f on %d of %d pages (%@)", area.minX, area.minY, area.width, area.height, kept, group.count, size))
        }
        return out
    }

    /// A 0–1 rectangle (top-left origin) in a picture's pixels.
    private static func pixels(_ r: CGRect, _ image: CGImage) -> CGRect {
        CGRect(x: (r.minX * Double(image.width)).rounded(), y: (r.minY * Double(image.height)).rounded(),
               width: (r.width * Double(image.width)).rounded(), height: (r.height * Double(image.height)).rounded())
    }

    /// The transcript's PDF in the `split` layout: "<name> (받아쓰기).pdf" — or "(Transcript)" in English.
    static func transcriptPDF(for transcript: URL) -> URL {
        let name = transcript.deletingPathExtension().lastPathComponent
        return transcript.deletingLastPathComponent().appendingPathComponent("\(name) (\(LF("받아쓰기", "Transcript"))).pdf")
    }

    /// Every name a session's transcript PDF can have (either language), for 기록's rename, delete and share.
    static func transcriptPDFNames(_ id: String) -> [String] { ["\(id) (받아쓰기).pdf", "\(id) (Transcript).pdf"] }

    /// `url`, or "<name> (2).pdf", "(3)"… — the first that is free.
    private static func unused(_ url: URL) -> URL {
        let fm = FileManager.default, base = url.deletingPathExtension().lastPathComponent
        var dest = url, k = 2
        while fm.fileExists(atPath: dest.path) { dest = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(k)).pdf"); k += 1 }
        return dest
    }

    /// The slides' names as the PDF's bookmarks — the sidebar of Preview and other viewers. Written by Core Graphics as
    /// the PDF is made (re-saving it through PDFKit loses the bookmarks and rewrites the slide count 기록 reads).
    private static func setBookmarks(_ ctx: CGContext, _ marks: [(String, Int)]) {
        guard !marks.isEmpty else { return }
        let children: [[CFString: Any]] = marks.map { [kCGPDFOutlineTitle: $0.0 as CFString, kCGPDFOutlineDestination: NSNumber(value: $0.1 + 1)] }
        CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren: children] as CFDictionary)   // (a title on the root: nothing is written)
    }

    private static func context(_ url: URL, _ box: CGRect, _ deck: Deck, keywords: Bool) -> CGContext? {
        var b = box
        var info: [CFString: Any] = [kCGPDFContextTitle: deck.title.replacingOccurrences(of: "\u{00A0}", with: " "),   // searchable
                                     kCGPDFContextCreator: L("Arc 강의 받아쓰기", "Arc Lecture Transcriber")]
        if keywords { info[kCGPDFContextKeywords] = "slides=\(deck.slides.count)" }      // 기록 counts the slides from this
        return CGContext(url as CFURL, mediaBox: &b, info as CFDictionary)
    }

    private static func begin(_ ctx: CGContext, _ box: CGRect) {
        var b = box
        ctx.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &b, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary)
    }

    /// Landscape pages 960 pt wide, as tall as the slide's own shape (kept within sensible bounds).
    private static func wideBox(_ image: CGImage) -> CGRect {
        let h = (960 * CGFloat(image.height) / CGFloat(max(1, image.width))).rounded()
        return CGRect(x: 0, y: 0, width: 960, height: min(960, max(400, h)))
    }

    /// The picture filling the page (centred on black if the page had to be a little wider or taller than it); where it went.
    @discardableResult
    private static func fullBleed(_ ctx: CGContext, _ image: CGImage, _ box: CGRect) -> CGRect {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(box)
        let k = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let w = CGFloat(image.width) * k, h = CGFloat(image.height) * k
        let r = CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)
        return r
    }

    /// A slide's words over its picture in `r`, invisible (PDF text that isn't painted, as in a scanned document's text
    /// layer): the PDF can be searched and the slide's words selected and copied; the picture looks the same. Each line is
    /// stretched to the width Vision measured, its baseline about a fifth of the way up its box.
    private static func invisible(_ ctx: CGContext, _ lines: [SlideText.Line], in r: CGRect) {
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for l in lines {
            let box = CGRect(x: r.minX + l.box.minX * r.width, y: r.minY + l.box.minY * r.height,
                             width: l.box.width * r.width, height: l.box.height * r.height)
            guard box.width >= 2, box.height >= 2 else { continue }
            let line = CTLineCreateWithAttributedString(text(l.text, font(box.height * 0.8, "Regular"), ink))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard w > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
            ctx.scaleBy(x: box.width / w, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// What was said while a slide was up: time, sentence; or a note that nothing was.
    private static func saidText(_ lines: [(Double, String)], size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString(), body = font(size, "Light"), time = font(size - 2, "Regular")
        for (k, l) in lines.enumerated() {
            out.append(text("\(fmtTime(l.0))   ", time, accent, kern: 0.4, line: 1.75))
            out.append(text(l.1 + (k + 1 < lines.count ? "\n" : ""), body, ink, line: 1.75))
        }
        if lines.isEmpty { out.append(text(L("이 슬라이드가 보이는 동안 받아 적은 말이 없습니다.", "Nothing was transcribed while this slide was up."), body, muted, line: 1.75)) }
        return out
    }

    /// `landscape`: a cover, then each slide filling its page with what was said on the page after it.
    /// `withText: false` (the `split` layout's first file, or nothing was said): only the slides — with the cover if `cover`.
    private static func writeLandscape(_ deck: Deck, to url: URL, withText: Bool, cover: Bool? = nil) -> [(String, Int)]? {
        let firstBox = wideBox(deck.slides[0].image)
        guard let ctx = context(url, firstBox, deck, keywords: true) else { return nil }
        var pageNo = 0, marks: [(String, Int)] = []
        if cover ?? withText {                                             // cover: what this is, and the first slide
            begin(ctx, firstBox); pageNo += 1
            let m: CGFloat = 56, colW = firstBox.width * 0.46
            line(ctx, text(L("강 의 노 트", "LECTURE NOTES"), font(10, "Regular"), accent, kern: 2), at: CGPoint(x: m, y: firstBox.height - 96))
            let titleBox = CGRect(x: m, y: firstBox.height - 210, width: colW, height: 96)
            _ = flow(ctx, fitted(deck.title, width: titleBox.width, lines: 2) { text($0, font(26, "Light"), ink, line: 1.3) }, from: 0, in: titleBox)
            _ = flow(ctx, text(summary(deck), font(10.5, "Light"), muted, line: 1.6), from: 0,
                     in: CGRect(x: m, y: firstBox.height - 300, width: colW, height: 80))
            let thumbW = firstBox.width - colW - m * 3, first = deck.slides[0].image
            let th = thumbW * CGFloat(first.height) / CGFloat(first.width)
            let r = CGRect(x: firstBox.width - m - thumbW, y: (firstBox.height - th) / 2, width: thumbW, height: th)
            ctx.saveGState(); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.clip()
            ctx.draw(first, in: r); ctx.restoreGState()
            ctx.setStrokeColor(hairline); ctx.setLineWidth(0.6)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.strokePath()
            footer(ctx, deck.title, pageNo, in: firstBox, margin: m)
            ctx.endPDFPage()
        }
        for s in deck.slides {
            let box = wideBox(s.image)
            begin(ctx, box); pageNo += 1                                    // the slide, the whole page
            marks.append((s.name, pageNo - 1))
            invisible(ctx, s.text, in: fullBleed(ctx, s.image, box))
            ctx.endPDFPage()
            guard withText else { continue }
            let said = saidText(s.lines, size: 11.5), m: CGFloat = 52, gap: CGFloat = 34
            var start = 0, first = true
            repeat {                                                        // then what was said, in two columns
                begin(ctx, box); pageNo += 1
                let top = box.height - 50
                let head = first ? s.name : s.name + L(" (계속)", " (continued)")
                line(ctx, fitted(head, width: box.width - m * 2 - 70, lines: 1) { text($0, font(12.5, "Regular"), accent, kern: 0.6) },
                     at: CGPoint(x: m, y: top))
                if let t = s.shown {
                    line(ctx, text(fmtTime(t), font(9.5, "Light"), muted, kern: 0.6), at: CGPoint(x: box.width - m, y: top), alignRight: true)
                }
                ctx.setStrokeColor(hairline); ctx.setLineWidth(0.6)
                ctx.move(to: CGPoint(x: m, y: top - 14)); ctx.addLine(to: CGPoint(x: box.width - m, y: top - 14)); ctx.strokePath()
                let colW = (box.width - m * 2 - gap) / 2, colH = max(40, top - 34 - 54)
                var next = flow(ctx, said, from: start, in: CGRect(x: m, y: 54, width: colW, height: colH))
                if next < said.length, next > start { next = flow(ctx, said, from: next, in: CGRect(x: m + colW + gap, y: 54, width: colW, height: colH)) }
                footer(ctx, deck.title, pageNo, in: box, margin: m)
                ctx.endPDFPage()
                if next <= start { break }                                 // nothing fitted: don't loop forever
                start = next
                first = false
            } while start < said.length
        }
        setBookmarks(ctx, marks)
        ctx.closePDF()
        return marks
    }

    /// `split`'s second file: the whole transcript on A4, grouped under each slide's name and time.
    private static func writeTranscript(_ deck: Deck, to url: URL) -> [(String, Int)]? {
        guard let ctx = context(url, page, deck, keywords: false) else { return nil }
        let all = NSMutableAttributedString(), headFont = font(11, "Regular"), timeFont = font(9, "Light")
        var heads: [(String, Int)] = []                                    // each slide's name and where it starts in the text
        for (n, s) in deck.slides.enumerated() {
            heads.append((s.name, all.length))
            all.append(text(s.name, headFont, accent, kern: 0.6, line: 1.9))
            if let t = s.shown { all.append(text("   " + fmtTime(t), timeFont, muted, kern: 0.6, line: 1.9)) }
            all.append(text("\n", timeFont, muted, line: 1.2))
            all.append(saidText(s.lines, size: 10.5))
            if n + 1 < deck.slides.count { all.append(text("\n\n", font(10.5, "Light"), ink, line: 1.4)) }
        }
        var pageNo = 0, start = 0, marks: [(String, Int)] = []
        repeat {
            ctx.beginPDFPage(nil); pageNo += 1
            var top = page.height - 56
            if pageNo == 1 {                                                // the title on the first page
                line(ctx, text(L("받 아 쓰 기", "TRANSCRIPT"), font(9.5, "Regular"), accent, kern: 2), at: CGPoint(x: margin, y: top))
                let titleBox = CGRect(x: margin, y: top - 84, width: page.width - margin * 2, height: 70)
                _ = flow(ctx, fitted(deck.title, width: titleBox.width, lines: 2) { text($0, font(20, "Light"), ink, line: 1.3) }, from: 0, in: titleBox)
                _ = flow(ctx, text(summary(deck), font(9.5, "Light"), muted, line: 1.6), from: 0,
                         in: CGRect(x: margin, y: top - 140, width: page.width - margin * 2, height: 50))
                top -= 160
            }
            let next = flow(ctx, all, from: start, in: CGRect(x: margin, y: 54, width: page.width - margin * 2, height: max(40, top - 54)))
            for h in heads where h.1 >= start && h.1 < next { marks.append((h.0, pageNo - 1)) }
            footer(ctx, deck.title, pageNo)
            ctx.endPDFPage()
            if next <= start { break }
            start = next
        } while start < all.length
        setBookmarks(ctx, marks)
        ctx.closePDF()
        return marks
    }

    /// `classic`: A4 — a cover, then a page (or more) per slide: its picture, its name and time, what was said.
    private static func writeClassic(_ deck: Deck, to url: URL) -> [(String, Int)]? {
        guard let ctx = context(url, page, deck, keywords: true) else { return nil }
        var pageNo = 0, marks: [(String, Int)] = []
        ctx.beginPDFPage(nil); pageNo += 1                                   // cover
        line(ctx, text(L("강 의 노 트", "LECTURE NOTES"), font(10, "Regular"), accent, kern: 2), at: CGPoint(x: margin, y: page.height - 150))
        let titleBox = CGRect(x: margin, y: page.height - 260, width: page.width - margin * 2, height: 92)
        _ = flow(ctx, fitted(deck.title, width: titleBox.width, lines: 2) { text($0, font(26, "Light"), ink, line: 1.3) }, from: 0, in: titleBox)
        _ = flow(ctx, text(summary(deck), font(10.5, "Light"), muted, line: 1.6), from: 0,
                 in: CGRect(x: margin, y: page.height - 340, width: page.width - margin * 2, height: 70))
        let first = deck.slides[0].image
        let fw = page.width - margin * 2, fh = min(fw * CGFloat(first.height) / CGFloat(first.width), 300)
        let fr = CGRect(x: margin, y: 120, width: fh * CGFloat(first.width) / CGFloat(first.height), height: fh)
        ctx.saveGState(); ctx.addPath(CGPath(roundedRect: fr, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.clip()
        ctx.draw(first, in: fr); ctx.restoreGState()
        ctx.setStrokeColor(hairline); ctx.setLineWidth(0.6)
        ctx.addPath(CGPath(roundedRect: fr, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.strokePath()
        footer(ctx, deck.title, pageNo)
        ctx.endPDFPage()

        let quiet = deck.said == 0                                           // nothing said at all: the slides alone
        for s in deck.slides {                                               // one page (or more) per slide
            let said = quiet ? NSAttributedString() : saidText(s.lines, size: 10.5)
            var start = 0, isFirst = true
            repeat {
                ctx.beginPDFPage(nil); pageNo += 1
                if isFirst { marks.append((s.name, pageNo - 1)) }
                let top = page.height - 56
                let head = isFirst ? s.name : s.name + L(" (계속)", " (continued)")
                line(ctx, fitted(head, width: page.width - margin * 2 - 60, lines: 1) { text($0, font(10, "Regular"), accent, kern: 1.2) },
                     at: CGPoint(x: margin, y: top))
                if let t = s.shown {
                    line(ctx, text(fmtTime(t), font(9, "Light"), muted, kern: 0.6), at: CGPoint(x: page.width - margin, y: top), alignRight: true)
                }
                var textTop = top - 22
                if isFirst {
                    let image = s.image, w = page.width - margin * 2
                    let h = min(w * CGFloat(image.height) / CGFloat(image.width), 360)
                    let iw = h * CGFloat(image.width) / CGFloat(image.height)
                    let r = CGRect(x: margin + (w - iw) / 2, y: top - 16 - h, width: iw, height: h)
                    ctx.saveGState(); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.clip()
                    ctx.draw(image, in: r); ctx.restoreGState()
                    invisible(ctx, s.text, in: r)
                    ctx.setStrokeColor(hairline); ctx.setLineWidth(0.6)
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.strokePath()
                    textTop = r.minY - 26
                    if !quiet { line(ctx, text(L("이 슬라이드에서 한 말", "Said during this slide"), font(8.5, "Regular"), muted, kern: 0.8), at: CGPoint(x: margin, y: textTop + 2)) }
                    textTop -= 14
                }
                let area = CGRect(x: margin, y: 54, width: page.width - margin * 2, height: max(40, textTop - 54))
                let next = flow(ctx, said, from: start, in: area)
                footer(ctx, deck.title, pageNo)
                ctx.endPDFPage()
                if next <= start { break }                                 // nothing fitted: don't loop forever
                start = next
                isFirst = false
            } while start < said.length
        }
        setBookmarks(ctx, marks)
        ctx.closePDF()
        return marks
    }

    /// "강의 녹취 · …\n슬라이드 12장 · 문장 340개 · 1:12:01" — what the cover says under the title.
    private static func summary(_ deck: Deck) -> String {
        let counts = L("슬라이드 \(deck.slides.count)장 · 문장 \(deck.said)개 · \(fmtTime(deck.end))",
                       "\(nL(deck.slides.count, "slide")) · \(nL(deck.said, "sentence")) · \(fmtTime(deck.end))")
        return deck.header.isEmpty ? counts : coverHeader(deck.header) + "\n" + counts
    }

    /// The transcript's first line as the cover shows it. Files keep Korean or English headers (LF); in any other
    /// language the cover says what it is in that language, without the English weekday:
    /// "Lecture transcript · 2026-10-09 (Fri) 14:30" → "<Lecture transcript in ja> · 2026-10-09 14:30".
    static func coverHeader(_ h: String) -> String {
        guard !["ko", "en"].contains(appLanguage.value) else { return h }
        let rest = { (p: String) in String(h.dropFirst(p.count)).replacingOccurrences(of: #" \([A-Z][a-z]{2}\)"#, with: "", options: .regularExpression) }
        if h.hasPrefix("Lecture transcript · ") { return L("강의 녹취", "Lecture transcript") + " · " + rest("Lecture transcript · ") }
        if h.hasPrefix("File transcription · ") { return L("파일 받아쓰기", "File transcription") + " · " + rest("File transcription · ") }
        return h
    }

    /// "2026년 10월 6일 화요일 오후 2:00 강의" for the app's default names; the name itself otherwise.
    static func coverTitle(name: String, header: String, file: URL) -> String {
        if Library.defaultNameRE.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            let d = Library.date(header: header, file: file), c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: d)
            if !["ko", "en"].contains(appLanguage.value) {                 // other languages: their own date format
                let f = DateFormatter()
                f.locale = Locale(identifier: appLanguage.value)
                f.dateStyle = .full; f.timeStyle = .short
                return L("", "\(f.string(from: d).replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")) Lecture")   // "2026 г.", not "2026г."
            }
            let h = c.hour ?? 0, mm = String(format: "%02d", c.minute ?? 0), h12 = h % 12 == 0 ? 12 : h % 12
            let days = ["일", "월", "화", "수", "목", "금", "토"], daysEN = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            return L("\(c.year!)년 \(c.month!)월 \(c.day!)일 \(days[(c.weekday ?? 1) - 1])요일 \(h < 12 ? "오전" : "오후") \(h12):\(mm) 강의",
                     "\(daysEN[(c.weekday ?? 1) - 1]), \(months[(c.month ?? 1) - 1]) \(c.day!), \(c.year!), \(h12):\(mm)\u{00A0}\(h < 12 ? "AM" : "PM")\u{00A0}Lecture")   // "10:43 PM Lecture" stays on one line
        }
        return name.replacingOccurrences(of: #" (받아쓰기|transcript)( \(\d+\))?$"#, with: "", options: .regularExpression)
    }

    /// How many slides a session's PDF holds (from its keywords), or 0.
    static func count(_ pdf: URL) -> Int {
        guard let doc = CGPDFDocument(pdf as CFURL), let info = doc.info else { return 0 }
        var raw: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Keywords", &raw), let s = raw, let k = CGPDFStringCopyTextString(s) as String?,
              let n = Int(k.replacingOccurrences(of: "slides=", with: "")) else { return 0 }
        return n
    }
}

// MARK: - Slide titles

/// Reads each slide's title off the picture, on this device (Apple's text recognition, Korean and English): the
/// biggest line of text in the upper part of the slide — not a web address, not a clock, and not something that sits
/// near the top of most slides alike (the browser's address bar, the course site's banner) — with its second line
/// when the title runs onto one. No title (a photo, a blank slide): nil, and the slide keeps just its number.
/// What a slide says, read with Vision on the device — laid over the slide in the PDF as invisible text (SlidesPDF.invisible).
/// Korean and English (as the titles are read), or the lecture's language with English when Vision reads it; about 0.15
/// s a slide on an M2 (the first read in a process loads the model).
enum SlideText {
    struct Line { let text: String; let box: CGRect }       // box: fractions of the picture, origin bottom left (Vision's)

    /// Vision's languages for a lecture language: its own with English, if Vision reads it; otherwise Korean and English.
    static func languages(for lecture: String) -> [String] {
        let vision = ["ja": "ja-JP", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "yue-Hant": "yue-Hant", "yue-Hans": "yue-Hans",
                      "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "pt-BR": "pt-BR", "pt-PT": "pt-PT", "ru": "ru-RU",
                      "uk": "uk-UA", "vi": "vi-VT", "th": "th-TH", "ar": "ar-SA"]
        guard let v = vision[lecture], (try? VNRecognizeTextRequest().supportedRecognitionLanguages())?.contains(v) == true
        else { return ["ko-KR", "en-US"] }
        return [v, "en-US"]
    }

    static func read(_ image: CGImage, languages: [String] = ["ko-KR", "en-US"]) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = languages
        req.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image).perform([req]) } catch { return [] }
        return (req.results ?? []).compactMap { o in              // in Vision's order: top down, left to right
            guard let c = o.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
            let s = c.string.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : Line(text: s, box: o.boundingBox)
        }
    }
}

enum SlideTitles {
    struct Found { let text: String; let top: Double; let height: Double; let minX: Double; let maxX: Double }

    /// `found`: each slide's lines, as `lines(_:)` read them. `within`: the part of each picture 깔끔하게 담기 keeps
    /// (nil: all of it) — only text inside it counts, measured against it.
    static func read(_ found: [[Found]], within crops: [CGRect?] = []) -> [String?] {
        let images = found
        var seen: [String: Int] = [:]                                    // what repeats near the top: the window around
        for f in found { for k in Set(f.filter { $0.top < 0.16 }.map { key($0.text) }) { seen[k, default: 0] += 1 } }
        let chrome = Set(seen.filter { images.count >= 2 && $0.value >= max(2, (images.count + 1) / 2) }.map(\.key))
        return found.enumerated().map { n, lines in
            let own = lines.filter { !($0.top < 0.16 && chrome.contains(key($0.text))) }
            guard n < crops.count, let c = crops[n] else { return pick(own) }
            return pick(own.compactMap { l in
                let cx = (l.minX + l.maxX) / 2, cy = l.top + l.height / 2
                guard c.contains(CGPoint(x: cx, y: cy)) else { return nil }
                return Found(text: l.text, top: (l.top - c.minY) / c.height, height: l.height / c.height,
                             minX: (l.minX - c.minX) / c.width, maxX: (l.maxX - c.minX) / c.width)
            })
        }
    }

    private static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The lines of text in the upper 45 % of a picture (positions and sizes as fractions of the whole picture, top down).
    static func lines(_ image: CGImage) -> [Found] {
        let share = 0.45
        guard let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: max(1, Int(Double(image.height) * share)))) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ko-KR", "en-US"]
        req.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: top).perform([req]) } catch { return [] }
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, c.confidence >= 0.4 else { return nil }
            let s = c.string.trimmingCharacters(in: .whitespaces)
            guard s.filter({ $0.isLetter }).count >= 2,
                  s.range(of: #"(https?://|www\.|\.(com|org|net|kr|edu|io|ac)\b)"#, options: [.regularExpression, .caseInsensitive]) == nil,
                  s.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) == nil else { return nil }
            let b = o.boundingBox
            return Found(text: s, top: (1 - b.maxY) * share, height: b.height * share, minX: b.minX, maxX: b.maxX)
        }
    }

    /// The title among a slide's lines: the biggest (a near tie goes to the higher one), plus the line right under it
    /// when that is the title's second line (about as big, just below, overlapping it).
    static func pick(_ lines: [Found]) -> String? {
        let tall = lines.filter { $0.height >= 0.022 }
        guard let biggest = tall.map(\.height).max(),
              let title = tall.filter({ $0.height >= biggest * 0.88 }).min(by: { $0.top < $1.top }) else { return nil }
        var text = title.text
        if let second = tall.filter({ $0.top > title.top && $0.top - (title.top + title.height) < title.height * 0.9
                                       && $0.height >= title.height * 0.75 && min($0.maxX, title.maxX) > max($0.minX, title.minX) })
            .min(by: { $0.top < $1.top }) {
            text += " " + second.text
        }
        text = text.split(separator: " ").joined(separator: " ")
        return text.count > 60 ? String(text.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

/// A crash or a quit during recording leaves a collector folder behind: turn it into the PDF.
func recoverSlides() {
    let fm = FileManager.default
    for dir in (try? fm.contentsOfDirectory(at: SlideCollector.root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
        let mod = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        guard Date().timeIntervalSince(mod) > 60 else { continue }
        if let p = try? String(contentsOf: dir.appendingPathComponent("transcript.path"), encoding: .utf8),
           let txt = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8), let parsed = Library.parse(txt) {
            let lines = parsed.lines.map { ($0.t, 0.0, $0.text) }        // ends unknown: up to the next line
            let n = SlidesPDF.build(from: dir, transcript: URL(fileURLWithPath: p), lines: lines, end: lines.last?.0 ?? 0,
                                    layout: Settings.load().pdfLayout, clean: Settings.load().cleanCapture)
            log("recovered \(n) slides for an earlier session")
        }
        try? fm.removeItem(at: dir)
    }
}
