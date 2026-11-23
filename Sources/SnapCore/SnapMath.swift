import CoreGraphics
import Foundation

/// All rects in this module use the Accessibility coordinate space:
/// origin at the top-left of the primary display, y grows downward.

public enum Direction: String, Codable, CaseIterable {
    case left, right, up, down
    public var isHorizontal: Bool { self == .left || self == .right }
}

/// Which edge a window is snapped to on one axis, and how far through the size cycle it is.
public struct AxisSnap: Equatable {
    public var direction: Direction
    public var step: Int
    public init(_ direction: Direction, _ step: Int) { self.direction = direction; self.step = step }
}

/// Where a window is snapped. One axis set = a half/third/etc. spanning the full other axis.
/// Both set = a corner (e.g. right ½ × top ½).
public struct SnapState: Equatable {
    public var horizontal: AxisSnap?
    public var vertical: AxisSnap?
    public init(horizontal: AxisSnap? = nil, vertical: AxisSnap? = nil) {
        self.horizontal = horizontal; self.vertical = vertical
    }
    public var isCorner: Bool { horizontal != nil && vertical != nil }

    public static func plain(_ d: Direction) -> SnapState {
        d.isHorizontal ? SnapState(horizontal: AxisSnap(d, 0)) : SnapState(vertical: AxisSnap(d, 0))
    }
}

public enum SnapMath {
    /// Press 1 → ½, 2 → ⅓, 3 → ¾, 4 → ⅔, 5 → next monitor (then it starts over).
    public static let fractions: [CGFloat] = [1.0 / 2.0, 1.0 / 3.0, 3.0 / 4.0, 2.0 / 3.0]

    /// The result of pressing an arrow.
    public struct Transition: Equatable {
        public var state: SnapState
        public var moveToNextScreen: Bool
    }

    /// - previous: where the window is snapped now (nil if it isn't, or was moved by hand since).
    /// - quick: the previous arrow was pressed only a moment ago (that's how corners are made).
    public static func transition(from previous: SnapState?, pressing d: Direction, quick: Bool) -> Transition {
        guard let s = previous else { return Transition(state: .plain(d), moveToNextScreen: false) }
        let same = d.isHorizontal ? s.horizontal : s.vertical

        // Same arrow again: cycle that axis' size. Works for halves and for corners.
        if let same, same.direction == d {
            var next = s
            let step = same.step + 1
            let wraps = step >= fractions.count
            let axis = AxisSnap(d, wraps ? 0 : step)
            if d.isHorizontal { next.horizontal = axis } else { next.vertical = axis }
            return Transition(state: next, moveToNextScreen: wraps)
        }
        // Opposite arrow on the same axis: leave any corner, plain half on that side.
        if same != nil { return Transition(state: .plain(d), moveToNextScreen: false) }

        // Perpendicular arrow right after a snap → corner, keeping the other axis as it was.
        if quick {
            var corner = s
            if d.isHorizontal { corner.horizontal = AxisSnap(d, 0) } else { corner.vertical = AxisSnap(d, 0) }
            return Transition(state: corner, moveToNextScreen: false)
        }
        return Transition(state: .plain(d), moveToNextScreen: false)
    }

    /// The rect for a snap state inside `screen` (a visible frame). An unset axis spans the screen.
    public static func rect(for state: SnapState, in s: CGRect) -> CGRect {
        var r = s
        if let h = state.horizontal {
            let w = s.width * fraction(h.step)
            r.origin.x = h.direction == .left ? s.minX : s.maxX - w
            r.size.width = w
        }
        if let v = state.vertical {
            let h = s.height * fraction(v.step)
            r.origin.y = v.direction == .up ? s.minY : s.maxY - h
            r.size.height = h
        }
        return rounded(r)
    }

    /// Convenience for a plain (non-corner) snap.
    public static func rect(for direction: Direction, step: Int, in screen: CGRect) -> CGRect {
        let a = AxisSnap(direction, step)
        return rect(for: direction.isHorizontal ? SnapState(horizontal: a) : SnapState(vertical: a), in: screen)
    }

    static func fraction(_ step: Int) -> CGFloat {
        fractions[((step % fractions.count) + fractions.count) % fractions.count]
    }

    /// Picks the screen to jump to when cycling past the last fraction.
    /// Prefers the nearest screen in `direction`; if there is none, wraps around to the
    /// farthest screen on the opposite side. Returns nil when there is only one screen.
    public static func neighborScreen(from current: Int, direction: Direction, screens: [CGRect]) -> Int? {
        guard screens.count > 1, screens.indices.contains(current) else { return nil }
        let c = screens[current]
        let horizontal = direction == .left || direction == .right
        let sign: CGFloat = (direction == .left || direction == .up) ? -1 : 1
        func axis(_ r: CGRect) -> CGFloat { horizontal ? r.midX : r.midY }
        func dist(_ r: CGRect) -> CGFloat { hypot(r.midX - c.midX, r.midY - c.midY) }

        let others = screens.indices.filter { $0 != current }
        let ahead = others.filter { (axis(screens[$0]) - axis(c)) * sign > 0.5 }
        if let best = ahead.min(by: { dist(screens[$0]) < dist(screens[$1]) }) {
            return best
        }
        // Wrap: farthest screen in the opposite direction (e.g. pressing ← on the leftmost
        // monitor goes to the rightmost one).
        return others.max(by: { -sign * axis(screens[$0]) < -sign * axis(screens[$1]) })
    }

    /// Index of the screen that contains most of `rect` (falls back to the nearest screen).
    public static func bestScreen(for rect: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best = 0
        var bestArea: CGFloat = -1
        for (i, s) in screens.enumerated() {
            let inter = s.intersection(rect)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea { bestArea = area; best = i }
        }
        if bestArea > 0 { return best }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screens.indices.min(by: {
            hypot(screens[$0].midX - center.x, screens[$0].midY - center.y) <
                hypot(screens[$1].midX - center.x, screens[$1].midY - center.y)
        })
    }

    /// True when two frames are the same within a few points (apps sometimes round sizes).
    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: Layout geometry

    /// `rect` expressed as fractions of `screen`, so it can be re-applied to a screen of another size.
    public static func relative(_ rect: CGRect, in screen: CGRect) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - screen.minX) / screen.width,
                      y: (rect.minY - screen.minY) / screen.height,
                      width: rect.width / screen.width,
                      height: rect.height / screen.height)
    }

    /// Inverse of `relative`, clamped so the window stays on the screen.
    public static func absolute(_ rel: CGRect, in screen: CGRect) -> CGRect {
        let r = CGRect(x: screen.minX + rel.minX * screen.width,
                       y: screen.minY + rel.minY * screen.height,
                       width: rel.width * screen.width,
                       height: rel.height * screen.height)
        return clamp(rounded(r), to: screen)
    }

    /// Roughly how much of `rect` (0…1) the user can see: on a display and not under any of the
    /// `covering` windows (those in front of it). Sampled on a grid, which is plenty for this.
    public static func visibleFraction(of rect: CGRect, coveredBy covering: [CGRect], screens: [CGRect]) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        let n = 16
        var visible = 0
        for i in 0..<n {
            for j in 0..<n {
                let p = CGPoint(x: rect.minX + rect.width * (CGFloat(i) + 0.5) / CGFloat(n),
                                y: rect.minY + rect.height * (CGFloat(j) + 0.5) / CGFloat(n))
                if screens.contains(where: { $0.contains(p) }) && !covering.contains(where: { $0.contains(p) }) {
                    visible += 1
                }
            }
        }
        return CGFloat(visible) / CGFloat(n * n)
    }

    public static func clamp(_ r: CGRect, to s: CGRect) -> CGRect {
        let w = min(r.width, s.width)
        let h = min(r.height, s.height)
        let x = min(max(r.minX, s.minX), s.maxX - w)
        let y = min(max(r.minY, s.minY), s.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func rounded(_ r: CGRect) -> CGRect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded()
        let x1 = r.maxX.rounded(), y1 = r.maxY.rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
