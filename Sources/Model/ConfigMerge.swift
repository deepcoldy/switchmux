import Foundation

/// Merges config snapshots key by key (top-level JSON keys), so a Mac only
/// overrides the settings it actually changed since it last synced.
///
/// - `base`: the iCloud state this Mac last incorporated (common ancestor).
/// - `local`: this Mac's current state. `remote`: what iCloud has now.
///
/// A key missing from one side means "unchanged", never "deleted": every
/// field is optional and older builds drop the keys they don't know (`apps`,
/// `_sync`) each time they re-save.
enum ConfigMerge {
    typealias JSON = [String: Any]

    static let metaKey = "_sync"

    /// Sync metadata stored under `_sync`. Older builds ignore it and drop it
    /// when they re-save; such files fall back to their modification date.
    struct Stamp: Equatable {
        /// When each top-level key was last changed (on whichever Mac).
        var times: [String: Double] = [:]
        /// Edit time of keys missing from `times`.
        var baseline: Double = 0
        /// Mac of the newest edit.
        var editedBy: String?
        /// Last write to iCloud.
        var savedAt: Double?
        var savedBy: String?
        /// Built from this Mac's Dock on first run and never merged with an
        /// iCloud config yet: loses against any real config.
        var seeded = false

        init(baseline: Double, editedBy: String? = nil, seeded: Bool = false) {
            self.baseline = baseline
            self.editedBy = editedBy
            self.seeded = seeded
        }

        init?(_ json: JSON?) {
            guard let meta = json?[ConfigMerge.metaKey] as? JSON else { return nil }
            for (key, value) in meta["times"] as? JSON ?? [:] {
                if let time = (value as? NSNumber)?.doubleValue { times[key] = time }
            }
            baseline = (meta["baseline"] as? NSNumber)?.doubleValue ?? 0
            editedBy = meta["editedBy"] as? String
            savedAt = (meta["savedAt"] as? NSNumber)?.doubleValue
            savedBy = meta["savedBy"] as? String
            seeded = (meta["seeded"] as? NSNumber)?.boolValue ?? false
        }

        var json: JSON {
            var meta: JSON = ["times": times, "baseline": baseline]
            if let editedBy { meta["editedBy"] = editedBy }
            if let savedAt { meta["savedAt"] = savedAt }
            if let savedBy { meta["savedBy"] = savedBy }
            if seeded { meta["seeded"] = true }
            return meta
        }

        /// Newest edit of any key.
        var editedAt: Double { max(baseline, times.values.max() ?? 0) }

        /// Edit time of `key`. A seed's untouched keys lose to everything.
        func time(of key: String) -> Double {
            times[key] ?? (seeded ? -1 : baseline)
        }
    }

    static func stamped(_ json: JSON, _ stamp: Stamp) -> JSON {
        var out = json
        out[metaKey] = stamp.json
        return out
    }

    /// Same settings, ignoring the metadata and `ignoring` keys.
    static func sameContent(_ a: JSON?, _ b: JSON?, ignoring: Set<String> = []) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let skip = ignoring.union([metaKey])
        return equal(a.filter { !skip.contains($0.key) }, b.filter { !skip.contains($0.key) })
    }

    /// Keys whose values differ between `a` and `b` (metadata ignored).
    static func changedKeys(from a: JSON?, to b: JSON) -> Set<String> {
        var keys = Set<String>()
        for (key, value) in b where key != metaKey && !equal(a?[key], value) { keys.insert(key) }
        return keys
    }

    /// Three-way merge. Keys changed on one side take that side's value; keys
    /// changed on both sides (or everything, without a base) take the newer
    /// edit. `localFileTime` / `remoteFileTime` stand in for edit times of
    /// files written by older builds (no `_sync`).
    static func merge(base: JSON?, local: JSON?, remote: JSON?,
                      localFileTime: Double = 0, remoteFileTime: Double = 0) -> JSON? {
        guard let remote else { return local }
        guard let local else { return remote }
        let localStamp = Stamp(local) ?? Stamp(baseline: localFileTime)
        let remoteStamped = Stamp(remote) != nil
        let remoteStamp = Stamp(remote) ?? Stamp(baseline: remoteFileTime)
        // A first-run seed in iCloud never overrides a real config.
        if remoteStamp.seeded && !localStamp.seeded { return local }

        let l = overlay(local, on: base), r = overlay(remote, on: base)
        var merged: JSON = [:]
        var stamp = Stamp(baseline: 0)
        var newest: (time: Double, device: String?) = (-.infinity, nil)
        for key in Set(l.keys).union(r.keys) where key != metaKey {
            let lv = l[key], rv = r[key]
            let lt = localStamp.time(of: key), rt = remoteStamp.time(of: key)
            let takeLocal: Bool
            if equal(lv, rv) {
                // An older build's file date says when it last rewrote the
                // file, not when this value was edited.
                takeLocal = !remoteStamped || lt >= rt
            } else if let base {
                let bv = base[key]
                if equal(lv, bv) { takeLocal = false }
                else if equal(rv, bv) { takeLocal = true }
                else { takeLocal = lt >= rt }
            } else {
                takeLocal = lt > rt
            }
            merged[key] = takeLocal ? lv : rv
            let time = takeLocal ? lt : rt
            if time > 0 { stamp.times[key] = time }
            if time > newest.time {
                newest = (time, takeLocal ? localStamp.editedBy : remoteStamp.editedBy)
            }
        }
        stamp.editedBy = newest.device ?? localStamp.editedBy ?? remoteStamp.editedBy
        stamp.savedAt = remoteStamp.savedAt
        stamp.savedBy = remoteStamp.savedBy
        stamp.seeded = localStamp.seeded && remoteStamp.seeded
        return stamped(merged, stamp)
    }

    /// Combines iCloud conflict versions (no reliable common ancestor) key by
    /// key: the newest edit of each key wins, a first-run seed loses to any
    /// real config. Versions from older builds count as edited at their
    /// modification date only if no version carries edit times (they rewrite
    /// stale state on every switch, so their dates say nothing about edits).
    /// Deterministic, so every Mac resolving the same set agrees.
    static func resolve(_ versions: [(json: JSON, fileTime: Double)]) -> JSON? {
        guard !versions.isEmpty else { return nil }
        // A seed must not fill in keys the real versions lack either.
        let real = versions.filter { Stamp($0.json)?.seeded != true }
        let versions = real.isEmpty ? versions : real
        let anyStamped = versions.contains { Stamp($0.json) != nil }
        let stamps = versions.map { Stamp($0.json) ?? Stamp(baseline: anyStamped ? 0 : $0.fileTime) }
        let order = versions.indices.sorted { versions[$0].fileTime < versions[$1].fileTime }

        var merged: JSON = [:]
        var stamp = Stamp(baseline: 0)
        var newest = -Double.infinity
        let keys = versions.reduce(into: Set<String>()) { $0.formUnion($1.json.keys) }.subtracting([metaKey])
        for key in keys {
            var best: (index: Int, time: Double)?
            for i in order where versions[i].json[key] != nil {
                let time = stamps[i].time(of: key)
                if best == nil || time >= best!.time { best = (i, time) }
            }
            guard let best else { continue }
            merged[key] = versions[best.index].json[key]
            if best.time > 0 { stamp.times[key] = best.time }
            if best.time > newest {
                newest = best.time
                stamp.editedBy = stamps[best.index].editedBy
            }
        }
        stamp.seeded = stamps.allSatisfy(\.seeded)
        return stamped(merged, stamp)
    }

    /// `json` with keys it lacks taken from `base`.
    private static func overlay(_ json: JSON, on base: JSON?) -> JSON {
        guard let base else { return json }
        return json.merging(base) { current, _ in current }
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b as AnyObject)
        default: return false
        }
    }
}
