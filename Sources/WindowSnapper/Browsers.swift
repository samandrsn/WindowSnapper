import AppKit

/// Browser windows are identified by their tabs, not their titles, so for browsers we use
/// AppleScript to read each window's tab URLs and to recreate windows that aren't open.
/// macOS will ask once per browser for permission ("WindowSnapper wants to control Chrome").
enum Browsers {
    enum Kind { case chromium, safari }

    struct Window {
        let id: Int
        let bounds: CGRect   // AX coordinates (top-left origin) — same as AppleScript bounds
        let title: String
        let urls: [String]
        let activeTab: Int
    }

    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    static func kind(for bundleID: String) -> Kind? {
        if chromium.contains(bundleID) { return .chromium }
        if bundleID == "com.apple.Safari" { return .safari }
        return nil
    }

    // Field separators that never appear in URLs or (realistically) titles.
    private static let RS = "\u{1E}", US = "\u{1F}", GS = "\u{1D}"

    /// All normal (non-private, non-minimized) windows with their tabs. nil if scripting failed
    /// (app not running, or the user denied automation permission).
    static func windows(_ bundleID: String) -> [Window]? {
        guard let kind = kind(for: bundleID) else { return nil }
        let filter: String
        let activeIndex: String
        switch kind {
        case .chromium:
            filter = "(mode of w) is not \"incognito\" and (minimized of w) is false and (visible of w) is true"
            activeIndex = "active tab index of w"
        case .safari:
            filter = "(visible of w) is true and (miniaturized of w) is false"
            activeIndex = "index of current tab of w"
        }
        let script = """
        set RS to character id 30
        set US to character id 31
        set GS to character id 29
        set out to {}
        tell application id "\(bundleID)"
            repeat with w in (every window)
                try
                    if \(filter) then
                        set b to bounds of w
                        set urls to {}
                        repeat with t in (tabs of w)
                            try
                                set end of urls to ((URL of t) as text)
                            on error
                                set end of urls to ""
                            end try
                        end repeat
                        set ai to 1
                        try
                            set ai to \(activeIndex)
                        end try
                        set AppleScript's text item delimiters to GS
                        set urlText to urls as text
                        set AppleScript's text item delimiters to ""
                        set end of out to ((id of w) as text) & US & ((item 1 of b) as text) & US & ((item 2 of b) as text) & US & ((item 3 of b) as text) & US & ((item 4 of b) as text) & US & (ai as text) & US & ((name of w) as text) & US & urlText
                    end if
                end try
            end repeat
        end tell
        set AppleScript's text item delimiters to RS
        set outText to out as text
        set AppleScript's text item delimiters to ""
        return outText
        """
        guard let text = run(script) else { return nil }
        return text.components(separatedBy: RS).compactMap { row in
            let f = row.components(separatedBy: US)
            guard f.count >= 8, let id = Int(f[0]),
                  let l = Double(f[1]), let t = Double(f[2]), let r = Double(f[3]), let b = Double(f[4]) else { return nil }
            let urls = f[7].components(separatedBy: GS).filter { !$0.isEmpty && $0 != "missing value" }
            return Window(id: id, bounds: CGRect(x: l, y: t, width: r - l, height: b - t),
                          title: f[6], urls: urls, activeTab: Int(f[5]) ?? 1)
        }
    }

    /// Opens a new window with these tabs. Returns its window id.
    static func createWindow(_ bundleID: String, urls: [String], activeTab: Int?) -> Int? {
        guard let kind = kind(for: bundleID), let first = urls.first else { return nil }
        let rest = urls.dropFirst().map { "make new tab at end of tabs of w with properties {URL:\(quote($0))}" }
            .joined(separator: "\n        ")
        let active = max(1, min(activeTab ?? 1, urls.count))
        let body: String
        switch kind {
        case .chromium:
            body = """
                set w to make new window
                set URL of active tab of w to \(quote(first))
                \(rest)
                try
                    set active tab index of w to \(active)
                end try
            """
        case .safari:
            body = """
                make new document with properties {URL:\(quote(first))}
                set w to front window
                \(rest)
                try
                    set current tab of w to tab \(active) of w
                end try
            """
        }
        let script = """
        tell application id "\(bundleID)"
        \(body)
            return (id of w) as text
        end tell
        """
        return run(script).flatMap { Int($0) }
    }

    static func setBounds(_ bundleID: String, windowID: Int, _ r: CGRect) {
        let b = "{\(Int(r.minX)), \(Int(r.minY)), \(Int(r.maxX)), \(Int(r.maxY))}"
        _ = run("""
        tell application id "\(bundleID)"
            set bounds of window id \(windowID) to \(b)
        end tell
        """)
    }

    static func close(_ bundleID: String, windowID: Int) {
        _ = run("tell application id \"\(bundleID)\" to close window id \(windowID)")
    }

    // MARK: -

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// NSAppleScript isn't thread-safe, so always run it on the main thread.
    private static func run(_ source: String) -> String? {
        let work = { () -> String? in
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return nil }
            let result = script.executeAndReturnError(&error)
            if let error {
                NSLog("WindowSnapper AppleScript error: \(error)")
                return nil
            }
            return result.stringValue ?? ""
        }
        return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
