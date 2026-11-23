import CoreGraphics

/// "Fill the gap" (⌥⌘/ by default): fit the window into the empty space around it. Each edge moves
/// until it meets a neighbouring window or the edge of the screen.
public enum GapFill {
    /// - window: the focused window's frame. others: every other on-screen window's frame.
    /// - screen: the visible frame of the window's display (other displays are ignored).
    /// - minOverlap: how much another window must line up with this one to count as in the way.
    /// Returns the new frame, or nil if the window already fills its space.
    public static func fill(_ window: CGRect, others: [CGRect], screen: CGRect, minOverlap: CGFloat = 40) -> CGRect? {
        let start = window.intersection(screen).isNull ? window : window.intersection(screen)
        let obstacles = others.filter { $0.intersects(screen) && !SnapMath.approximatelyEqual($0, window) }

        // Growing up/down first vs left/right first can give different shapes; keep the bigger one.
        let a = growHorizontally(growVertically(start, obstacles, screen, minOverlap), obstacles, screen, minOverlap)
        let b = growVertically(growHorizontally(start, obstacles, screen, minOverlap), obstacles, screen, minOverlap)
        let best = a.width * a.height >= b.width * b.height ? a : b

        // Only worth doing if something actually changes.
        return SnapMath.approximatelyEqual(best, window) ? nil : best
    }

    // A neighbour is a window that lines up with ours and sits mostly beyond one of our edges.
    // It may overlap that edge a little (windows often do); our edge then lands exactly on it,
    // even if that means shrinking slightly. Windows that are entirely behind or inside ours
    // (not extending past the edge) are ignored.

    private static func growVertically(_ r: CGRect, _ obstacles: [CGRect], _ screen: CGRect, _ minOverlap: CGFloat) -> CGRect {
        let lined = obstacles.filter { min($0.maxX, r.maxX) - max($0.minX, r.minX) >= minOverlap }
        let above = lined.filter { $0.minY < r.minY && $0.maxY < r.maxY }
        let below = lined.filter { $0.maxY > r.maxY && $0.minY > r.minY }
        let top = max(above.map(\.maxY).max() ?? screen.minY, screen.minY)
        let bottom = min(below.map(\.minY).min() ?? screen.maxY, screen.maxY)
        guard bottom - top >= 100 else { return r }
        return CGRect(x: r.minX, y: top, width: r.width, height: bottom - top)
    }

    private static func growHorizontally(_ r: CGRect, _ obstacles: [CGRect], _ screen: CGRect, _ minOverlap: CGFloat) -> CGRect {
        let lined = obstacles.filter { min($0.maxY, r.maxY) - max($0.minY, r.minY) >= minOverlap }
        let left = lined.filter { $0.minX < r.minX && $0.maxX < r.maxX }
        let right = lined.filter { $0.maxX > r.maxX && $0.minX > r.minX }
        let l = max(left.map(\.maxX).max() ?? screen.minX, screen.minX)
        let rr = min(right.map(\.minX).min() ?? screen.maxX, screen.maxX)
        guard rr - l >= 100 else { return r }
        return CGRect(x: l, y: r.minY, width: rr - l, height: r.height)
    }
}
