import CoreGraphics

/// "Fill the gap": when there's empty space between a window and another window in the
/// direction you press, grow the window's edge across that space until it meets the other one.
public enum GapFill {
    /// - window: the focused window's frame. others: every other on-screen window's frame.
    /// - screen: the visible frame of the window's display (others outside it are ignored).
    /// - minGap: smaller gaps than this are ignored. minOverlap: how much another window must
    ///   line up with this one (side by side, across the arrow) to count as "in the way".
    /// Returns the grown frame, or nil when there's no window-to-window gap that way.
    public static func target(for window: CGRect, direction: Direction, others: [CGRect], screen: CGRect,
                              minGap: CGFloat = 20, minOverlap: CGFloat = 40) -> CGRect? {
        let tol: CGFloat = 2
        let candidates = others.filter { $0.intersects(screen) && !SnapMath.approximatelyEqual($0, window) }

        func overlapX(_ r: CGRect) -> CGFloat { min(r.maxX, window.maxX) - max(r.minX, window.minX) }
        func overlapY(_ r: CGRect) -> CGFloat { min(r.maxY, window.maxY) - max(r.minY, window.minY) }

        var result = window
        switch direction {
        case .up:
            // Windows entirely above us that line up horizontally; stop at the lowest bottom edge.
            let edges = candidates.filter { $0.maxY <= window.minY + tol && overlapX($0) >= minOverlap }.map(\.maxY)
            guard let edge = edges.max() else { return nil }
            let newTop = max(edge, screen.minY)
            guard window.minY - newTop >= minGap else { return nil }
            result.size.height += window.minY - newTop
            result.origin.y = newTop
        case .down:
            let edges = candidates.filter { $0.minY >= window.maxY - tol && overlapX($0) >= minOverlap }.map(\.minY)
            guard let edge = edges.min() else { return nil }
            let newBottom = min(edge, screen.maxY)
            guard newBottom - window.maxY >= minGap else { return nil }
            result.size.height = newBottom - window.minY
        case .left:
            let edges = candidates.filter { $0.maxX <= window.minX + tol && overlapY($0) >= minOverlap }.map(\.maxX)
            guard let edge = edges.max() else { return nil }
            let newLeft = max(edge, screen.minX)
            guard window.minX - newLeft >= minGap else { return nil }
            result.size.width += window.minX - newLeft
            result.origin.x = newLeft
        case .right:
            let edges = candidates.filter { $0.minX >= window.maxX - tol && overlapY($0) >= minOverlap }.map(\.minX)
            guard let edge = edges.min() else { return nil }
            let newRight = min(edge, screen.maxX)
            guard newRight - window.maxX >= minGap else { return nil }
            result.size.width = newRight - window.minX
        }
        return result
    }
}
