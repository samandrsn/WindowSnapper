import AppKit
import ServiceManagement
import Carbon.HIToolbox
import SwiftUI

/// Records the next key combo the user types for one action.
final class ShortcutRecorder: ObservableObject {
    @Published var recording: ShortcutAction?
    private var monitor: Any?
    private var candidate: Shortcut?   // a modifier-only combo, committed when all keys are released

    func start(_ action: ShortcutAction) {
        stop()
        recording = action
        candidate = nil
        Settings.shared.isRecording = true   // turns global shortcuts off so we receive the keys
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        candidate = nil
        if recording != nil { recording = nil; Settings.shared.isRecording = false }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let action = recording else { return event }
        let flags = event.modifierFlags.intersection(Shortcut.relevant)

        if event.type == .keyDown {
            if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty { stop(); return nil }   // cancel
            if flags.isEmpty && !Shortcut.isFunctionKey(event.keyCode) { NSSound.beep(); return nil }
            finish(action, Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue,
                                    label: Shortcut.label(for: event)))
            return nil
        }

        // flagsChanged: remember "modifier pressed while others held" (e.g. ⌥⌘ then right ⇧)…
        if ModifierKey.isPress(event), let key = ModifierKey.byKeyCode[event.keyCode] {
            candidate = flags.subtracting(key.flag).isEmpty ? nil
                : Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue, label: key.name, modifierOnly: true)
        }
        // …and use it once everything is let go without a normal key having been pressed.
        if flags.isEmpty, let c = candidate { finish(action, c) }
        return event
    }

    private func finish(_ action: ShortcutAction, _ shortcut: Shortcut) {
        stop()
        Settings.shared.set(action, shortcut)
    }
}

/// General: drag-to-snap, preview style, launch at login.
struct GeneralSettingsView: View {
    @ObservedObject var settings = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("General").font(.title2.bold())

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Snap windows by dragging them to a screen edge", isOn: $settings.dragToSnap)
                        Text("Left/right edge → half · top edge → maximize · corners → quarter")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Text("Preview style")
                            Picker("Preview style", selection: $settings.fancyPreview) {
                                Text("Simple").tag(false)
                                Text("Fancy").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 180)
                        }
                        .disabled(!settings.dragToSnap)
                        .padding(.top, 4)
                        Text(settings.fancyPreview
                             ? "Fancy: darkens and blurs toward the screen edge, fading to black."
                             : "Simple: a frosted glass card showing where the window will go.")
                            .font(.callout).foregroundStyle(.secondary)
                        if settings.dragToSnap && Self.macOSTilingIsOn {
                            HStack(alignment: .firstTextBaseline) {
                                Text("macOS's own “Drag windows to screen edges to tile” is also on, so both will react. Turn it off in Desktop & Dock.")
                                    .font(.callout).foregroundStyle(.orange)
                                Button("Open Desktop & Dock") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Launch WindowSnapper at login", isOn: Binding(
                            get: { launchAtLogin },
                            set: { setLaunchAtLogin($0) }))
                        if let loginError {
                            Text(loginError).font(.callout).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(20)
        }
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this. Make sure WindowSnapper is in /Applications. (\(error.localizedDescription))"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// macOS 15+ has its own edge tiling (on unless the user turned it off).
    static var macOSTilingIsOn: Bool {
        guard #available(macOS 15.0, *) else { return false }
        return UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
    }
}

/// Every keyboard shortcut, each one re-recordable.
struct ShortcutsSettingsView: View {
    @ObservedObject var settings = Settings.shared
    @StateObject private var recorder = ShortcutRecorder()

    private let snapActions: [ShortcutAction] = [.snapLeft, .snapRight, .snapUp, .snapDown, .maximize, .fillGap]
    private let layoutActions = ShortcutAction.allCases.filter { $0.layoutIndex != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Shortcuts").font(.title2.bold())
                Text("Click a shortcut, then type the new keys. Esc cancels. A modifier-only combo like ⌥⌘ + right ⇧ works too: hold the keys, then let go.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                section("Snapping", subtitle: "Pressing the same snap shortcut again cycles ½ → ⅓ → ¾ → ⅔ → next display. Two snaps in quick succession make a corner.",
                        actions: snapActions)
                section("Layouts", subtitle: "Restores the 1st, 2nd, … saved layout (the order in the sidebar).",
                        actions: layoutActions)

                HStack {
                    Spacer()
                    Button("Restore Defaults") { recorder.stop(); settings.resetToDefaults() }
                }
            }
            .padding(20)
        }
        .onDisappear { recorder.stop() }
    }

    private func section(_ title: String, subtitle: String, actions: [ShortcutAction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(actions) { action in
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutField(action: action, settings: settings, recorder: recorder)
                        }
                        .padding(.vertical, 4)
                        if action != actions.last { Divider() }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

/// App icon, version, and credit.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("WindowSnapper").font(.title.bold())
            Text(version).foregroundStyle(.secondary)
            Text("Made with love in Indy by Sam Anderson")
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

struct ShortcutField: View {
    let action: ShortcutAction
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        let isRecording = recorder.recording == action
        let shortcut = settings.shortcuts[action]
        HStack(spacing: 4) {
            Button {
                isRecording ? recorder.stop() : recorder.start(action)
            } label: {
                Text(isRecording ? "Type shortcut…" : (shortcut?.display ?? "Not set"))
                    .font(.body.monospaced())
                    .foregroundStyle(isRecording ? Color.accentColor : (shortcut == nil ? .secondary : .primary))
                    .frame(minWidth: 150)
            }
            Button {
                recorder.stop()
                settings.set(action, nil)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove shortcut")
            .opacity(shortcut == nil ? 0 : 1)
            .disabled(shortcut == nil)
        }
    }
}
