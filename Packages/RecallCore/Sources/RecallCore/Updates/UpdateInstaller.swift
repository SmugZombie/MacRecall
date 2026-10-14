import CryptoKit
import Foundation
import Security

/// Downloads, verifies and installs a release over the running app.
///
/// Trust comes from the code signature, not the download location: the new bundle must satisfy a
/// requirement built from *this* app's own Team ID and bundle identifier, so only builds signed by
/// the same developer can replace it. GitHub's published SHA-256 is checked too when available.
public struct UpdateInstaller: Sendable {
    public struct Environment: Sendable, Equatable {
        public var bundleURL: URL
        public var bundleIdentifier: String
        public var version: SemanticVersion?
        /// Team ID of the running app's signature; nil for unsigned or ad hoc builds.
        public var teamIdentifier: String?

        public init(bundleURL: URL, bundleIdentifier: String, version: SemanticVersion?, teamIdentifier: String?) {
            self.bundleURL = bundleURL
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.teamIdentifier = teamIdentifier
        }

        public static var current: Environment {
            Environment(bundleURL: Bundle.main.bundleURL,
                        bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                        version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemanticVersion.init),
                        teamIdentifier: UpdateInstaller.teamIdentifier(ofRunningApp: ()))
        }
    }

    public enum Eligibility: Equatable, Sendable {
        case eligible
        case ineligible(String)
    }

    public init() {}

    // MARK: Eligibility

    /// Whether this copy can replace itself. Otherwise the UI offers a download link instead.
    public static func eligibility(_ env: Environment, fileManager: FileManager = .default) -> Eligibility {
        let path = env.bundleURL.path
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") {
            return .ineligible("This is a development build; install updates from a release build.")
        }
        if path.contains("/AppTranslocation/") {
            return .ineligible("macOS is running Recall from a temporary location. Move it to the Applications folder, then reopen it.")
        }
        guard env.teamIdentifier != nil else {
            return .ineligible("This copy isn't signed with a developer certificate, so updates can't be verified.")
        }
        let parent = env.bundleURL.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent), fileManager.isWritableFile(atPath: path) else {
            return .ineligible("Recall can't write to \(parent), so it can't update itself there.")
        }
        return .eligible
    }

    // MARK: Download

    /// Downloads the asset to a fresh temporary directory, reporting progress from 0 to 1.
    public func download(_ asset: ReleaseAsset, token: String?, configuration: URLSessionConfiguration? = nil,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecallUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(asset.name)

        // Private repos need the API URL plus a token; public ones use the plain download link.
        var request: URLRequest
        if let token, !token.isEmpty {
            request = URLRequest(url: asset.apiURL, timeoutInterval: 60)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        } else {
            request = URLRequest(url: asset.browserURL, timeoutInterval: 60)
        }
        request.setValue(GitHubReleaseClient.userAgent, forHTTPHeaderField: "User-Agent")

        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: DownloadRedirectGuard())
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.malformed("not HTTP") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UpdateError.unauthorized
        case 404: throw UpdateError.noAsset
        default: throw UpdateError.http(http.statusCode)
        }

        let expected = max(asset.size, http.expectedContentLength)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { progress(min(1, Double(written) / Double(expected))) }
            }
        }
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        if asset.size > 0, written != asset.size {
            throw UpdateError.invalidBundle("the download is \(written) bytes; expected \(asset.size)")
        }
        progress(1)
        return destination
    }

    // MARK: Verification

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyChecksum(_ file: URL, expected: String?) throws {
        guard let expected else { return }  // older releases have no published digest; the signature check still applies
        guard try sha256(of: file) == expected.lowercased() else { throw UpdateError.checksumMismatch }
    }

    /// Unzips with `ditto` (preserves the bundle's signature and symlinks) and returns the single app inside.
    public static func extractApp(from zip: URL) throws -> URL {
        let dir = zip.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, dir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidBundle("the archive couldn't be unpacked") }
        let apps = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateError.invalidBundle("expected one app in the archive, found \(apps.count)") }
        return apps[0]
    }

    /// Same app, and actually the advertised, newer version.
    public static func validateBundle(_ app: URL, expectedVersion: SemanticVersion, environment env: Environment) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary else { throw UpdateError.invalidBundle("no Info.plist") }
        guard bundle.bundleIdentifier == env.bundleIdentifier else {
            throw UpdateError.invalidBundle("bundle identifier \(bundle.bundleIdentifier ?? "none") doesn't match \(env.bundleIdentifier)")
        }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init), version == expectedVersion else {
            throw UpdateError.invalidBundle("the app inside isn't version \(expectedVersion)")
        }
        if let current = env.version, version <= current {
            throw UpdateError.invalidBundle("version \(version) isn't newer than the installed \(current)")
        }
    }

    static func requirement(teamIdentifier: String, bundleIdentifier: String) -> String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// The new bundle must be validly signed (all architectures, nested code, strict) by our own team.
    public static func verifySignature(of app: URL, environment env: Environment) throws {
        guard let team = env.teamIdentifier else { throw UpdateError.signatureInvalid("This copy has no Team ID to compare against.") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signatureInvalid("The app couldn't be read.")
        }
        let text = requirement(teamIdentifier: team, bundleIdentifier: env.bundleIdentifier)
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &compiled) == errSecSuccess, let compiled else {
            throw UpdateError.signatureInvalid("Couldn't build the signing requirement.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var errors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, compiled, &errors)
        guard status == errSecSuccess else {
            let detail = errors?.takeRetainedValue().localizedDescription ?? "OSStatus \(status)"
            throw UpdateError.signatureInvalid(detail)
        }
    }

    /// Team ID from the running process's signature (nil when unsigned or ad hoc).
    static func teamIdentifier(ofRunningApp: Void) -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: Install

    /// Swaps the new bundle in place of the current one. The running process keeps its mapped code;
    /// the new version runs after relaunch.
    public static func install(_ app: URL, over env: Environment, fileManager: FileManager = .default) throws {
        let target = env.bundleURL
        // Stage next to the target so the final swap is a same-volume rename.
        let staged = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).update-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: app, to: staged)
            _ = try fileManager.replaceItemAt(target, withItemAt: staged, backupItemName: nil, options: [])
        } catch {
            try? fileManager.removeItem(at: staged)
            throw UpdateError.cannotInstall("Couldn't replace \(target.path): \(error.localizedDescription)")
        }
    }

    /// Opens the app at `bundleURL` once this process has exited.
    public static func relaunch(_ bundleURL: URL) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Arguments are passed positionally, never interpolated into the script.
        helper.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), bundleURL.path]
        try helper.run()
    }
}

/// GitHub serves private-repo assets via a redirect to a signed storage URL. The token must not
/// travel to that other host, and downloads must stay on https.
final class DownloadRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirect(from: task.originalRequest, to: request))
    }

    static func redirect(from original: URLRequest?, to request: URLRequest) -> URLRequest? {
        guard request.url?.scheme == "https" else { return nil }
        var next = request
        if request.url?.host?.lowercased() != original?.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }
}
