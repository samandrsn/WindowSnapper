import AppKit
import SnapCore
import SwiftUI

enum Pane: Hashable {
    case general
    case shortcuts
    case save
    case layout(UUID)
    case about
}

final class LayoutsModel: ObservableObject {
    @Published var selection: Pane = .general
    @Published var snapshot: [LiveApp] = []
    @Published var snapshotVersion = 0
    @Published var status = ""

    func refreshSnapshot() {
        snapshot = LayoutEngine.snapshot()
        snapshotVersion += 1
    }
}

/// The one window this app has: save the current windows as a layout, or manage saved ones.
final class LayoutsWindowController: NSWindowController {
    let model = LayoutsModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        // The window owns its size (SwiftUI sizing it to its content made it very tall and
        // un-resizable); the SwiftUI view just fills whatever size the window is.
        let host = NSHostingView(rootView: LayoutsView(model: model, store: .shared))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = window.contentLayoutRect
        window.contentView = host
        window.title = "WindowSnapper"
        window.contentMinSize = NSSize(width: 620, height: 380)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LayoutsWindow")   // remembers the size you drag it to
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ pane: Pane) {
        // Capture before we come to the front, so the snapshot reflects the user's real setup.
        if pane == .save { model.refreshSnapshot() }
        model.selection = pane
        model.status = ""
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct LayoutsView: View {
    @ObservedObject var model: LayoutsModel
    @ObservedObject var store: LayoutStore
    @ObservedObject var settings = Settings.shared

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row("General", icon: "gearshape", pane: .general)
                    row("Shortcuts", icon: "keyboard", pane: .shortcuts)
                    row("About", icon: "info.circle", pane: .about)

                    sectionTitle("Layouts")
                    row("Save Current Layout", icon: "plus.rectangle.on.rectangle", pane: .save)
                    ForEach(Array(store.layouts.enumerated()), id: \.element.id) { i, layout in
                        row(layout.name, icon: "rectangle.3.group", pane: .layout(layout.id),
                            trailing: layoutShortcut(i))
                            .contextMenu {
                                Button("Move Up") { store.move(from: IndexSet(integer: i), to: i - 1) }
                                    .disabled(i == 0)
                                Button("Move Down") { store.move(from: IndexSet(integer: i), to: i + 2) }
                                    .disabled(i == store.layouts.count - 1)
                            }
                    }
                    if store.layouts.count > 1 {
                        Text("Right-click a layout to reorder it. The order sets its shortcut.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 6)
                    }
                }
                .padding(10)
            }
            .frame(width: 230)
            .background(.regularMaterial)

            Divider()

            Group {
                switch model.selection {
                case .general: GeneralSettingsView()
                case .shortcuts: ShortcutsSettingsView()
                case .about: AboutView()
                case .layout(let id): LayoutDetailView(layoutID: id, model: model, store: store)
                case .save: SaveLayoutView(model: model, store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func layoutShortcut(_ i: Int) -> String? {
        guard let action = ShortcutAction.allCases.first(where: { $0.layoutIndex == i }) else { return nil }
        return settings.shortcuts[action]?.display
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 2)
    }

    private func row(_ title: String, icon: String, pane: Pane, trailing: String? = nil) -> some View {
        let selected = model.selection == pane
        return Button {
            if pane == .save { model.refreshSnapshot() }
            model.selection = pane
            model.status = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.callout.monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Save

struct SaveLayoutView: View {
    @ObservedObject var model: LayoutsModel
    @ObservedObject var store: LayoutStore
    @State private var name = ""
    @State private var included: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Current Windows").font(.title2.bold())
            Text("Pick which apps this layout should remember. Apps you can see right now are ticked; ones buried behind other windows are listed but unticked. "
                 + "Saving with an existing name replaces that layout.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Layout name — e.g. Desk, Home, Sunday", text: $name)
                .textFieldStyle(.roundedBorder)
            if let existing = store.layout(named: name) {
                Text("Will replace “\(existing.name)”.").font(.caption).foregroundStyle(.orange)
            }

            if model.snapshot.isEmpty {
                Spacer()
                Text(AX.isTrusted ? "No visible windows found." : "WindowSnapper needs Accessibility permission to see windows.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(model.snapshot) { app in
                        Toggle(isOn: binding(for: app.bundleID)) {
                            AppRow(icon: app.icon, name: app.name,
                                   detail: windowCount(app.windows.count) + (app.isVisible ? "" : " · covered"))
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            HStack {
                Button("Refresh") { model.refreshSnapshot() }
                Button(included.count == model.snapshot.count ? "Select None" : "Select All") {
                    included = included.count == model.snapshot.count ? [] : Set(model.snapshot.map(\.bundleID))
                }
                .disabled(model.snapshot.isEmpty)
                Spacer()
                Button("Save Layout", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || included.isEmpty)
            }
        }
        .padding(20)
        .onAppear(perform: reset)
        .onChange(of: model.snapshotVersion) { _ in reset() }
    }

    private func reset() {
        let excluded = store.excludedBundleIDs
        // Tick only what you can actually see (minus apps you've unticked before).
        included = Set(model.snapshot.filter { $0.isVisible && !excluded.contains($0.bundleID) }.map(\.bundleID))
        if name.isEmpty {
            // At a desk you've saved before? Prefill that name so updating it is one click.
            let ids = Set(LiveScreen.all().map(\.id))
            name = store.layoutMatching(screenIDs: ids)?.name ?? ""
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { included.contains(id) },
                set: { if $0 { included.insert(id) } else { included.remove(id) } })
    }

    private func save() {
        let chosen = model.snapshot.filter { included.contains($0.bundleID) }
        // Remember unticked apps so they're unticked next time too.
        var excluded = store.excludedBundleIDs
        for app in model.snapshot {
            if included.contains(app.bundleID) {
                excluded.remove(app.bundleID)
            } else if app.isVisible {
                excluded.insert(app.bundleID)   // you could see it and still unticked it
            }
        }
        store.excludedBundleIDs = excluded

        let layout = LayoutEngine.makeLayout(name: name.trimmingCharacters(in: .whitespaces), apps: chosen)
        let saved = store.save(layout)
        model.selection = .layout(saved.id)
        model.status = "Saved \(windowCount(saved.windowCount)) from \(saved.apps.count) app\(saved.apps.count == 1 ? "" : "s")."
        name = ""
    }
}

// MARK: - Detail

struct LayoutDetailView: View {
    let layoutID: UUID
    @ObservedObject var model: LayoutsModel
    @ObservedObject var store: LayoutStore
    @State private var confirmDelete = false
    @State private var restoring = false

    var body: some View {
        if let layout = store.layouts.first(where: { $0.id == layoutID }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(layout.name).font(.title2.bold())
                    Spacer()
                    Button(restoring ? "Restoring…" : "Restore") { restore(layout) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(restoring || !layout.apps.contains(where: \.enabled))
                }
                Text("Saved \(layout.savedAt.formatted(date: .abbreviated, time: .shortened)) on "
                     + layout.screens.map(\.name).joined(separator: " + "))
                    .foregroundStyle(.secondary)

                Text("Restore these apps:").font(.headline).padding(.top, 4)
                List {
                    ForEach(layout.apps) { app in
                        Toggle(isOn: store.enabledBinding(layout: layout.id, app: app.bundleID)) {
                            AppRow(icon: AppIcon.forBundleID(app.bundleID), name: app.name, detail: detail(app))
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))

                HStack {
                    Button("Delete Layout…", role: .destructive) { confirmDelete = true }
                    Spacer()
                    Text(model.status).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(20)
            .confirmationDialog("Delete “\(layout.name)”?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    store.delete(layout.id)
                    model.selection = .save
                    model.status = ""
                }
            }
        } else {
            Text("Select a layout").foregroundStyle(.secondary)
        }
    }

    private func detail(_ app: SavedApp) -> String {
        var s = windowCount(app.windows.count)
        let tabs = app.windows.reduce(0) { $0 + ($1.tabs?.count ?? 0) }
        if tabs > 0 { s += " · \(tabs) tab\(tabs == 1 ? "" : "s")" }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) == nil { s += " · not installed" }
        return s
    }

    private func restore(_ layout: WindowLayout) {
        restoring = true
        model.status = "Restoring…"
        LayoutEngine.restore(layout) { summary in
            restoring = false
            model.status = summary
        }
    }
}

// MARK: - Bits

struct AppRow: View {
    let icon: NSImage?
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            Text(name)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.callout)
        }
    }
}

enum AppIcon {
    static func forBundleID(_ id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

func windowCount(_ n: Int) -> String { "\(n) window\(n == 1 ? "" : "s")" }
