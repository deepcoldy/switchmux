import AppKit
import Security

/// Bundle-level facts about the running build used across the updater.
enum AppInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
    }

    static var currentVersion: SemVer {
        SemVer(string: shortVersion) ?? .zero
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "dev.shenhan.switchmux"
    }

    static let expectedBundleID = "dev.shenhan.switchmux"
    static let teamID = "8VP93PY3E9"

    static let releasesWebURL = URL(string: "https://github.com/deepcoldy/switchmux/releases/latest")!

    /// Team ID embedded in the on-disk running app's signature; nil for ad-hoc builds.
    /// The kSecCSSigningInformation flag is required, otherwise the signing
    /// info dictionary omits the certificate chain and team identifier.
    static var runningTeamIdentifier: String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Release builds carry the Developer ID team; local build.sh builds are ad-hoc.
    static var isDeveloperIDSigned: Bool {
        runningTeamIdentifier == teamID
    }

    /// Whether the running .app sits in a directory the updater can swap in
    /// place. False for the unbundled debug binary, a DMG volume, or a
    /// read-only / non-writable parent.
    static func canReplaceInPlace() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return false }
        let resolved = bundleURL.resolvingSymlinksInPath().path
        guard !resolved.contains("/Volumes/") else { return false }
        let parent = bundleURL.deletingLastPathComponent()
        // Real write probe: create and remove a temp file next to the app.
        let probe = parent.appendingPathComponent(".switchmux-update-probe-\(UUID().uuidString.prefix(8))")
        do {
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}

extension SemVer {
    static let zero = SemVer(major: 0, minor: 0, patch: 0, prerelease: [])
}
