import AppKit
import SnapCore

/// Keyboard window snapping: ⌥⌘ + arrow cycles ½ → ⅓ → ¾ → ⅔ → next monitor.
/// Two perpendicular arrows in quick succession make a corner. ⌥⌘ + right ⇧ maximizes.
/// If there's empty space between the window and another window in that direction, the first
/// press grows the window across that gap instead; pressing again starts the cycle at ½.
final class Snapper {
    /// Two arrows closer together than this count as one corner gesture.
    static let cornerWindow: TimeInterval = 0.25

    /// What the last press did, so the next press can continue the cycle or make a corner.
    private struct LastSnap {
        let window: AXUIElement
        let state: SnapState
        let frame: CGRect   // the frame the window actually ended up with
        let time: Date
        var gapFill: Direction? = nil   // set when this press filled a gap
    }
    private var last: LastSnap?

    func snap(_ direction: Direction) {
        guard AX.isTrusted else { AX.promptForTrust(); return }
        guard let window = AX.focusedWindow(), let frame = AX.frame(of: window) else { NSSound.beep(); return }

        let screens = LiveScreen.all()
        guard let current = SnapMath.bestScreen(for: frame, screens: screens.map(\.frame)) else { return }

        // Continue from the last snap only if it's the same window and nobody moved it since.
        var previous: SnapState?
        var quick = false
        var justFilledThisWay = false
        if let last, CFEqual(last.window, window), SnapMath.approximatelyEqual(last.frame, frame) {
            previous = last.state
            quick = Date().timeIntervalSince(last.time) < Self.cornerWindow
            justFilledThisWay = last.gapFill == direction
        }

        let t = SnapMath.transition(from: previous, pressing: direction, quick: quick)

        // Fill the gap first: only when this press would start a fresh cycle that way (not
        // continuing one or making a corner), and we didn't just fill a gap in this direction.
        if t.state == .plain(direction) && !t.moveToNextScreen && !justFilledThisWay {
            let visible = screens[current].visible
            if let filled = GapFill.target(for: frame, direction: direction,
                                           others: AX.otherWindowFrames(), screen: visible) {
                AX.setFrame(window, filled)
                last = LastSnap(window: window, state: SnapState(), frame: AX.frame(of: window) ?? filled,
                                time: Date(), gapFill: direction)
                return
            }
        }
        var screenIndex = current
        if t.moveToNextScreen {
            // No other monitor → just start the cycle over on this one.
            screenIndex = SnapMath.neighborScreen(from: current, direction: direction,
                                                  screens: screens.map(\.frame)) ?? current
        }

        let visible = screens[screenIndex].visible
        let target = SnapMath.rect(for: t.state, in: visible)
        let actual = AX.setFrame(window, target, inside: visible,
                                 anchorRight: t.state.horizontal?.direction == .right,
                                 anchorBottom: t.state.vertical?.direction == .down)
        last = LastSnap(window: window, state: t.state, frame: actual, time: Date())
    }

    /// Snap a specific window (used by drag-to-edge). nil state = maximize. Afterwards the arrow
    /// keys continue the cycle from here (e.g. drag to the left edge, then ⌥⌘← gives ⅓).
    func place(_ window: AXUIElement, _ state: SnapState?, on screen: LiveScreen) {
        guard let state else {
            AX.setFrame(window, screen.visible, inside: screen.visible, anchorRight: false, anchorBottom: false)
            last = nil
            return
        }
        let actual = AX.setFrame(window, SnapMath.rect(for: state, in: screen.visible), inside: screen.visible,
                                 anchorRight: state.horizontal?.direction == .right,
                                 anchorBottom: state.vertical?.direction == .down)
        last = LastSnap(window: window, state: state, frame: actual, time: .distantPast)
    }

    /// Fill the current display (not macOS full screen).
    func maximize() {
        guard AX.isTrusted else { AX.promptForTrust(); return }
        guard let window = AX.focusedWindow(), let frame = AX.frame(of: window) else { NSSound.beep(); return }
        let screens = LiveScreen.all()
        guard let i = SnapMath.bestScreen(for: frame, screens: screens.map(\.frame)) else { return }
        AX.setFrame(window, screens[i].visible, inside: screens[i].visible, anchorRight: false, anchorBottom: false)
        last = nil
    }
}
