import AppKit
import SnapCore

/// An app that currently has visible windows (what the Save screen lists).
struct LiveApp: Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let icon: NSImage?
    var windows: [SavedWindow]
    /// At least one window is on this desktop and not buried behind other windows.
    var isVisible: Bool
}

/// Captures and restores window layouts.
enum LayoutEngine {
    private static let queue = DispatchQueue(label: "WindowSnapper.restore")

    // MARK: Capture

    /// Regular apps that aren't hidden and have at least one on-screen, non-minimized window.
    /// Must be called on the main thread.
    static func snapshot() -> [LiveApp] {
        guard AX.isTrusted else { return [] }
        let screens = LiveScreen.all()
        let me = ProcessInfo.processInfo.processIdentifier
        let seen = visiblePIDs(excluding: me, screens: screens.map(\.frame))
        var byBundle: [String: LiveApp] = [:]

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && app.processIdentifier != me {
            guard let bundleID = app.bundleIdentifier else { continue }
            let ax = AX.appElement(app.processIdentifier)
            let windows: [SavedWindow] = AX.standardWindows(ax, includeMinimized: false).compactMap { w in
                guard let f = AX.frame(of: w), f.width >= 80, f.height >= 60 else { return nil }
                return savedWindow(title: AX.string(w, kAXTitleAttribute) ?? "", frame: f, screens: screens)
            }
            guard !windows.isEmpty else { continue }
            let visible = seen.contains(app.processIdentifier)
            if byBundle[bundleID] != nil {
                byBundle[bundleID]!.windows += windows
                byBundle[bundleID]!.isVisible = byBundle[bundleID]!.isVisible || visible
            } else {
                byBundle[bundleID] = LiveApp(bundleID: bundleID, name: app.localizedName ?? bundleID,
                                             icon: app.icon, windows: windows, isVisible: visible)
            }
        }
        // Visible apps first, then the ones hiding behind them; alphabetical within each.
        return byBundle.values.sorted {
            $0.isVisible != $1.isVisible ? $0.isVisible
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Apps with at least one window the user can actually see right now: on the current
    /// desktop and at least 10% uncovered by the windows stacked in front of it.
    private static func visiblePIDs(excluding me: pid_t, screens: [CGRect]) -> Set<pid_t> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var inFront: [CGRect] = []   // the list is ordered front to back
        var result = Set<pid_t>()
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 80, bounds.height >= 60 else { continue }
            if SnapMath.visibleFraction(of: bounds, coveredBy: inFront, screens: screens) >= 0.1 {
                result.insert(pid)
            }
            inFront.append(bounds)
        }
        return result
    }

    /// Turns the chosen apps into a layout. Browsers get their tabs captured too.
    /// Must be called on the main thread.
    static func makeLayout(name: String, apps: [LiveApp]) -> WindowLayout {
        let screens = LiveScreen.all()
        let saved: [SavedApp] = apps.map { app in
            var windows = app.windows
            if Browsers.kind(for: app.bundleID) != nil, let live = Browsers.windows(app.bundleID), !live.isEmpty {
                windows = live.map {
                    savedWindow(title: $0.title, frame: $0.bounds, screens: screens,
                                tabs: $0.urls, activeTab: $0.activeTab)
                }
            }
            return SavedApp(bundleID: app.bundleID, name: app.name, windows: windows)
        }
        return WindowLayout(name: name,
                      screens: screens.map { SavedScreen(id: $0.id, name: $0.name, frame: $0.visible) },
                      apps: saved)
    }

    private static func savedWindow(title: String, frame: CGRect, screens: [LiveScreen],
                                     tabs: [String]? = nil, activeTab: Int? = nil) -> SavedWindow {
        let i = SnapMath.bestScreen(for: frame, screens: screens.map(\.frame)) ?? 0
        let s = screens[i]
        return SavedWindow(title: title, frame: frame, screenID: s.id, screenName: s.name,
                           relativeFrame: SnapMath.relative(frame, in: s.visible),
                           tabs: tabs, activeTab: activeTab)
    }

    // MARK: Restore

    /// Launches missing apps, then puts every saved window back. Only apps marked `enabled`.
    static func restore(_ layout: WindowLayout, completion: @escaping (String) -> Void) {
        guard AX.isTrusted else { AX.promptForTrust(); completion("Needs Accessibility permission."); return }
        let screens = LiveScreen.all()
        let apps = layout.apps.filter(\.enabled)

        queue.async {
            var launched = Set<String>()
            var notInstalled: [String] = []

            // 1. Launch everything that isn't running, all at once.
            for app in apps where running(app.bundleID) == nil {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
                    notInstalled.append(app.name); continue
                }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
                launched.insert(app.bundleID)
            }

            // 2. Position each app's windows.
            var placed = 0
            var placements: [Placement] = []
            for app in apps {
                guard let runningApp = waitFor(timeout: 15, { running(app.bundleID) }) else { continue }
                if runningApp.isHidden { runningApp.unhide() }
                let wasLaunched = launched.contains(app.bundleID)

                let hasTabs = !app.windows.isEmpty && app.windows.allSatisfy { $0.tabs != nil }
                if hasTabs, Browsers.kind(for: app.bundleID) != nil,
                   let n = restoreBrowser(app, screens: screens, launched: wasLaunched) {
                    placed += n
                } else {
                    let p = restoreGeneric(app, runningApp, screens: screens, launched: wasLaunched)
                    placed += p.count
                    placements += p
                }
            }

            // 3. Some apps (especially ones we just launched) move their windows back to where
            //    they remember a moment later. Check twice and put those back again.
            for delay in [1.0, 2.0] where !placements.isEmpty {
                Thread.sleep(forTimeInterval: delay)
                for p in placements {
                    guard let now = AX.frame(of: p.window),
                          !SnapMath.approximatelyEqual(now, p.result) else { continue }
                    p.apply()
                }
            }

            var summary = "Restored \(placed) window\(placed == 1 ? "" : "s") in “\(layout.name)”."
            if !notInstalled.isEmpty { summary += " Not installed: \(notInstalled.joined(separator: ", "))." }
            DispatchQueue.main.async { completion(summary) }
        }
    }

    /// Where a saved window should go on the displays connected right now. Same display (by
    /// UUID, then by name) if it's connected, otherwise the main display — scaled to fit.
    static func targetFrame(_ w: SavedWindow, screens: [LiveScreen]) -> CGRect {
        SnapMath.absolute(w.relativeFrame, in: targetScreen(w, screens: screens).visible)
    }

    static func targetScreen(_ w: SavedWindow, screens: [LiveScreen]) -> LiveScreen {
        screens.first { $0.id == w.screenID }
            ?? screens.first { $0.name == w.screenName }
            ?? screens[0]
    }

    /// One window we moved, and how to move it there again.
    private final class Placement {
        let window: AXUIElement
        let saved: SavedWindow
        let screens: [LiveScreen]
        var result = CGRect.zero   // where it actually ended up

        init(window: AXUIElement, saved: SavedWindow, screens: [LiveScreen]) {
            self.window = window; self.saved = saved; self.screens = screens
        }

        func apply() {
            let visible = LayoutEngine.targetScreen(saved, screens: screens).visible
            let rel = saved.relativeFrame
            // A window saved against the right/bottom edge stays there even if the app won't
            // take the exact size (e.g. Outlook's minimum height).
            result = AX.setFrame(window, LayoutEngine.targetFrame(saved, screens: screens), inside: visible,
                                 anchorRight: rel.maxX >= 0.99, anchorBottom: rel.maxY >= 0.99)
        }
    }

    private static func restoreGeneric(_ app: SavedApp, _ runningApp: NSRunningApplication,
                                       screens: [LiveScreen], launched: Bool) -> [Placement] {
        let ax = AX.appElement(runningApp.processIdentifier)
        let needed = app.windows.count
        func list() -> [AXUIElement] { AX.standardWindows(ax, includeMinimized: true) }

        var windows = list()
        if launched {
            windows = waitForWindows(needed: needed, timeout: 12, list)
            // Freshly launched apps often restore their own window frames right after the
            // window appears; let that happen first so it doesn't undo ours.
            Thread.sleep(forTimeInterval: 1.0)
            windows = list()
        } else if windows.isEmpty {
            // Running with no windows (e.g. Finder, Mail): a "reopen" makes most apps open one.
            if let url = runningApp.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            }
            windows = waitForWindows(needed: needed, timeout: 4, list)
        }

        let mapping = WindowMatcher.matchByTitle(saved: app.windows.map(\.title),
                                                 current: windows.map { AX.string($0, kAXTitleAttribute) ?? "" })
        return mapping.sorted { $0.key < $1.key }.map { savedIndex, currentIndex in
            let p = Placement(window: windows[currentIndex], saved: app.windows[savedIndex], screens: screens)
            AX.unminimize(p.window)
            p.apply()
            return p
        }
    }

    /// Returns nil if AppleScript isn't available (permission denied), so the caller falls back
    /// to plain window positioning.
    private static func restoreBrowser(_ app: SavedApp, screens: [LiveScreen], launched: Bool) -> Int? {
        let id = app.bundleID
        var current = Browsers.windows(id)
        if launched {
            // Give the browser time to start and restore its own session.
            var lastCount = -1
            var stableSince = Date()
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                current = Browsers.windows(id)
                let count = current?.count ?? -1
                if count >= app.windows.count { break }
                if count != lastCount { lastCount = count; stableSince = Date() }
                if count > 0 && Date().timeIntervalSince(stableSince) > 2.5 { break }
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        guard let live = current else { return nil }

        let mapping = WindowMatcher.matchByTabs(saved: app.windows.map { $0.tabs ?? [] },
                                                current: live.map(\.urls))
        var placed = 0
        for (i, saved) in app.windows.enumerated() {
            let target = targetFrame(saved, screens: screens)
            if let c = mapping[i] {
                Browsers.setBounds(id, windowID: live[c].id, target)
                placed += 1
            } else if let tabs = saved.tabs, !tabs.isEmpty,
                      let newID = Browsers.createWindow(id, urls: tabs, activeTab: saved.activeTab) {
                Browsers.setBounds(id, windowID: newID, target)
                placed += 1
            }
        }
        // If we started the browser and it opened an empty "New Tab" window, tidy it away.
        if launched {
            let used = Set(mapping.values)
            for (i, w) in live.enumerated() where !used.contains(i) && w.urls.allSatisfy(WindowMatcher.isBlankTab) {
                Browsers.close(id, windowID: w.id)
            }
        }
        return placed
    }

    // MARK: Helpers

    private static func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    private static func waitFor<T>(timeout: TimeInterval, _ probe: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let v = probe() { return v }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return probe()
    }

    /// Waits until the app has `needed` windows, or its window count stops changing.
    private static func waitForWindows(needed: Int, timeout: TimeInterval,
                                       _ list: () -> [AXUIElement]) -> [AXUIElement] {
        var windows = list()
        var lastCount = windows.count
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while windows.count < needed && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            windows = list()
            if windows.count != lastCount { lastCount = windows.count; stableSince = Date() }
            if !windows.isEmpty && Date().timeIntervalSince(stableSince) > 2.5 { break }
        }
        return windows
    }
}
