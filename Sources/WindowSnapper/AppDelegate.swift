import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SnapCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let snapper = Snapper()
    private let modifierShortcuts = ModifierShortcutMonitor()
    private let dragSnapper = DragSnapper()
    private lazy var layoutsWindow = LayoutsWindowController()
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Settings.shared.onChange = { [weak self] in self?.applyShortcuts() }
        applyShortcuts()
        dragSnapper.isEnabled = { Settings.shared.dragToSnap }
        dragSnapper.onSnap = { [weak self] window, state, screen in self?.snapper.place(window, state, on: screen) }

        // `open WindowSnapper.app --args --show-layouts` opens the Layouts window on launch.
        if CommandLine.arguments.contains("--show-layouts") {
            DispatchQueue.main.async { self.layoutsWindow.show(.save) }
        }
        // `--show general|shortcuts|about|save|layout` opens that page on launch.
        if let i = CommandLine.arguments.firstIndex(of: "--show"), i + 1 < CommandLine.arguments.count {
            let pages: [String: Pane] = ["general": .general, "shortcuts": .shortcuts, "about": .about, "save": .save]
            var pane = pages[CommandLine.arguments[i + 1]]
            if CommandLine.arguments[i + 1] == "layout", let first = LayoutStore.shared.layouts.first {
                pane = .layout(first.id)
            }
            if let pane {
                DispatchQueue.main.async { self.layoutsWindow.show(pane) }
            }
        }
        // `--restore <name>` restores a saved layout on launch (handy for scripts/testing).
        if let i = CommandLine.arguments.firstIndex(of: "--restore"), i + 1 < CommandLine.arguments.count,
           let layout = LayoutStore.shared.layout(named: CommandLine.arguments[i + 1]) {
            LayoutEngine.restore(layout) { summary in NSLog("WindowSnapper: \(summary)") }
        }

        if AX.isTrusted {
            startTrustedMonitors()
        } else {
            AX.promptForTrust()
            // Wait for the user to flip the switch in System Settings, then finish setup.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard AX.isTrusted, let self else { return }
                timer.invalidate()
                self.startTrustedMonitors()
            }
        }
    }

    /// The app icon's motif as a monochrome menu bar glyph: a screen with the left half and
    /// the top-right corner filled, bottom-right quarter outlined.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let screen = NSRect(x: 1.5, y: 3, width: 15, height: 12)
            let outline = NSBezierPath(roundedRect: screen, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.3
            NSColor.black.setStroke()
            outline.stroke()
            NSColor.black.setFill()
            let inner = screen.insetBy(dx: 2, dy: 2)
            let gap: CGFloat = 1.5
            let halfW = (inner.width - gap) / 2, halfH = (inner.height - gap) / 2
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: halfW, height: inner.height),
                         xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: inner.maxX - halfW, y: inner.minY, width: halfW, height: halfH),
                         xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "WindowSnapper"
        return image
    }

    /// These need Accessibility permission, so they start once it's granted.
    private func startTrustedMonitors() {
        modifierShortcuts.start()
        dragSnapper.start()
    }

    /// (Re)registers every shortcut from Settings. Called at launch and whenever they change.
    private func applyShortcuts() {
        HotKeys.shared.unregisterAll()
        modifierShortcuts.bindings = []
        // While the user is recording a new shortcut, everything is off so the keys reach the recorder.
        guard !Settings.shared.isRecording else { return }
        for (action, shortcut) in Settings.shared.shortcuts {
            let run = { [weak self] in self?.perform(action) ?? () }
            if shortcut.modifierOnly {
                modifierShortcuts.bindings.append((shortcut, run))
            } else {
                HotKeys.shared.register(keyCode: Int(shortcut.keyCode), modifiers: shortcut.carbonModifiers, run)
            }
        }
    }

    private func perform(_ action: ShortcutAction) {
        if let dir = action.direction {
            snapper.snap(dir)
        } else if action == .maximize {
            snapper.maximize()
        } else if let i = action.layoutIndex {
            let layouts = LayoutStore.shared.layouts
            guard layouts.indices.contains(i) else { NSSound.beep(); return }
            LayoutEngine.restore(layouts[i]) { summary in NSLog("WindowSnapper: \(summary)") }
        }
    }

    // MARK: Menu (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Every item gets an icon so all the text lines up in one column (macOS adds icons to
        // some standard items on its own, which made the menu look ragged).
        if !AX.isTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibility), icon: "exclamationmark.triangle"))
            menu.addItem(.separator())
        }

        let layouts = LayoutStore.shared.layouts
        menu.addItem(header(layouts.isEmpty ? "No Saved Layouts" : "Restore Layout"))
        for (i, layout) in layouts.enumerated() {
            let enabled = layout.apps.filter(\.enabled).count
            let it = item(layout.name, #selector(restoreLayout(_:)), icon: "rectangle.3.group")
            // Show the layout's shortcut next to it when the menu can display that key.
            if i < 9, let action = ShortcutAction.allCases.first(where: { $0.layoutIndex == i }),
               let sc = Settings.shared.shortcuts[action], !sc.modifierOnly, sc.label.count == 1 {
                it.keyEquivalent = sc.label.lowercased()
                it.keyEquivalentModifierMask = sc.flags
            }
            it.representedObject = layout.id
            it.toolTip = "\(enabled) app\(enabled == 1 ? "" : "s"), \(windowCount(layout.windowCount))"
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(item("Save Current Layout…", #selector(saveLayout), key: "s", icon: "square.and.arrow.down"))
        menu.addItem(item("Manage Layouts…", #selector(manageLayouts), icon: "list.bullet.rectangle"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", icon: "gearshape"))
        menu.addItem(item("Quit WindowSnapper", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp, icon: "power"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil,
                      icon: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = target ?? self
        it.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        return it
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // MARK: Actions

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let layout = LayoutStore.shared.layouts.first(where: { $0.id == id }) else { return }
        LayoutEngine.restore(layout) { summary in NSLog("WindowSnapper: \(summary)") }
    }

    @objc private func saveLayout() { layoutsWindow.show(.save) }

    @objc private func manageLayouts() {
        if let first = LayoutStore.shared.layouts.first {
            layoutsWindow.show(.layout(first.id))
        } else {
            layoutsWindow.show(.save)
        }
    }

    @objc private func openSettings() { layoutsWindow.show(.general) }

    @objc private func openAccessibility() {
        AX.promptForTrust()
        AX.openAccessibilitySettings()
    }
}
