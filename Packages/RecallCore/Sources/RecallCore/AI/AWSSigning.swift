import CryptoKit
import Foundation

public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = (sessionToken?.isEmpty ?? true) ? nil : sessionToken
        self.expiration = expiration
    }

    func isFresh(at now: Date = Date()) -> Bool {
        guard let expiration else { return true }
        return expiration.timeIntervalSince(now) > 300
    }
}

/// AWS Signature Version 4, implemented with CryptoKit so the app needs no AWS SDK.
enum SigV4 {
    static func sign(_ request: inout URLRequest, body: Data, credentials: AWSCredentials, region: String, service: String,
                     date: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }
        let amzDate = format(date, "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = format(date, "yyyyMMdd")
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        var headers: [String: String] = ["host": hostHeader, "x-amz-date": amzDate]
        if let token = credentials.sessionToken { headers["x-amz-security-token"] = token }
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken { request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token") }

        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonicalHeaders = headers.keys.sorted().map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(url),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            hex(SHA256.hash(data: body)),
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// Non-S3 services encode each already-encoded path segment again (so `%3A` becomes `%253A`).
    static func canonicalURI(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(name: String, value: String)] = items.map { (encode($0.name), encode($0.value ?? "")) }
        let sorted = pairs.sorted { (a, b) -> Bool in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// Resolves credentials for a named AWS profile.
///
/// Static keys are read from `~/.aws/credentials`. Anything else (SSO, `aws login`, assumed roles,
/// credential_process) is delegated to the AWS CLI via `aws configure export-credentials`, so the
/// app supports every credential type the CLI does without bundling the SDK.
public enum AWSProfileCredentials {
    public static func load(profile: String) async throws -> AWSCredentials {
        let name = profile.isEmpty ? "default" : profile
        if let creds = staticCredentials(profile: name) { return creds }
        return try await exportFromCLI(profile: name)
    }

    static func staticCredentials(profile: String) -> AWSCredentials? {
        let env = ProcessInfo.processInfo.environment
        let path = env["AWS_SHARED_CREDENTIALS_FILE"] ?? NSString(string: "~/.aws/credentials").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let section = parseINI(text)[profile] ?? [:]
        guard let id = section["aws_access_key_id"], let secret = section["aws_secret_access_key"] else { return nil }
        return AWSCredentials(accessKeyID: id, secretAccessKey: secret, sessionToken: section["aws_session_token"])
    }

    static func parseINI(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result[current, default: [:]][key] = value
        }
        return result
    }

    static let cliCandidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]

    static func exportFromCLI(profile: String) async throws -> AWSCredentials {
        guard let cli = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AIProviderError.missingCredentials("profile “\(profile)” has no static keys in ~/.aws/credentials and the AWS CLI wasn't found to resolve it")
        }
        let output: Data = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["configure", "export-credentials", "--profile", profile, "--format", "process"]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { p in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: AIProviderError.missingCredentials("aws CLI could not export credentials for “\(profile)”: \(message.clipped(200))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: AIProviderError.missingCredentials(error.localizedDescription)) }
        }
        guard let obj = AIHTTP.object(output), let id = obj["AccessKeyId"] as? String, let secret = obj["SecretAccessKey"] as? String else {
            throw AIProviderError.missingCredentials("unexpected output from aws configure export-credentials")
        }
        let expiration = (obj["Expiration"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return AWSCredentials(accessKeyID: id, secretAccessKey: secret, sessionToken: obj["SessionToken"] as? String, expiration: expiration)
    }
}
