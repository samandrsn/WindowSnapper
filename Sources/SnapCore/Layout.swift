import CoreGraphics
import Foundation

/// A display as it existed when a layout was saved.
public struct SavedScreen: Codable, Hashable {
    public var id: String          // display UUID (stable across reboots)
    public var name: String        // e.g. "Built-in Retina Display", "DELL U2720Q"
    public var frame: CGRect       // visible frame, AX coordinates

    public init(id: String, name: String, frame: CGRect) {
        self.id = id; self.name = name; self.frame = frame
    }
}

/// One window of one app.
public struct SavedWindow: Codable, Hashable {
    public var title: String
    public var frame: CGRect              // absolute frame at save time (AX coordinates)
    public var screenID: String
    public var screenName: String
    public var relativeFrame: CGRect      // frame as fractions of that screen's visible frame
    public var tabs: [String]?            // browsers only: tab URLs, in order
    public var activeTab: Int?            // browsers only: 1-based index of the selected tab

    public init(title: String, frame: CGRect, screenID: String, screenName: String,
                relativeFrame: CGRect, tabs: [String]? = nil, activeTab: Int? = nil) {
        self.title = title; self.frame = frame; self.screenID = screenID
        self.screenName = screenName; self.relativeFrame = relativeFrame
        self.tabs = tabs; self.activeTab = activeTab
    }
}

public struct SavedApp: Codable, Hashable, Identifiable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var enabled: Bool              // whether "Restore" touches this app
    public var windows: [SavedWindow]

    public init(bundleID: String, name: String, enabled: Bool = true, windows: [SavedWindow]) {
        self.bundleID = bundleID; self.name = name; self.enabled = enabled; self.windows = windows
    }
}

public struct WindowLayout: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var savedAt: Date
    public var screens: [SavedScreen]
    public var apps: [SavedApp]

    public init(id: UUID = UUID(), name: String, savedAt: Date = Date(),
                screens: [SavedScreen], apps: [SavedApp]) {
        self.id = id; self.name = name; self.savedAt = savedAt
        self.screens = screens; self.apps = apps
    }

    public var windowCount: Int { apps.reduce(0) { $0 + $1.windows.count } }
}
