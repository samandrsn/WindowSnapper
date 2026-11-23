import CoreGraphics

/// Where dragging a window to the edge of a screen will snap it.
public enum DragZone: Equatable {
    case left, right, maximize
    case topLeft, topRight, bottomLeft, bottomRight

    /// The snap this zone means. nil = maximize (fill the screen).
    public var state: SnapState? {
        switch self {
        case .left: return SnapState(horizontal: AxisSnap(.left, 0))
        case .right: return SnapState(horizontal: AxisSnap(.right, 0))
        case .maximize: return nil
        case .topLeft: return SnapState(horizontal: AxisSnap(.left, 0), vertical: AxisSnap(.up, 0))
        case .topRight: return SnapState(horizontal: AxisSnap(.right, 0), vertical: AxisSnap(.up, 0))
        case .bottomLeft: return SnapState(horizontal: AxisSnap(.left, 0), vertical: AxisSnap(.down, 0))
        case .bottomRight: return SnapState(horizontal: AxisSnap(.right, 0), vertical: AxisSnap(.down, 0))
        }
    }
}

public enum DragZones {
    /// - point: mouse position (AX coordinates). screen: that display's full frame.
    /// - edge: how close to an edge counts as "at the edge".
    /// - corner: how far along an edge from a corner still counts as the corner.
    /// Left/right edges → halves, top edge → maximize, corners → quarters. Bottom edge (where the
    /// Dock lives) only does its corners.
    public static func zone(for p: CGPoint, in screen: CGRect, edge: CGFloat = 5, corner: CGFloat = 60) -> DragZone? {
        let atLeft = p.x <= screen.minX + edge
        let atRight = p.x >= screen.maxX - 1 - edge
        let atTop = p.y <= screen.minY + edge
        let atBottom = p.y >= screen.maxY - 1 - edge
        guard atLeft || atRight || atTop || atBottom else { return nil }

        let nearTop = p.y <= screen.minY + corner
        let nearBottom = p.y >= screen.maxY - 1 - corner
        let nearLeft = p.x <= screen.minX + corner
        let nearRight = p.x >= screen.maxX - 1 - corner

        if atLeft || atRight {
            if nearTop { return atLeft ? .topLeft : .topRight }
            if nearBottom { return atLeft ? .bottomLeft : .bottomRight }
            return atLeft ? .left : .right
        }
        if atTop {
            if nearLeft { return .topLeft }
            if nearRight { return .topRight }
            return .maximize
        }
        // Bottom edge.
        if nearLeft { return .bottomLeft }
        if nearRight { return .bottomRight }
        return nil
    }

    /// The rect a zone fills inside a visible frame.
    public static func rect(for zone: DragZone, in visible: CGRect) -> CGRect {
        guard let state = zone.state else { return visible }
        return SnapMath.rect(for: state, in: visible)
    }
}
