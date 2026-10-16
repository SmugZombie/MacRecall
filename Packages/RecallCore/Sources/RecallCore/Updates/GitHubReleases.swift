import Foundation

public struct ReleaseAsset: Sendable, Equatable {
    public var name: String
    public var browserURL: URL
    public var size: Int64
    /// e.g. "sha256:…", published by GitHub for release assets.
    public var digest: String?

    public var sha256: String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        return String(digest.dropFirst("sha256:".count)).lowercased()
    }
}

public struct AppRelease: Sendable, Equatable {
    public var version: SemanticVersion
    public var tag: String
    public var name: String
    public var notes: String
    public var pageURL: URL
    public var publishedAt: Date?
    /// The app archive (`RecallForMac-<version>.zip`), if the release has one.
    public var asset: ReleaseAsset?
}

public enum UpdateError: Error, LocalizedError, Sendable, Equatable {
    case notFound(String)
    case rateLimited(Date?)
    case http(Int)
    case network(String)
    case malformed(String)
    case noAsset
    case checksumMismatch
    case invalidBundle(String)
    case signatureInvalid(String)
    case cannotInstall(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let repo):
            return "No published releases were found for \(repo)."
        case .rateLimited(let reset):
            return "GitHub's rate limit was reached" + (reset.map { "; try again after \($0.formatted(date: .omitted, time: .shortened))" } ?? "") + "."
        case .http(let code): return "GitHub returned HTTP \(code)."
        case .network(let m): return "Couldn't reach GitHub: \(m)"
        case .malformed(let m): return "Unexpected response from GitHub: \(m)"
        case .noAsset: return "This release has no app download attached."
        case .checksumMismatch: return "The download doesn't match the checksum GitHub published for it, so it wasn't installed."
        case .invalidBundle(let m): return "The downloaded app isn't valid: \(m)"
        case .signatureInvalid(let m): return "The downloaded app isn't signed by the same developer as this one, so it wasn't installed. \(m)"
        case .cannotInstall(let m): return m
        }
    }
}

/// Reads releases from the GitHub REST API. Sends no data beyond the request itself.
public struct GitHubReleaseClient: Sendable {
    public var repository: String
    let session: URLSession

    public init(repository: String, configuration: URLSessionConfiguration? = nil) {
        self.repository = repository
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// The latest published, non-prerelease release.
    public func latestRelease() async throws -> AppRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { throw UpdateError.malformed("repository") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw UpdateError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.malformed("not HTTP") }
        switch http.statusCode {
        case 200: return try Self.parse(data)
        case 404: throw UpdateError.notFound(repository)
        case 403, 429:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                throw UpdateError.rateLimited(reset)
            }
            throw UpdateError.http(http.statusCode)
        default: throw UpdateError.http(http.statusCode)
        }
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "RecallForMac/\(version)"
    }

    static func parse(_ data: Data) throws -> AppRelease {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpdateError.malformed("not JSON") }
        guard let tag = obj["tag_name"] as? String, let version = SemanticVersion(tag) else {
            throw UpdateError.malformed("release tag isn't a version")
        }
        guard let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) else { throw UpdateError.malformed("missing release URL") }
        let assets = (obj["assets"] as? [[String: Any]] ?? []).compactMap { a -> ReleaseAsset? in
            guard let name = a["name"] as? String,
                  let browser = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return ReleaseAsset(name: name, browserURL: browser, size: (a["size"] as? NSNumber)?.int64Value ?? 0,
                                digest: a["digest"] as? String)
        }
        return AppRelease(
            version: version, tag: tag, name: obj["name"] as? String ?? tag, notes: obj["body"] as? String ?? "",
            pageURL: page, publishedAt: (obj["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            asset: assets.first { $0.name.hasPrefix("RecallForMac") && $0.name.hasSuffix(".zip") })
    }
}
