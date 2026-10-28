import Foundation

// MARK: GitHub API payloads

struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let assets: [GitHubAsset]

    // All keys explicit: .convertFromSnakeCase would also re-convert these
    // raw values, and it maps html_url -> htmlUrl rather than htmlURL anyway.
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case htmlURL = "html_url"
    }

    var dmgAsset: GitHubAsset? {
        assets.first { $0.name == "SwitchMux.dmg" }
    }

    func makeReleaseInfo() -> ReleaseInfo? {
        guard !draft, !prerelease,
              let version = SemVer.parse(tag: tagName),
              version.isStable,
              version > AppInfo.currentVersion,
              let asset = dmgAsset else { return nil }
        var sha: String?
        if let digest = asset.digest {
            // API format: "sha256:<hex>" (and may carry a second algorithm).
            for part in digest.split(separator: ",") {
                let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0] == "sha256", pair[1].count == 64 {
                    sha = pair[1].lowercased()
                    break
                }
            }
        }
        return ReleaseInfo(
            version: version,
            title: name?.isEmpty == false ? name! : "v\(version)",
            releaseNotes: body ?? "",
            pageURL: htmlURL,
            downloadURL: asset.browserDownloadURL,
            size: asset.size,
            sha256: sha
        )
    }
}

struct GitHubAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: App-side models

struct ReleaseInfo: Equatable {
    let version: SemVer
    let title: String
    let releaseNotes: String
    let pageURL: URL
    let downloadURL: URL
    let size: Int64
    /// Hex SHA-256 without the "sha256:" prefix, when the API provided one.
    let sha256: String?
}

/// A fully downloaded + checksum-verified update waiting for the relaunch.
struct PendingUpdate: Codable, Equatable {
    let version: String
    let dmgPath: String
    let releaseNotes: String
    let pageURL: URL
    let downloadedAt: Date

    var dmgURL: URL { URL(fileURLWithPath: dmgPath) }
}

enum UpdateCheckMode { case automatic, manual }

enum UpdateError: Error, Equatable {
    case network
    case http(Int)
    case rateLimited
    case decode
    case noAsset
    case unsupportedTag
    case metered
    case checksumMismatch
    case attachFailed
    case signatureRejected
    case adhocRejected
    case readOnlyLocation
    case installFailed

    var userMessage: String {
        switch self {
        case .network: return "网络异常，暂时无法检查更新"
        case .http(let code): return "GitHub 返回异常（\(code)），请稍后再试"
        case .rateLimited: return "GitHub 接口请求受限，请稍后再试"
        case .decode: return "版本信息异常"
        case .noAsset: return "暂未找到 SwitchMux.dmg 安装包"
        case .unsupportedTag: return "版本信息异常"
        case .metered: return "当前为计费网络，已跳过自动下载，可手动下载"
        case .checksumMismatch: return "安装包校验失败（可能已损坏或被篡改），已删除"
        case .attachFailed: return "无法打开安装映像"
        case .signatureRejected: return "安装包签名校验未通过，已中止更新"
        case .adhocRejected: return "开发版（ad-hoc）构建不能自动安装，请从官网下载正式版"
        case .readOnlyLocation: return "当前位置无写权限，无法自动更新"
        case .installFailed: return "安装失败，请手动下载新版"
        }
    }
}

/// UI state machine. `ready` carries the pending update; transient release
/// states carry the release being acted on.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case downloading(ReleaseInfo, Double)
    case verifying(ReleaseInfo)
    case ready(PendingUpdate)
    case error(String)

    /// The release involved in a transient state, if any.
    var release: ReleaseInfo? {
        switch self {
        case .available(let r), .downloading(let r, _), .verifying(let r): return r
        default: return nil
        }
    }

    var pending: PendingUpdate? {
        if case .ready(let p) = self { return p }
        return nil
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying: return true
        default: return false
        }
    }
}
