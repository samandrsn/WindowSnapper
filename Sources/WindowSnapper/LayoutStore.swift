import Foundation
import SnapCore
import SwiftUI

/// Saved layouts, kept in ~/Library/Application Support/WindowSnapper/layouts.json.
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()

    @Published private(set) var layouts: [WindowLayout] = []

    private let fileURL: URL = {
        // WINDOWSNAPPER_DATA_DIR points the app at a different folder (used for demos/screenshots).
        let dir = ProcessInfo.processInfo.environment["WINDOWSNAPPER_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowSnapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layouts.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            layouts = (try? decoder.decode([WindowLayout].self, from: data)) ?? []
        }
    }

    func layout(named name: String) -> WindowLayout? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return layouts.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    /// Adds a layout, replacing any existing one with the same name (keeps its id/position).
    @discardableResult
    func save(_ layout: WindowLayout) -> WindowLayout {
        var l = layout
        if let i = layouts.firstIndex(where: { $0.name.caseInsensitiveCompare(layout.name) == .orderedSame }) {
            l.id = layouts[i].id
            layouts[i] = l
        } else {
            layouts.append(l)
        }
        persist()
        return l
    }

    /// Reordering changes which ⌥⌘ number restores which layout.
    func move(from source: IndexSet, to destination: Int) {
        layouts.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func delete(_ id: UUID) {
        layouts.removeAll { $0.id == id }
        persist()
    }

    func enabledBinding(layout id: UUID, app bundleID: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                self?.layouts.first { $0.id == id }?.apps.first { $0.bundleID == bundleID }?.enabled ?? false
            },
            set: { [weak self] value in
                guard let self,
                      let li = self.layouts.firstIndex(where: { $0.id == id }),
                      let ai = self.layouts[li].apps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
                self.layouts[li].apps[ai].enabled = value
                self.persist()
            })
    }

    /// The layout saved on exactly the displays connected now (used to prefill the Save name).
    func layoutMatching(screenIDs: Set<String>) -> WindowLayout? {
        layouts.last { Set($0.screens.map(\.id)) == screenIDs }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(layouts).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("WindowSnapper: failed to save layouts: \(error)")
        }
    }

    // MARK: Remembered app choices

    /// Apps the user unticked last time they saved, so they stay unticked next time.
    var excludedBundleIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "excludedBundleIDs") }
    }
}
