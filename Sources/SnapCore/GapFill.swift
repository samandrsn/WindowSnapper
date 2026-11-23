import CoreGraphics

/// "Fill the gap" (⌥⌘/ by default): grow the window into the empty space around it. Each edge moves
/// outward until it meets another window or the edge of the screen.
public enum GapFill {
    /// - window: the focused window's frame. others: every other on-screen window's frame.
    /// - screen: the visible frame of the window's display (other displays are ignored).
    /// - minOverlap: how much another window must line up with this one to count as in the way.
    /// Returns the grown frame, or nil if there's no room to grow.
    public static func fill(_ window: CGRect, others: [CGRect], screen: CGRect, minOverlap: CGFloat = 40) -> CGRect? {
        let start = window.intersection(screen).isNull ? window : window.intersection(screen)
        let obstacles = others.filter { $0.intersects(screen) && !SnapMath.approximatelyEqual($0, window) }

        // Growing up/down first vs left/right first can give different shapes; keep the bigger one.
        let a = growHorizontally(growVertically(start, obstacles, screen, minOverlap), obstacles, screen, minOverlap)
        let b = growVertically(growHorizontally(start, obstacles, screen, minOverlap), obstacles, screen, minOverlap)
        let best = a.width * a.height >= b.width * b.height ? a : b

        // Only worth doing if it actually grows by a noticeable amount.
        let grew = window.minX - best.minX > 4 || best.maxX - window.maxX > 4 ||
            window.minY - best.minY > 4 || best.maxY - window.maxY > 4
        return grew ? best : nil
    }

    private static func growVertically(_ r: CGRect, _ obstacles: [CGRect], _ screen: CGRect, _ minOverlap: CGFloat) -> CGRect {
        let tol: CGFloat = 2
        let lined = obstacles.filter { min($0.maxX, r.maxX) - max($0.minX, r.minX) >= minOverlap }
        let top = lined.filter { $0.maxY <= r.minY + tol }.map(\.maxY).max().map { max($0, screen.minY) } ?? screen.minY
        let bottom = lined.filter { $0.minY >= r.maxY - tol }.map(\.minY).min().map { min($0, screen.maxY) } ?? screen.maxY
        return CGRect(x: r.minX, y: min(top, r.minY), width: r.width, height: max(bottom, r.maxY) - min(top, r.minY))
    }

    private static func growHorizontally(_ r: CGRect, _ obstacles: [CGRect], _ screen: CGRect, _ minOverlap: CGFloat) -> CGRect {
        let tol: CGFloat = 2
        let lined = obstacles.filter { min($0.maxY, r.maxY) - max($0.minY, r.minY) >= minOverlap }
        let left = lined.filter { $0.maxX <= r.minX + tol }.map(\.maxX).max().map { max($0, screen.minX) } ?? screen.minX
        let right = lined.filter { $0.minX >= r.maxX - tol }.map(\.minX).min().map { min($0, screen.maxX) } ?? screen.maxX
        return CGRect(x: min(left, r.minX), y: r.minY, width: max(right, r.maxX) - min(left, r.minX), height: r.height)
    }
}
