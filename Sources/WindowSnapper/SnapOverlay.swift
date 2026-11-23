import AppKit
import SnapCore

/// The drag-to-snap preview, in one of two styles (Settings → Preview style):
/// - Fancy: a progressive blur + dim that fades to black against the screen edge the window will
///   sit on, lighter toward the middle of the screen (like the iPhone Duo UI).
/// - Simple: a grey frosted Liquid Glass panel with a light border, inset inside the zone.
///
/// Motion is real spring physics rather than fixed-duration animations, so it feels liquid:
/// it starts as a droplet at the cursor and stretches into the zone, it keeps its momentum when
/// you slide to another zone, and it swells and dissolves when you drop the window.
final class SnapOverlay {
    private let panel: NSPanel
    private let fancyLook = EdgeBlurView()
    private let simpleLook = SimpleGlassView()
    private var fancy = true
    private var look: PreviewLook { fancy ? fancyLook : simpleLook }
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()

    // Position follows slightly stiffer than size, so the shape stretches a touch as it moves.
    private var x = Spring(stiffness: 340, damping: 27)
    private var y = Spring(stiffness: 340, damping: 27)
    private var w = Spring(stiffness: 260, damping: 21)
    private var h = Spring(stiffness: 260, damping: 21)
    private var alpha: CGFloat = 0
    private var alphaTarget: CGFloat = 0
    private var alphaRate: CGFloat = 16
    private var cornerRadius: CGFloat = 38
    private var isDismissing = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0

        let root = NSView()
        root.wantsLayer = true
        panel.contentView = root
        root.addSubview(fancyLook)
        root.addSubview(simpleLook)
    }

    // MARK: Public

    /// Flow to `zone` on `screen` (AX coordinates). If hidden, it starts as a droplet at the cursor.
    func show(_ zone: DragZone, screen: LiveScreen, from axPoint: CGPoint) {
        let screenFrame = screen.frame
        cover(AX.appKitRect(screenFrame))
        let starting = !panel.isVisible || alpha < 0.02
        if starting {
            // Pick the style when a preview starts, so it never switches mid-drag.
            fancy = Settings.shared.fancyPreview
            fancyLook.isHidden = !fancy
            simpleLook.isHidden = fancy
        }
        fancyLook.setZone(zone, animated: !starting)

        let r: CGRect
        if fancy {
            // Fill the zone right up to the screen edge (no gap), and push the shape past the edges
            // it touches so its rounded corners there land off-screen: only inner corners stay round.
            let zoneRect = DragZones.rect(for: zone, in: screenFrame)
            let bleed: CGFloat = 80
            var b = zoneRect
            if abs(zoneRect.minX - screenFrame.minX) < 1 { b.origin.x -= bleed; b.size.width += bleed }
            if abs(zoneRect.maxX - screenFrame.maxX) < 1 { b.size.width += bleed }
            if abs(zoneRect.minY - screenFrame.minY) < 1 { b.origin.y -= bleed; b.size.height += bleed }
            if abs(zoneRect.maxY - screenFrame.maxY) < 1 { b.size.height += bleed }
            r = b
        } else {
            // A floating card just inside where the window will land.
            r = DragZones.rect(for: zone, in: screen.visible).insetBy(dx: 10, dy: 10)
        }
        let target = AX.appKitRect(r)
        if !panel.isVisible || alpha < 0.02 || isDismissing {
            if !panel.isVisible || alpha < 0.02 {
                let p = AX.appKitPoint(axPoint)
                setNow(CGRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56))
            }
            panel.orderFrontRegardless()
        }
        isDismissing = false
        cornerRadius = fancy ? 38 : 26
        alphaRate = 16
        alphaTarget = 1
        setTarget(target)
        run()
    }

    /// Left the zone: shrink back into the cursor and fade.
    func hide(toward axPoint: CGPoint?) {
        guard panel.isVisible else { return }
        let c = axPoint.map(AX.appKitPoint) ?? NSPoint(x: x.value + w.value / 2, y: y.value + h.value / 2)
        setTarget(CGRect(x: c.x - 20, y: c.y - 20, width: 40, height: 40))
        alphaTarget = 0
        alphaRate = 12
        isDismissing = true
        run()
    }

    /// Dropped: swell to fill the zone exactly, then dissolve as the window takes its place.
    func commit() {
        guard panel.isVisible else { return }
        let current = CGRect(x: x.target, y: y.target, width: w.target, height: h.target)
        setTarget(current.insetBy(dx: -8, dy: -8))
        // A little outward kick makes the swell feel like a release of pressure.
        w.velocity += 260; h.velocity += 260
        x.velocity -= 130; y.velocity -= 130
        isDismissing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.isDismissing else { return }
            self.alphaTarget = 0
            self.alphaRate = 5.5
        }
        run()
    }

    // MARK: Physics

    private struct Spring {
        let stiffness: CGFloat
        let damping: CGFloat
        var value: CGFloat = 0
        var velocity: CGFloat = 0
        var target: CGFloat = 0

        mutating func step(_ dt: CGFloat) {
            let force = -stiffness * (value - target) - damping * velocity
            velocity += force * dt
            value += velocity * dt
        }
        var atRest: Bool { abs(value - target) < 0.3 && abs(velocity) < 3 }
    }

    private func setTarget(_ r: CGRect) {
        x.target = r.minX; y.target = r.minY; w.target = r.width; h.target = r.height
    }

    private func setNow(_ r: CGRect) {
        for (s, v) in [(\SnapOverlay.x, r.minX), (\SnapOverlay.y, r.minY), (\SnapOverlay.w, r.width), (\SnapOverlay.h, r.height)] {
            self[keyPath: s].value = v
            self[keyPath: s].target = v
            self[keyPath: s].velocity = 0
        }
        alpha = 0
        render()
    }

    private func run() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // Sub-step so the springs stay stable even if a frame is late.
        var remaining = CGFloat(min(now - lastTick, 1.0 / 20.0))
        lastTick = now
        let alphaStep = 1 - exp(-alphaRate * remaining)
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 240.0)
            x.step(dt); y.step(dt); w.step(dt); h.step(dt)
            remaining -= dt
        }
        alpha += (alphaTarget - alpha) * alphaStep
        render()

        if isDismissing && alpha < 0.01 {
            stop()
            panel.orderOut(nil)
            alpha = 0
            panel.alphaValue = 0
        } else if !isDismissing && x.atRest && y.atRest && w.atRest && h.atRest && abs(alpha - alphaTarget) < 0.005 {
            stop()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func render() {
        let origin = panel.frame.origin
        let f = CGRect(x: x.value - origin.x, y: y.value - origin.y,
                       width: max(w.value, 2), height: max(h.value, 2))
        // While small it's a round droplet; as it grows the corners settle to a soft radius.
        let r = min(cornerRadius, min(f.width, f.height) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        look.frame = f
        look.update(cornerRadius: r)
        panel.alphaValue = max(0, min(1, alpha))
        CATransaction.commit()
    }

    /// The panel covers exactly one display; anything past its edges is clipped away, which is
    /// what lets the shape run "off" the screen edge. Springs work in global coordinates, so
    /// moving the panel to another display mid-drag doesn't disturb the motion.
    private func cover(_ screen: NSRect) {
        if panel.frame != screen { panel.setFrame(screen, display: false) }
    }
}

/// The preview's look. macOS has no public "variable blur", so it's built from two layers that
/// both fade across the shape: a strong blur (masked so it thins out) and a dark tint. Both are
/// heaviest on the side touching the screen edge and lightest toward the middle of the screen.
/// A preview style; `update` is called every animation frame inside a no-animation transaction.
protocol PreviewLook: NSView {
    func update(cornerRadius: CGFloat)
}

final class EdgeBlurView: NSView, PreviewLook {
    private let box = NSView()                 // clips everything to the rounded shape
    private let blurHost = NSView()
    private let blur = NSVisualEffectView()
    private let blurMask = CAGradientLayer()   // how much blur shows: full at the edge → light inside
    private let dim = CAGradientLayer()        // how dark: dark at the edge → slightly dim inside
    private let edge = CALayer()               // faint hairline so the shape reads
    // The dim and hairline live in their own views stacked above the blur. (As raw sublayers,
    // AppKit was drawing the blur view on top of them, which hid the darkening.)
    private let dimView = NSView()
    private let edgeView = NSView()

    // Strength from the screen edge (location 0) to the inner side (location 1), eased.
    // The shape extends ~80pt past the screen edge, so location 0 is off-screen; the visible edge
    // sits near 0.08 (for a half) and is essentially black.
    private static let locations: [NSNumber] = [0, 0.12, 0.3, 0.6, 1]
    private static let blurAmounts: [CGFloat] = [1, 1, 0.85, 0.5, 0.3]
    private static let dimAmounts: [CGFloat] = [1, 0.97, 0.82, 0.62, 0.48]

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        box.wantsLayer = true
        box.layer?.masksToBounds = true
        box.layer?.cornerCurve = .continuous
        addSubview(box)

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blurHost.wantsLayer = true
        blurHost.addSubview(blur)
        blurHost.layer?.mask = blurMask
        box.addSubview(blurHost)

        dimView.layer = dim
        dimView.wantsLayer = true
        box.addSubview(dimView)

        // Faint line only where it matters: the inner, rounded side.
        edge.borderWidth = 1
        edge.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        edge.cornerCurve = .continuous
        edgeView.layer = edge
        edgeView.wantsLayer = true
        box.addSubview(edgeView)

        setZone(.left, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Points the falloff away from the edge(s) this zone touches.
    func setZone(_ zone: DragZone, animated: Bool) {
        // Unit coordinates, origin bottom-left. `from` = the screen-edge side.
        let from: CGPoint, to: CGPoint
        var radial = false
        switch zone {
        case .left: from = CGPoint(x: 0, y: 0.5); to = CGPoint(x: 1, y: 0.5)
        case .right: from = CGPoint(x: 1, y: 0.5); to = CGPoint(x: 0, y: 0.5)
        case .topLeft: from = CGPoint(x: 0, y: 1); to = CGPoint(x: 1, y: 0)
        case .topRight: from = CGPoint(x: 1, y: 1); to = CGPoint(x: 0, y: 0)
        case .bottomLeft: from = CGPoint(x: 0, y: 0); to = CGPoint(x: 1, y: 1)
        case .bottomRight: from = CGPoint(x: 1, y: 0); to = CGPoint(x: 0, y: 1)
        case .maximize: from = CGPoint(x: 0.5, y: 0.5); to = CGPoint(x: 1.0, y: 1.0); radial = true
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        CATransaction.setDisableActions(!animated)
        for (layer, amounts) in [(blurMask, Self.blurAmounts), (dim, Self.dimAmounts)] {
            // Radial goes center → outside, so it runs inner strength → edge strength.
            let ordered = radial ? amounts.reversed() : amounts
            layer.type = radial ? .radial : .axial
            layer.colors = ordered.map { NSColor.black.withAlphaComponent($0).cgColor }
            layer.locations = radial ? Self.locations.reversed().map { NSNumber(value: 1 - $0.doubleValue) } : Self.locations
            layer.startPoint = from
            layer.endPoint = to
        }
        CATransaction.commit()
    }

    /// Called every animation frame (inside a no-animation transaction).
    func update(cornerRadius r: CGFloat) {
        let b = bounds
        box.frame = b
        box.layer?.cornerRadius = r
        blurHost.frame = b
        blur.frame = b
        blurMask.frame = b
        dimView.frame = b
        edgeView.frame = b
        edge.cornerRadius = r
    }
}

/// The "Simple" style: grey frosted Liquid Glass with a light border and a soft floating shadow.
final class SimpleGlassView: NSView, PreviewLook {
    private let shadowView = NSView()
    private let glass: NSView
    private let border = CALayer()
    private let borderView = NSView()

    init() {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            v.layer?.cornerCurve = .continuous
            glass = v
        }
        super.init(frame: .zero)
        wantsLayer = true

        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.35
        shadowView.layer?.shadowRadius = 18
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        addSubview(shadowView)
        addSubview(glass)

        border.borderWidth = 1.5
        border.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        border.cornerCurve = .continuous
        borderView.layer = border
        borderView.wantsLayer = true
        addSubview(borderView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(cornerRadius r: CGFloat) {
        let b = bounds
        shadowView.frame = b
        shadowView.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: b.size),
                                              cornerWidth: r, cornerHeight: r, transform: nil)
        glass.frame = b
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.cornerRadius = r
        } else {
            glass.layer?.cornerRadius = r
        }
        borderView.frame = b
        border.cornerRadius = r
    }
}
