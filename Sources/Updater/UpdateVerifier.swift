import Foundation
import CryptoKit
import Security

enum VerificationReport: Equatable {
    case ok
    case checksumMismatch
    case bundleIDMismatch
    case versionMismatch
    case signatureRejected(String)
    case deepVerifyFailed(String)
    case adhocRejected

    var passed: Bool { self == .ok }
    var message: String {
        switch self {
        case .ok: return ""
        case .checksumMismatch: return UpdateError.checksumMismatch.userMessage
        case .bundleIDMismatch: return "安装包应用标识不匹配，已中止更新"
        case .versionMismatch: return "安装包版本与发布信息不一致，已中止更新"
        case .signatureRejected(let detail): return "\(UpdateError.signatureRejected.userMessage)（\(detail)）"
        case .deepVerifyFailed(let detail): return "安装包完整性校验未通过（\(detail)）"
        case .adhocRejected: return UpdateError.adhocRejected.userMessage
        }
    }
}

enum UpdateVerifier {

    // MARK: Checksum

    static func sha256(of url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }
        var hash = SHA256()
        let bufferSize = 1 << 16
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 { return nil }
            if read == 0 { break }
            hash.update(data: Data(buffer[..<read]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// When `expected` is nil the feed gave no digest; skip (signature check
    /// still anchors trust). A present digest must match exactly.
    static func verifyDMGChecksum(_ dmg: URL, expected: String?) -> Bool {
        guard let expected else { return true }
        guard let actual = sha256(of: dmg) else { return false }
        return actual.caseInsensitiveCompare(expected) == .orderedSame
    }

    // MARK: Mounted app identity + signature

    /// Designated requirement pinning our Developer ID team. Must be validated
    /// against a real installed release via `codesign -dr -` before shipping.
    static let designatedRequirement = """
    identifier "\(AppInfo.expectedBundleID)" and anchor apple generic \
    and certificate 1[field.1.2.840.113635.100.6.2.6] \
    and certificate leaf[field.1.2.840.113635.100.6.1.13] \
    and certificate leaf[subject.OU] = "\(AppInfo.teamID)"
    """

    static func verifyMountedApp(_ app: URL, target: SemVer, allowAdhoc: Bool) -> VerificationReport {
        // 1. Bundle identifier.
        guard let bundle = Bundle(url: app),
              let bundleID = bundle.bundleIdentifier,
              bundleID == AppInfo.expectedBundleID else {
            return .bundleIDMismatch
        }

        // 2. Advertised version must match the mounted app.
        let mountedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard mountedVersion == target.description else {
            return .versionMismatch
        }

        // 3. Ad-hoc dev builds can never satisfy the Developer ID DR. Only an
        //    explicit env opt-in downgrades to the bundle-id/version checks above.
        if !AppInfo.isDeveloperIDSigned {
            return allowAdhoc ? .ok : .adhocRejected
        }

        // 4. SecStaticCode validity against the pinned requirement.
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard createStatus == errSecSuccess, let code else {
            return .signatureRejected("SecStaticCodeCreateWithPath \(createStatus)")
        }
        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(designatedRequirement as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            return .signatureRejected("SecRequirementCreateWithString \(reqStatus)")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let validStatus = SecStaticCodeCheckValidity(code, flags, requirement)
        guard validStatus == errSecSuccess else {
            return .signatureRejected("OSStatus \(validStatus)")
        }

        // 5. Cross-check the team id in signing information. The
        //    kSecCSSigningInformation flag is required, otherwise the
        //    dictionary omits the certificate chain and team identifier.
        var info: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, infoFlags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              team == AppInfo.teamID,
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
              identifier == AppInfo.expectedBundleID else {
            return .signatureRejected("team/identifier mismatch")
        }

        // 6. codesign --deep as belt and braces.
        let result = runCodeSignVerify(app)
        if result != 0 {
            return .deepVerifyFailed("exit \(result)")
        }
        return .ok
    }

    @discardableResult
    private static func runCodeSignVerify(_ app: URL) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", "--verbose=2", app.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let workItem = DispatchWorkItem { if p.isRunning { p.terminate() } }
        do {
            try p.run()
        } catch {
            return -1
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: workItem)
        p.waitUntilExit()
        workItem.cancel()
        return p.terminationStatus
    }
}
