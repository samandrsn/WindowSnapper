import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility API, which is how we read and move other apps' windows.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow accessibility" prompt if we aren't trusted yet.
    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reading attributes

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        (copy(el, attr) as? [AXUIElement]) ?? []
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { copy(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { copy(el, attr) as? Bool }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let p = copy(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = copy(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: Moving windows

    /// - positionFirst: move, then resize. Right when growing a window in place (e.g. filling a
    ///   gap upward), where resizing first would be refused because it'd run off the screen.
    static func setFrame(_ window: AXUIElement, _ rect: CGRect, positionFirst: Bool = false) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = AXUIElementCreateApplication(pid)

        // Chrome/Electron/etc. turn on "enhanced UI" when assistive tech is present, which makes
        // them animate (and often fight) programmatic resizes. Turn it off while we move things.
        let enhanced = bool(app, "AXEnhancedUserInterface") == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        if positionFirst {
            setPosition(window, rect.origin)
            setSize(window, rect.size)
        } else {
            // size → position → size: the first resize lets a big window fit on a smaller target
            // display, the second one fixes sizes the app clamped against the old display.
            setSize(window, rect.size)
            setPosition(window, rect.origin)
            setSize(window, rect.size)
        }

        // Some apps (Chrome, Teams and other Electron apps) apply moves a beat late, so a resize
        // that arrives too soon gets clamped against the old position. If the window clearly
        // didn't end up where we asked, give it a moment and apply again. (Small differences are
        // normal — e.g. Terminal sizes in whole characters — and aren't retried.)
        for _ in 0..<4 {
            guard let f = frame(of: window), isClearlyOff(f, rect) else { break }
            usleep(40_000)
            setPosition(window, rect.origin)
            setSize(window, rect.size)
        }
    }

    private static func isClearlyOff(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > 12 || abs(a.minY - b.minY) > 12 ||
            abs(a.width - b.width) > 24 || abs(a.height - b.height) > 24
    }

    /// Sets the frame, then fixes up apps that won't take that size (e.g. Outlook has a minimum
    /// height): the window stays against the edges it was placed on and fully inside `bounds`.
    /// Returns the frame the window actually ended up with.
    @discardableResult
    static func setFrame(_ window: AXUIElement, _ rect: CGRect, inside bounds: CGRect,
                         anchorRight: Bool, anchorBottom: Bool) -> CGRect {
        setFrame(window, rect)
        guard let actual = frame(of: window) else { return rect }
        guard abs(actual.width - rect.width) > 2 || abs(actual.height - rect.height) > 2 else { return actual }

        var origin = rect.origin
        if anchorRight { origin.x = rect.maxX - actual.width }
        if anchorBottom { origin.y = rect.maxY - actual.height }
        let w = min(actual.width, bounds.width), h = min(actual.height, bounds.height)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - w)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - h)
        if abs(origin.x - actual.minX) > 1 || abs(origin.y - actual.minY) > 1 {
            setPosition(window, origin)
        }
        return frame(of: window) ?? CGRect(origin: origin, size: actual.size)
    }

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
    }

    static func unminimize(_ window: AXUIElement) {
        if bool(window, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    // MARK: Finding windows

    static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)   // never hang on a frozen app
        return app
    }

    /// The window the user is working in right now.
    static func focusedWindow() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = appElement(front.processIdentifier)
        if let w = element(app, kAXFocusedWindowAttribute) { return w }
        if let w = element(app, kAXMainWindowAttribute) { return w }
        return standardWindows(app, includeMinimized: false).first
    }

    /// The window under a point (AX coordinates), e.g. the one whose title bar was just clicked.
    static func window(at p: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success,
              let hit else { return nil }
        if string(hit, kAXRoleAttribute) == kAXWindowRole { return hit }
        return element(hit, kAXWindowAttribute)
    }

    /// Frames (AX coordinates) of the normal windows on screen right now, other than ours.
    static func otherWindowFrames() -> [CGRect] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d), r.width >= 60, r.height >= 60 else { return nil }
            return r
        }
    }

    // MARK: Coordinates (AX: top-left origin, y down. AppKit: bottom-left origin, y up.)

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func mouseLocation() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func appKitRect(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func appKitPoint(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight - p.y) }

    /// Normal document windows only — no sheets, palettes, popovers or tooltips.
    static func standardWindows(_ app: AXUIElement, includeMinimized: Bool) -> [AXUIElement] {
        elements(app, kAXWindowsAttribute).filter { w in
            let subrole = string(w, kAXSubroleAttribute)
            guard subrole == kAXStandardWindowSubrole || subrole == nil else { return false }
            if !includeMinimized && bool(w, kAXMinimizedAttribute) == true { return false }
            return true
        }
    }
}

/// Displays, converted from AppKit's bottom-left coordinates into AX top-left coordinates.
struct LiveScreen {
    let id: String
    let name: String
    let frame: CGRect     // whole display
    let visible: CGRect   // minus menu bar and Dock

    /// Must be called on the main thread.
    static func all() -> [LiveScreen] {
        guard let primary = NSScreen.screens.first else { return [] }
        let h = primary.frame.maxY
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { s in
            LiveScreen(id: displayUUID(s), name: s.localizedName, frame: flip(s.frame), visible: flip(s.visibleFrame))
        }
    }

    private static func displayUUID(_ screen: NSScreen) -> String {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue(),
              let str = CFUUIDCreateString(nil, uuid) as String? else { return screen.localizedName }
        return str
    }
}
