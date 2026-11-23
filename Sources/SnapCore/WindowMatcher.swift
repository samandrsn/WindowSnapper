import Foundation

/// Decides which live window should take the place of which saved window.
/// Needed because apps like Chrome can have many windows, and they don't come back in
/// the same order (or with stable IDs) after a relaunch.
public enum WindowMatcher {

    /// Generic apps: match by window title, then by "one title contains the other",
    /// then pair whatever is left in order. Returns savedIndex → currentIndex.
    public static func matchByTitle(saved: [String], current: [String]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var freeCurrent = Set(current.indices)

        // 1. Exact title.
        for (si, s) in saved.enumerated() where !s.isEmpty {
            if let ci = current.indices.first(where: { freeCurrent.contains($0) && current[$0] == s }) {
                result[si] = ci; freeCurrent.remove(ci)
            }
        }
        // 2. Fuzzy title (e.g. "Notes — 3 unsaved" vs "Notes").
        for (si, s) in saved.enumerated() where result[si] == nil && s.count >= 3 {
            if let ci = current.indices.first(where: {
                freeCurrent.contains($0) && current[$0].count >= 3 &&
                    (current[$0].localizedCaseInsensitiveContains(s) || s.localizedCaseInsensitiveContains(current[$0]))
            }) {
                result[si] = ci; freeCurrent.remove(ci)
            }
        }
        // 3. Leftovers in order.
        let remaining = current.indices.filter { freeCurrent.contains($0) }
        var it = remaining.makeIterator()
        for si in saved.indices where result[si] == nil {
            guard let ci = it.next() else { break }
            result[si] = ci
        }
        return result
    }

    /// Browsers: match windows by how many tab URLs they share (Jaccard similarity), best
    /// pairs first. Saved windows without any overlapping live window stay unmatched, so the
    /// caller can recreate them with their tabs.
    public static func matchByTabs(saved: [[String]], current: [[String]]) -> [Int: Int] {
        let savedSets = saved.map { Set($0.map(normalize).filter { !$0.isEmpty }) }
        let currentSets = current.map { Set($0.map(normalize).filter { !$0.isEmpty }) }

        var pairs: [(score: Double, s: Int, c: Int)] = []
        for (si, a) in savedSets.enumerated() where !a.isEmpty {
            for (ci, b) in currentSets.enumerated() where !b.isEmpty {
                let inter = a.intersection(b).count
                guard inter > 0 else { continue }
                pairs.append((Double(inter) / Double(a.union(b).count), si, ci))
            }
        }
        pairs.sort { $0.score != $1.score ? $0.score > $1.score : ($0.s, $0.c) < ($1.s, $1.c) }

        var result: [Int: Int] = [:]
        var usedCurrent = Set<Int>()
        for p in pairs where result[p.s] == nil && !usedCurrent.contains(p.c) {
            result[p.s] = p.c
            usedCurrent.insert(p.c)
        }
        return result
    }

    /// Ignore fragments and trailing slashes so "x.com/a#top" and "x.com/a/" count as the same tab.
    static func normalize(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = u.firstIndex(of: "#") { u = String(u[..<hash]) }
        while u.hasSuffix("/") { u.removeLast() }
        return u.lowercased()
    }

    /// New-tab / blank pages, which carry no identity.
    public static func isBlankTab(_ url: String) -> Bool {
        let u = url.lowercased()
        if u.isEmpty || u == "missing value" || u == "about:blank" { return true }
        return u.contains("newtab") || u.contains("new-tab-page") ||
            u.hasPrefix("favorites://") || u.hasPrefix("topsites://")
    }
}
