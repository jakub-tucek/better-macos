import Foundation

/// Pure layout planning in CoreGraphics coordinates (positive Y points down).
/// Surviving edge-connected groups move together, preserving their internal
/// alignment. Gaps between groups close without swapping left/right or above/below.
enum DisplayTopology {
    private struct Tile {
        let uuid: String
        var frame: CGRect
    }

    static func plan(_ baseline: [DisplayPosition], active: Set<String>, anchor: String) -> [DisplayPosition]? {
        guard !active.isEmpty, active.contains(anchor),
              Set(baseline.map(\.uuid)).count == baseline.count,
              active.isSubset(of: Set(baseline.map(\.uuid))) else { return nil }
        var original: [Tile] = []
        for position in baseline {
            guard let width = position.width, let height = position.height, width > 0, height > 0 else { return nil }
            original.append(Tile(uuid: position.uuid, frame: CGRect(x: Int(position.x), y: Int(position.y),
                                                                   width: Int(width), height: Int(height))))
        }
        original.sort { $0.uuid < $1.uuid }
        guard !overlaps(original), connectedGroups(original).count == 1 else { return nil }
        let surviving = original.filter { active.contains($0.uuid) }
        var groups = connectedGroups(surviving)
        guard let anchorGroup = groups.firstIndex(where: { $0.contains(where: { $0.uuid == anchor }) }) else { return nil }
        var placed = groups.remove(at: anchorGroup)
        let originals = Dictionary(uniqueKeysWithValues: original.map { ($0.uuid, $0.frame) })

        while !groups.isEmpty {
            var best: (index: Int, tiles: [Tile], distance: CGFloat)?
            for (index, group) in groups.enumerated() {
                for fixed in placed {
                    for moving in group {
                        let a = fixed.frame, b = moving.frame
                        let oldA = originals[fixed.uuid]!, oldB = originals[moving.uuid]!
                        var shifts: [CGPoint] = []
                        if overlap(a.minY, a.maxY, b.minY, b.maxY) > 0 {
                            if oldA.maxX <= oldB.minX { shifts.append(CGPoint(x: a.maxX - b.minX, y: 0)) }
                            if oldB.maxX <= oldA.minX { shifts.append(CGPoint(x: a.minX - b.maxX, y: 0)) }
                        }
                        if overlap(a.minX, a.maxX, b.minX, b.maxX) > 0 {
                            if oldA.maxY <= oldB.minY { shifts.append(CGPoint(x: 0, y: a.maxY - b.minY)) }
                            if oldB.maxY <= oldA.minY { shifts.append(CGPoint(x: 0, y: a.minY - b.maxY)) }
                        }
                        for shift in shifts {
                            let moved = group.map { Tile(uuid: $0.uuid, frame: $0.frame.offsetBy(dx: shift.x, dy: shift.y)) }
                            let combined = placed + moved
                            guard !overlaps(combined), preservesOrder(combined, original: originals) else { continue }
                            let distance = abs(shift.x) + abs(shift.y)
                            if best == nil || distance < best!.distance { best = (index, moved, distance) }
                        }
                    }
                }
            }
            // An ambiguous diagonal-only layout needs manual arrangement rather
            // than guessing a new physical relationship between monitors.
            guard let best else { return nil }
            placed += best.tiles
            groups.remove(at: best.index)
        }
        guard let origin = placed.first(where: { $0.uuid == anchor })?.frame.origin else { return nil }
        var result: [DisplayPosition] = []
        for tile in placed.sorted(by: { $0.uuid < $1.uuid }) {
            guard let x = Int32(exactly: tile.frame.minX - origin.x),
                  let y = Int32(exactly: tile.frame.minY - origin.y),
                  let width = Int32(exactly: tile.frame.width), let height = Int32(exactly: tile.frame.height) else { return nil }
            result.append(DisplayPosition(uuid: tile.uuid, x: x, y: y, width: width, height: height))
        }
        return result
    }

    private static func overlap(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
        min(b, d) - max(a, c)
    }

    private static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        ((a.maxX == b.minX || b.maxX == a.minX) && overlap(a.minY, a.maxY, b.minY, b.maxY) > 0) ||
        ((a.maxY == b.minY || b.maxY == a.minY) && overlap(a.minX, a.maxX, b.minX, b.maxX) > 0)
    }

    private static func overlaps(_ tiles: [Tile]) -> Bool {
        for (i, a) in tiles.enumerated() {
            for b in tiles.dropFirst(i + 1) where overlap(a.frame.minX, a.frame.maxX, b.frame.minX, b.frame.maxX) > 0 &&
                overlap(a.frame.minY, a.frame.maxY, b.frame.minY, b.frame.maxY) > 0 { return true }
        }
        return false
    }

    private static func connectedGroups(_ tiles: [Tile]) -> [[Tile]] {
        var remaining = tiles
        var result: [[Tile]] = []
        while !remaining.isEmpty {
            var group = [remaining.removeFirst()]
            while let index = remaining.firstIndex(where: { tile in group.contains { touches($0.frame, tile.frame) } }) {
                group.append(remaining.remove(at: index))
            }
            result.append(group)
        }
        return result
    }

    private static func preservesOrder(_ tiles: [Tile], original: [String: CGRect]) -> Bool {
        for a in tiles {
            for b in tiles where a.uuid != b.uuid {
                let oldA = original[a.uuid]!, oldB = original[b.uuid]!
                if overlap(oldA.minY, oldA.maxY, oldB.minY, oldB.maxY) > 0,
                   oldA.maxX <= oldB.minX, a.frame.maxX > b.frame.minX { return false }
                if overlap(oldA.minX, oldA.maxX, oldB.minX, oldB.maxX) > 0,
                   oldA.maxY <= oldB.minY, a.frame.maxY > b.frame.minY { return false }
            }
        }
        return true
    }
}
