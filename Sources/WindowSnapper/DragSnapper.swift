import AppKit
import QuartzCore
import SnapCore

/// Drag a window to a screen edge or corner → a preview animates in → let go and it snaps.
final class DragSnapper {
    var isEnabled: () -> Bool = { true }
    /// Called on drop with the window and where it should go (nil state = maximize).
    var onSnap: ((AXUIElement, SnapState?, LiveScreen) -> Void)?

    private var monitors: [Any] = []
    private let overlay = SnapOverlay()

    // Per-drag state.
    private var window: AXUIElement?
    private var startFrame: CGRect?
    private var screens: [LiveScreen] = []
    private var isMovingWindow = false
    private var lastProbe = Date.distantPast
    private var current: (zone: DragZone, screen: Int)?

    func start() {
        guard monitors.isEmpty else { return }
        let add = { (mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { self.monitors.append(m) }
        }
        add(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] _ in self?.mouseDragged() }
        add(.leftMouseUp) { [weak self] _ in self?.mouseUp() }
    }

    private func mouseDown() {
        reset()
        guard isEnabled(), AX.isTrusted else { return }
        let p = AX.mouseLocation()
        guard let w = AX.window(at: p), let f = AX.frame(of: w) else { return }
        window = w
        startFrame = f
        screens = LiveScreen.all()
    }

    private func mouseDragged() {
        guard let window, let start = startFrame else { return }

        // Only act when the window is being *moved* (title-bar drag), not resized or text-selected.
        if !isMovingWindow {
            guard Date().timeIntervalSince(lastProbe) > 0.03 else { return }
            lastProbe = Date()
            guard let f = AX.frame(of: window) else { return }
            let moved = abs(f.minX - start.minX) > 2 || abs(f.minY - start.minY) > 2
            let sameSize = abs(f.width - start.width) < 2 && abs(f.height - start.height) < 2
            guard moved && sameSize else {
                if !sameSize { self.window = nil }   // it's a resize; ignore the rest of this drag
                return
            }
            isMovingWindow = true
        }

        let p = AX.mouseLocation()
        guard let si = screens.firstIndex(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }),
              let zone = DragZones.zone(for: p, in: screens[si].frame) else {
            if current != nil { current = nil; overlay.hide(toward: p) }
            return
        }
        if current?.zone != zone || current?.screen != si {
            current = (zone, si)
            overlay.show(zone, screen: screens[si], from: p)
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard isMovingWindow, let window, let (zone, si) = current else { return }
        let screen = screens[si]
        overlay.commit()
        // Let the app finish its own drag handling before we resize the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.onSnap?(window, zone.state, screen)
        }
    }

    private func reset() {
        if current != nil && !isMovingWindow { overlay.hide(toward: nil) }
        window = nil
        startFrame = nil
        isMovingWindow = false
        current = nil
    }
}
