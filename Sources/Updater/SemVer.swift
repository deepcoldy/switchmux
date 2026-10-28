import Foundation

/// Minimal semantic version (https://semver.org) sufficient for release tags.
/// Build metadata is ignored for equality and precedence per the spec.
struct SemVer: Comparable, Codable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-split prerelease identifiers after "-"; empty means a stable release.
    let prerelease: [String]
    /// Build metadata after "+" (ignored for comparison/identity).
    let buildMeta: String

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = [], buildMeta: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMeta = buildMeta
    }

    /// Parses "1.2.3", "v1.2.3", "1.2.3-canary.1", "1.2.3+build.42".
    /// Returns nil for anything malformed ("1.2", two-digit shortcuts, garbage).
    init?(string raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        var buildMeta = ""
        if let plus = s.firstIndex(of: "+") {
            buildMeta = String(s[s.index(after: plus)...])
            s = String(s[..<plus])
            guard !buildMeta.isEmpty,
                  buildMeta.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "." || $0 == "-" })
            else { return nil }
        }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            let preRaw = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
            guard !preRaw.isEmpty else { return nil }
            pre = preRaw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pre.allSatisfy(SemVer.isValidIdentifier) else { return nil }
        }
        let core = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard core.count == 3,
              core.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        // No leading zeroes on numeric identifiers.
        guard core.allSatisfy({ $0.count == 1 || $0.first != "0" }) else { return nil }
        guard let maj = Int(core[0]), let min = Int(core[1]), let pat = Int(core[2]) else { return nil }
        self.init(major: maj, minor: min, patch: pat, prerelease: pre, buildMeta: buildMeta)
    }

    /// Parses a git tag, tolerating one leading "v".
    static func parse(tag: String) -> SemVer? { SemVer(string: tag) }

    var isStable: Bool { prerelease.isEmpty }

    var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { s += "-" + prerelease.joined(separator: ".") }
        return s
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        guard id.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" }) else { return false }
        if id.allSatisfy(\.isNumber) {
            return id.count == 1 || id.first != "0"   // no leading zeroes
        }
        return true
    }

    // Build metadata is ignored for identity/precedence (semver §10).
    static func == (l: SemVer, r: SemVer) -> Bool {
        l.major == r.major && l.minor == r.minor && l.patch == r.patch && l.prerelease == r.prerelease
    }

    static func < (l: SemVer, r: SemVer) -> Bool {
        let lc = [l.major, l.minor, l.patch]
        let rc = [r.major, r.minor, r.patch]
        if lc != rc { return lc.lexicographicallyPrecedes(rc) }
        // No prerelease > has prerelease (stable outranks its own prerelease).
        if l.prerelease.isEmpty && r.prerelease.isEmpty { return false }
        if l.prerelease.isEmpty { return false }
        if r.prerelease.isEmpty { return true }
        // Compare prerelease identifiers pairwise per semver §11.
        for (a, b) in zip(l.prerelease, r.prerelease) {
            if a == b { continue }
            let an = a.allSatisfy(\.isNumber)
            let bn = b.allSatisfy(\.isNumber)
            if an && bn {
                return (Int(a) ?? 0) < (Int(b) ?? 0)
            }
            if an != bn { return an }   // numeric sorts lower than alphanumeric
            return a < b
        }
        return l.prerelease.count < r.prerelease.count
    }
}
