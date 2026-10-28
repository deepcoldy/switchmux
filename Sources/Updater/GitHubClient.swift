import Foundation

/// Fetches the latest-release feed from the GitHub API.
final class GitHubClient {
    static let shared = GitHubClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Feed URL; overridable for local end-to-end tests via SWITCHMUX_UPDATE_FEED
    /// (may be a file:// URL). The override only exists in a debug launch context.
    static var feedURL: URL {
        if let override = ProcessInfo.processInfo.environment["SWITCHMUX_UPDATE_FEED"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/deepcoldy/switchmux/releases/latest")!
    }

    func fetchLatest(completion: @escaping (Result<GitHubRelease, UpdateError>) -> Void) {
        var request = URLRequest(url: Self.feedURL)
        request.setValue("SwitchMux/\(AppInfo.shortVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(.network))
                return
            }
            guard let data, !data.isEmpty else {
                completion(.failure(.decode))
                return
            }
            // A file:// feed (local test override) yields a plain NSURLResponse.
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 403 || http.statusCode == 429 {
                    let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                    if remaining == "0" { completion(.failure(.rateLimited)); return }
                }
                guard (200..<300).contains(http.statusCode) else {
                    completion(.failure(.http(http.statusCode)))
                    return
                }
            }
            let decoder = JSONDecoder()
            guard let release = try? decoder.decode(GitHubRelease.self, from: data) else {
                completion(.failure(.decode))
                return
            }
            completion(.success(release))
        }
        task.resume()
    }
}
