import AppKit
import Carbon.HIToolbox
import SnapCore

/// Everything a shortcut can trigger.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case snapLeft, snapRight, snapUp, snapDown, maximize, fillGap
    case layout1, layout2, layout3, layout4, layout5, layout6, layout7, layout8, layout9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snapLeft: return "Snap left"
        case .snapRight: return "Snap right"
        case .snapUp: return "Snap up"
        case .snapDown: return "Snap down"
        case .maximize: return "Maximize"
        case .fillGap: return "Fill the gap"
        default: return "Restore layout \(layoutIndex! + 1)"
        }
    }

    var direction: Direction? {
        switch self {
        case .snapLeft: return .left
        case .snapRight: return .right
        case .snapUp: return .up
        case .snapDown: return .down
        default: return nil
        }
    }

    /// 0-based saved-layout slot for layout1…layout9.
    var layoutIndex: Int? {
        let all: [ShortcutAction] = [.layout1, .layout2, .layout3, .layout4, .layout5, .layout6, .layout7, .layout8, .layout9]
        return all.firstIndex(of: self)
    }
}

/// A key combo. Either a normal key with modifiers (⌥⌘←), or "modifier-only": a modifier key
/// pressed while others are held (⌥⌘ + right ⇧).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt          // NSEvent.ModifierFlags raw value (⌃⌥⇧⌘ only)
    var label: String            // what to show for the key: "←", "1", "Right ⇧"
    var modifierOnly = false

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    var display: String {
        var f = flags
        if modifierOnly, let own = ModifierKey.byKeyCode[keyCode] { f.remove(own.flag) }
        let symbols = Self.symbols(f)
        return modifierOnly ? "\(symbols) + \(label)" : symbols + label
    }

    static func symbols(_ f: NSEvent.ModifierFlags) -> String {
        (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") +
            (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
    }

    var carbonModifiers: Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    // MARK: Defaults (what the app shipped with)

    static let defaults: [ShortcutAction: Shortcut] = {
        let cmdOpt = NSEvent.ModifierFlags([.command, .option]).rawValue
        var d: [ShortcutAction: Shortcut] = [
            .snapLeft: Shortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: cmdOpt, label: "←"),
            .snapRight: Shortcut(keyCode: UInt16(kVK_RightArrow), modifiers: cmdOpt, label: "→"),
            .snapUp: Shortcut(keyCode: UInt16(kVK_UpArrow), modifiers: cmdOpt, label: "↑"),
            .snapDown: Shortcut(keyCode: UInt16(kVK_DownArrow), modifiers: cmdOpt, label: "↓"),
            .maximize: Shortcut(keyCode: UInt16(kVK_RightShift),
                                modifiers: NSEvent.ModifierFlags([.command, .option, .shift]).rawValue,
                                label: "Right ⇧", modifierOnly: true),
            .fillGap: Shortcut(keyCode: UInt16(kVK_ANSI_Slash), modifiers: cmdOpt, label: "/"),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for action in ShortcutAction.allCases {
            if let i = action.layoutIndex {
                d[action] = Shortcut(keyCode: UInt16(digits[i]), modifiers: cmdOpt, label: "\(i + 1)")
            }
        }
        return d
    }()

    /// Readable name for a non-modifier key.
    static func label(for event: NSEvent) -> String {
        let names: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ANSI_KeypadEnter: "⌤",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let n = names[Int(event.keyCode)] { return n }
        let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return chars.uppercased()
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            .contains(Int(keyCode))
    }
}

/// The physical modifier keys, so we can tell left ⇧ from right ⇧.
struct ModifierKey {
    let flag: NSEvent.ModifierFlags
    let deviceMask: UInt      // NX_DEVICE*KEYMASK: set while this specific key is down
    let name: String

    static let byKeyCode: [UInt16: ModifierKey] = [
        UInt16(kVK_Shift): ModifierKey(flag: .shift, deviceMask: 0x02, name: "Left ⇧"),
        UInt16(kVK_RightShift): ModifierKey(flag: .shift, deviceMask: 0x04, name: "Right ⇧"),
        UInt16(kVK_Control): ModifierKey(flag: .control, deviceMask: 0x01, name: "Left ⌃"),
        UInt16(kVK_RightControl): ModifierKey(flag: .control, deviceMask: 0x2000, name: "Right ⌃"),
        UInt16(kVK_Option): ModifierKey(flag: .option, deviceMask: 0x20, name: "Left ⌥"),
        UInt16(kVK_RightOption): ModifierKey(flag: .option, deviceMask: 0x40, name: "Right ⌥"),
        UInt16(kVK_Command): ModifierKey(flag: .command, deviceMask: 0x08, name: "Left ⌘"),
        UInt16(kVK_RightCommand): ModifierKey(flag: .command, deviceMask: 0x10, name: "Right ⌘"),
    ]

    /// True if this flagsChanged event is the key going down (not up).
    static func isPress(_ event: NSEvent) -> Bool {
        guard let key = byKeyCode[event.keyCode] else { return false }
        return event.modifierFlags.rawValue & key.deviceMask != 0
    }
}

/// User's shortcut choices + other settings, saved in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published private(set) var shortcuts: [ShortcutAction: Shortcut]
    /// While true, global shortcuts are switched off so the recorder can see the keys.
    @Published var isRecording = false { didSet { onChange?() } }
    @Published var dragToSnap: Bool { didSet { UserDefaults.standard.set(dragToSnap, forKey: "dragToSnap") } }
    /// Drag preview style: simple (grey glass card, the default) or fancy (edge fade to black).
    @Published var fancyPreview: Bool { didSet { UserDefaults.standard.set(fancyPreview, forKey: "fancyPreview") } }

    /// Called whenever shortcuts need re-registering.
    var onChange: (() -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "shortcuts"),
           let saved = try? JSONDecoder().decode([String: Shortcut?].self, from: data) {
            var s: [ShortcutAction: Shortcut] = [:]
            for action in ShortcutAction.allCases {
                // Missing from the saved file → default; explicitly cleared (nil) → none.
                if let entry = saved[action.rawValue] { if let sc = entry { s[action] = sc } } else { s[action] = Shortcut.defaults[action] }
            }
            shortcuts = s
        } else {
            shortcuts = Shortcut.defaults
        }
        dragToSnap = UserDefaults.standard.object(forKey: "dragToSnap") as? Bool ?? true
        fancyPreview = UserDefaults.standard.object(forKey: "fancyPreview") as? Bool ?? false   // Simple by default
    }

    func set(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        if let shortcut {
            // One combo can only do one thing: take it away from whatever had it.
            for (other, sc) in shortcuts where other != action && sc == shortcut { shortcuts[other] = nil }
        }
        shortcuts[action] = shortcut
        persist()
        onChange?()
    }

    func resetToDefaults() {
        shortcuts = Shortcut.defaults
        persist()
        onChange?()
    }

    private func persist() {
        var out: [String: Shortcut?] = [:]
        for action in ShortcutAction.allCases { out[action.rawValue] = shortcuts[action] }
        if let data = try? JSONEncoder().encode(out) { UserDefaults.standard.set(data, forKey: "shortcuts") }
    }
}

/// Watches modifier-only shortcuts (like ⌥⌘ + right ⇧). Needs Accessibility permission.
final class ModifierShortcutMonitor {
    var bindings: [(Shortcut, () -> Void)] = []
    private var global: Any?
    private var local: Any?

    func start() {
        guard global == nil else { return }
        let check: (NSEvent) -> Void = { [weak self] event in
            guard let self, ModifierKey.isPress(event) else { return }
            let flags = event.modifierFlags.intersection(Shortcut.relevant)
            for (sc, action) in self.bindings where sc.keyCode == event.keyCode && sc.flags == flags {
                action()
            }
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: check)
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { check($0); return $0 }
    }
}
