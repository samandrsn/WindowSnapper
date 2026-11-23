import CoreGraphics
@testable import SnapCore
import XCTest

final class SnapMathTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1200, height: 800)

    func testCycleFractions() {
        XCTAssertEqual(SnapMath.rect(for: .left, step: 0, in: screen), CGRect(x: 0, y: 25, width: 600, height: 800))
        XCTAssertEqual(SnapMath.rect(for: .left, step: 1, in: screen), CGRect(x: 0, y: 25, width: 400, height: 800))
        XCTAssertEqual(SnapMath.rect(for: .left, step: 2, in: screen), CGRect(x: 0, y: 25, width: 900, height: 800))
        XCTAssertEqual(SnapMath.rect(for: .right, step: 1, in: screen), CGRect(x: 800, y: 25, width: 400, height: 800))
        XCTAssertEqual(SnapMath.rect(for: .up, step: 0, in: screen), CGRect(x: 0, y: 25, width: 1200, height: 400))
        XCTAssertEqual(SnapMath.rect(for: .down, step: 2, in: screen), CGRect(x: 0, y: 225, width: 1200, height: 600))
    }

    /// Presses a sequence of arrows; `quick` marks presses that came right after the previous one.
    private func press(_ seq: [(Direction, Bool)]) -> (SnapState?, [Bool]) {
        var state: SnapState?
        var moves: [Bool] = []
        for (d, quick) in seq {
            let t = SnapMath.transition(from: state, pressing: d, quick: quick)
            state = t.state
            moves.append(t.moveToNextScreen)
        }
        return (state, moves)
    }

    func testCycleSequence() {
        // ½ → ⅓ → ¾ → ⅔ → next monitor (back to ½)
        let (state, moves) = press(Array(repeating: (.left, false), count: 6))
        XCTAssertEqual(moves, [false, false, false, false, true, false])
        XCTAssertEqual(state, SnapState(horizontal: AxisSnap(.left, 1)))
        XCTAssertEqual(SnapMath.rect(for: .left, step: 3, in: screen), CGRect(x: 0, y: 25, width: 800, height: 800))
    }

    func testQuickPerpendicularMakesCorner() {
        let (state, _) = press([(.up, false), (.right, true)])
        XCTAssertEqual(state, SnapState(horizontal: AxisSnap(.right, 0), vertical: AxisSnap(.up, 0)))
        XCTAssertEqual(SnapMath.rect(for: state!, in: screen), CGRect(x: 600, y: 25, width: 600, height: 400))
    }

    func testSlowPerpendicularIsPlainSnap() {
        let (state, _) = press([(.up, false), (.right, false)])
        XCTAssertEqual(state, SnapState(horizontal: AxisSnap(.right, 0)))
    }

    func testCycleInsideCorner() {
        // Top-right corner, then keep pressing → (slowly) to cycle the width only.
        let (state, moves) = press([(.up, false), (.right, true), (.right, false), (.right, false)])
        XCTAssertEqual(state, SnapState(horizontal: AxisSnap(.right, 2), vertical: AxisSnap(.up, 0)))
        XCTAssertEqual(SnapMath.rect(for: state!, in: screen), CGRect(x: 300, y: 25, width: 900, height: 400))
        XCTAssertEqual(moves, [false, false, false, false])
        // …and ↑ cycles the height while staying in the right ½.
        let (s2, _) = press([(.up, false), (.right, true), (.up, false)])
        XCTAssertEqual(s2, SnapState(horizontal: AxisSnap(.right, 0), vertical: AxisSnap(.up, 1)))
    }

    func testCornerCarriesToNextMonitor() {
        let seq: [(Direction, Bool)] = [(.up, false), (.right, true)] + Array(repeating: (.right, false), count: 4)
        let (state, moves) = press(seq)
        XCTAssertEqual(moves.last, true)
        XCTAssertEqual(state, SnapState(horizontal: AxisSnap(.right, 0), vertical: AxisSnap(.up, 0)))
    }

    func testOppositeArrowLeavesCorner() {
        let (state, _) = press([(.up, false), (.right, true), (.left, false)])
        XCTAssertEqual(state, SnapState(horizontal: AxisSnap(.left, 0)))
    }

    func testNeighborScreens() {
        // [laptop] [monitor A] [monitor B], left to right; plus one monitor above A.
        let laptop = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let a = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let b = CGRect(x: 2560, y: 0, width: 2560, height: 1440)
        let above = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
        let screens = [a, laptop, b, above]
        XCTAssertEqual(SnapMath.neighborScreen(from: 0, direction: .left, screens: screens), 1)
        XCTAssertEqual(SnapMath.neighborScreen(from: 0, direction: .right, screens: screens), 2)
        XCTAssertEqual(SnapMath.neighborScreen(from: 0, direction: .up, screens: screens), 3)
        // Wrap: ← on the leftmost goes to the rightmost; → on the rightmost goes to the leftmost.
        XCTAssertEqual(SnapMath.neighborScreen(from: 1, direction: .left, screens: screens), 2)
        XCTAssertEqual(SnapMath.neighborScreen(from: 2, direction: .right, screens: screens), 1)
        XCTAssertNil(SnapMath.neighborScreen(from: 0, direction: .left, screens: [a]))
    }

    func testBestScreen() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let b = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(SnapMath.bestScreen(for: CGRect(x: 900, y: 0, width: 400, height: 400), screens: [a, b]), 1)
        XCTAssertEqual(SnapMath.bestScreen(for: CGRect(x: 5000, y: 0, width: 10, height: 10), screens: [a, b]), 1)
    }

    func testRelativeRoundTripAndScaling() {
        let desk = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        let win = CGRect(x: 1280, y: 25, width: 1280, height: 1415)
        let rel = SnapMath.relative(win, in: desk)
        XCTAssertEqual(SnapMath.absolute(rel, in: desk), win)
        // Same window on a smaller laptop screen keeps "right half".
        let laptop = CGRect(x: 0, y: 38, width: 1512, height: 944)
        XCTAssertEqual(SnapMath.absolute(rel, in: laptop), CGRect(x: 756, y: 38, width: 756, height: 944))
    }

    func testClampKeepsWindowOnScreen() {
        let s = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SnapMath.clamp(CGRect(x: 900, y: 700, width: 300, height: 200), to: s),
                       CGRect(x: 700, y: 600, width: 300, height: 200))
    }
}

final class WindowMatcherTests: XCTestCase {
    func testTitleMatchingHandlesMultipleWindowsOfOneApp() {
        let saved = ["Inbox", "Project Plan.docx", "Untitled"]
        let current = ["Untitled", "Inbox (3)", "Project Plan.docx"]
        let m = WindowMatcher.matchByTitle(saved: saved, current: current)
        XCTAssertEqual(m[0], 1)   // fuzzy
        XCTAssertEqual(m[1], 2)   // exact
        XCTAssertEqual(m[2], 0)   // exact
    }

    func testTitleMatchingFallsBackToOrder() {
        let m = WindowMatcher.matchByTitle(saved: ["a", "b"], current: ["x", "y", "z"])
        XCTAssertEqual(m, [0: 0, 1: 1])
    }

    func testTabMatchingPicksBestOverlap() {
        let saved = [
            ["https://mail.google.com/", "https://calendar.google.com/"],
            ["https://github.com/a", "https://github.com/b", "https://docs.swift.org"],
            ["https://news.ycombinator.com"],
        ]
        let current = [
            ["https://github.com/a/", "https://github.com/b#readme"],       // window 1, slightly changed
            ["https://mail.google.com", "https://calendar.google.com", "https://x.com"],
            ["chrome://newtab/"],
        ]
        let m = WindowMatcher.matchByTabs(saved: saved, current: current)
        XCTAssertEqual(m[0], 1)
        XCTAssertEqual(m[1], 0)
        XCTAssertNil(m[2])   // not open → caller recreates it
    }

    func testBlankTabs() {
        XCTAssertTrue(WindowMatcher.isBlankTab("chrome://newtab/"))
        XCTAssertTrue(WindowMatcher.isBlankTab("favorites://"))
        XCTAssertFalse(WindowMatcher.isBlankTab("https://example.com"))
    }
}

final class VisibilityTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func testUncoveredWindowIsFullyVisible() {
        XCTAssertEqual(SnapMath.visibleFraction(of: CGRect(x: 0, y: 0, width: 500, height: 500),
                                                coveredBy: [], screens: [screen]), 1)
    }

    func testWindowBuriedBehindAnotherIsHidden() {
        let back = CGRect(x: 100, y: 100, width: 400, height: 400)
        XCTAssertEqual(SnapMath.visibleFraction(of: back, coveredBy: [screen], screens: [screen]), 0)
    }

    func testHalfCoveredWindow() {
        let back = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let front = CGRect(x: 0, y: 0, width: 500, height: 1000)
        XCTAssertEqual(SnapMath.visibleFraction(of: back, coveredBy: [front], screens: [screen]), 0.5)
    }
}

final class DragZoneTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 2056, height: 1329)

    func testEdgesAndCorners() {
        XCTAssertEqual(DragZones.zone(for: CGPoint(x: 0, y: 600), in: screen), .left)
        XCTAssertEqual(DragZones.zone(for: CGPoint(x: 2055, y: 600), in: screen), .right)
        XCTAssertEqual(DragZones.zone(for: CGPoint(x: 1000, y: 0), in: screen), .maximize)
        XCTAssertEqual(DragZones.zone(for: CGPoint(x: 0, y: 10), in: screen), .topLeft)
        XCTAssertEqual(DragZones.zone(for: CGPoint(x: 2030, y: 0), in: screen), .topRight)
        XCTAssertEqual(DragZones.zone(for: CGPoint(x: 0, y: 1328), in: screen), .bottomLeft)
        XCTAssertEqual(DragZones.zone(for: CGPoint(x: 2055, y: 1300), in: screen), .bottomRight)
        XCTAssertNil(DragZones.zone(for: CGPoint(x: 1000, y: 1328), in: screen))   // bottom middle (Dock)
        XCTAssertNil(DragZones.zone(for: CGPoint(x: 1000, y: 600), in: screen))
    }

    func testZoneRects() {
        let visible = CGRect(x: 0, y: 39, width: 2056, height: 1290)
        XCTAssertEqual(DragZones.rect(for: .left, in: visible), CGRect(x: 0, y: 39, width: 1028, height: 1290))
        XCTAssertEqual(DragZones.rect(for: .maximize, in: visible), visible)
        XCTAssertEqual(DragZones.rect(for: .bottomRight, in: visible), CGRect(x: 1028, y: 684, width: 1028, height: 645))
    }
}

final class GapFillTests: XCTestCase {
    let screen = CGRect(x: 0, y: 39, width: 2056, height: 1290)

    func testFillsGapBetweenTopAndBottomWindows() {
        // Your screenshot: dashboard across the top, Teams across the bottom, wallpaper between.
        let dashboard = CGRect(x: 0, y: 39, width: 2056, height: 600)
        let teams = CGRect(x: 0, y: 1000, width: 2056, height: 329)
        XCTAssertEqual(GapFill.fill(teams, others: [dashboard], screen: screen),
                       CGRect(x: 0, y: 639, width: 2056, height: 690))
    }

    func testFillsMiddleOfUltrawide() {
        let wide = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        let leftApp = CGRect(x: 0, y: 0, width: 1700, height: 1440)
        let rightApp = CGRect(x: 3400, y: 0, width: 1720, height: 1440)
        XCTAssertEqual(GapFill.fill(rightApp, others: [leftApp], screen: wide),
                       CGRect(x: 1700, y: 0, width: 3420, height: 1440))
    }

    func testSmallWindowFillsTheHoleItSitsIn() {
        // Windows on the left and across the top; a small window in the empty bottom-right area.
        let left = CGRect(x: 0, y: 39, width: 800, height: 1290)
        let top = CGRect(x: 800, y: 39, width: 1256, height: 500)
        let small = CGRect(x: 1200, y: 800, width: 400, height: 300)
        XCTAssertEqual(GapFill.fill(small, others: [left, top], screen: screen),
                       CGRect(x: 800, y: 539, width: 1256, height: 790))
    }

    func testTallMonitorSlackBetweenChromeAndTeams() {
        // Your tall monitor: Chrome on top, Teams at the bottom, Slack in between overlapping the
        // top of Teams a little. Slack should fit exactly between them, not cover Teams.
        let tall = CGRect(x: 3440, y: -1160, width: 1440, height: 3440)
        let chrome = CGRect(x: 3440, y: -1130, width: 1440, height: 1137)   // ends at y 7
        let teams = CGRect(x: 3440, y: 1143, width: 1440, height: 1137)     // starts at y 1143
        let slack = CGRect(x: 3500, y: 300, width: 1300, height: 900)       // ends at y 1200 (over Teams)
        XCTAssertEqual(GapFill.fill(slack, others: [chrome, teams], screen: tall),
                       CGRect(x: 3440, y: 7, width: 1440, height: 1136))
    }

    func testWindowInsideOrBehindIsIgnored() {
        // A small window sitting on top of ours (fully inside) doesn't shrink us.
        let w = CGRect(x: 0, y: 600, width: 1000, height: 600)
        let inside = CGRect(x: 300, y: 800, width: 300, height: 200)
        XCTAssertEqual(GapFill.fill(w, others: [inside], screen: screen), screen)
    }

    func testNothingToFill() {
        let full = screen
        XCTAssertNil(GapFill.fill(full, others: [], screen: screen))
    }

    func testWindowBehindDoesNotBlock() {
        // A big window behind (overlapping, not beside) isn't in the way.
        let w = CGRect(x: 0, y: 1000, width: 2056, height: 329)
        let behind = CGRect(x: 0, y: 39, width: 2056, height: 1290)
        let top = CGRect(x: 0, y: 39, width: 2056, height: 500)
        XCTAssertEqual(GapFill.fill(w, others: [behind, top], screen: screen)?.minY, 539)
    }
}
