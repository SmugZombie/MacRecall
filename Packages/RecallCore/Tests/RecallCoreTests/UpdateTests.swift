import Foundation
import Testing
@testable import RecallCore

@Suite struct SemanticVersionTests {
    @Test func parsing() {
        #expect(SemanticVersion("v1.0.1") == SemanticVersion(major: 1, minor: 0, patch: 1))
        #expect(SemanticVersion("2.3") == SemanticVersion(major: 2, minor: 3, patch: 0))
        #expect(SemanticVersion("1.2.3-beta.2+build.7")?.prerelease == ["beta", "2"])
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1.-2.0") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
    }

    @Test func ordering() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
            .compactMap(SemanticVersion.init)
        #expect(ordered.count == 9)
        #expect(ordered == ordered.sorted())
        #expect(SemanticVersion("1.0.10")! > SemanticVersion("1.0.9")!)  // numeric, not lexical
    }
}

/// Builds a minimal app bundle (unsigned) for installer tests.
func makeFakeApp(in dir: URL, name: String = "RecallForMac", identifier: String = "dev.macrecall.RecallForMac", version: String) throws -> URL {
    let app = dir.appendingPathComponent("\(name).app")
    let contents = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                "CFBundleExecutable": name, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent(name))
    return app
}

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recall-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct UpdateInstallerTests {
    let env = UpdateInstaller.Environment(bundleURL: URL(fileURLWithPath: "/Applications/RecallForMac.app"),
                                          bundleIdentifier: "dev.macrecall.RecallForMac",
                                          version: SemanticVersion("1.0.1"), teamIdentifier: "2D6A77NN3X")

    @Test func parsesReleaseAndPicksAppAsset() throws {
        let json: [String: Any] = [
            "tag_name": "v1.0.2", "name": "Recall for macOS 1.0.2", "body": "## Fixes", "html_url": "https://github.com/o/r/releases/tag/v1.0.2",
            "published_at": "2026-10-20T10:00:00Z",
            "assets": [
                ["name": "notes.txt", "url": "https://api.github.com/a/1", "browser_download_url": "https://github.com/d/notes.txt", "size": 3],
                ["name": "RecallForMac-1.0.2.zip", "url": "https://api.github.com/a/2", "browser_download_url": "https://github.com/d/r.zip",
                 "size": 2_600_000, "digest": "sha256:ABCDEF"],
            ],
        ]
        let release = try GitHubReleaseClient.parse(JSONSerialization.data(withJSONObject: json))
        #expect(release.version == SemanticVersion("1.0.2"))
        #expect(release.asset?.name == "RecallForMac-1.0.2.zip")
        #expect(release.asset?.sha256 == "abcdef")
        #expect(release.publishedAt != nil)
        #expect(throws: UpdateError.self) { try GitHubReleaseClient.parse(Data(#"{"tag_name":"nightly","html_url":"https://x"}"#.utf8)) }
    }

    @Test func credentialsAreStrippedOnCrossHostRedirectAndHTTPIsRefused() {
        var original = URLRequest(url: URL(string: "https://api.github.com/repos/o/r/releases/assets/1")!)
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        var sameHost = original
        sameHost.url = URL(string: "https://api.github.com/other")
        #expect(DownloadRedirectGuard.redirect(from: original, to: sameHost)?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        var storage = original
        storage.url = URL(string: "https://objects.githubusercontent.com/signed?x=1")
        let next = DownloadRedirectGuard.redirect(from: original, to: storage)
        #expect(next != nil && next?.value(forHTTPHeaderField: "Authorization") == nil)
        var plain = original
        plain.url = URL(string: "http://objects.githubusercontent.com/signed")
        #expect(DownloadRedirectGuard.redirect(from: original, to: plain) == nil)
    }

    @Test func checksum() throws {
        let file = try tempDir().appendingPathComponent("x.zip")
        try Data("hello".utf8).write(to: file)
        let digest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(try UpdateInstaller.sha256(of: file) == digest)
        try UpdateInstaller.verifyChecksum(file, expected: digest.uppercased())
        try UpdateInstaller.verifyChecksum(file, expected: nil)  // no published digest: signature check still applies
        #expect(throws: UpdateError.checksumMismatch) { try UpdateInstaller.verifyChecksum(file, expected: String(repeating: "0", count: 64)) }
    }

    @Test func extractsAndValidatesBundle() throws {
        let dir = try tempDir()
        let src = try tempDir()
        _ = try makeFakeApp(in: src, version: "1.0.2")
        let zip = dir.appendingPathComponent("RecallForMac-1.0.2.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", src.appendingPathComponent("RecallForMac.app").path, zip.path]
        try ditto.run(); ditto.waitUntilExit()

        let app = try UpdateInstaller.extractApp(from: zip)
        try UpdateInstaller.validateBundle(app, expectedVersion: SemanticVersion("1.0.2")!, environment: env)
        #expect(throws: UpdateError.self) { try UpdateInstaller.validateBundle(app, expectedVersion: SemanticVersion("1.0.3")!, environment: env) }
        var older = env
        older.version = SemanticVersion("1.0.2")
        #expect(throws: UpdateError.self) { try UpdateInstaller.validateBundle(app, expectedVersion: SemanticVersion("1.0.2")!, environment: older) }
        var other = env
        other.bundleIdentifier = "com.example.Other"
        #expect(throws: UpdateError.self) { try UpdateInstaller.validateBundle(app, expectedVersion: SemanticVersion("1.0.2")!, environment: other) }
        #expect(throws: UpdateError.self) { try UpdateInstaller.extractApp(from: dir.appendingPathComponent("missing.zip")) }
    }

    @Test func rejectsUnsignedAndForeignSignatures() throws {
        let unsigned = try makeFakeApp(in: try tempDir(), version: "1.0.2")
        #expect(throws: UpdateError.self) { try UpdateInstaller.verifySignature(of: unsigned, environment: env) }
        // Validly signed, but by Apple rather than our team and with another identifier.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        if FileManager.default.fileExists(atPath: calculator.path) {
            #expect(throws: UpdateError.self) { try UpdateInstaller.verifySignature(of: calculator, environment: env) }
        }
        var noTeam = env
        noTeam.teamIdentifier = nil
        #expect(throws: UpdateError.self) { try UpdateInstaller.verifySignature(of: unsigned, environment: noTeam) }
    }

    @Test func requirementPinsTeamAndIdentifier() {
        #expect(UpdateInstaller.requirement(teamIdentifier: "2D6A77NN3X", bundleIdentifier: "dev.macrecall.RecallForMac") ==
            #"anchor apple generic and identifier "dev.macrecall.RecallForMac" and certificate leaf[subject.OU] = "2D6A77NN3X""#)
    }

    @Test func eligibility() throws {
        let dir = try tempDir()
        let app = try makeFakeApp(in: dir, version: "1.0.1")
        var e = env
        e.bundleURL = app
        #expect(UpdateInstaller.eligibility(e) == .eligible)
        e.teamIdentifier = nil
        if case .eligible = UpdateInstaller.eligibility(e) { Issue.record("unsigned copy must not self-update") }
        e = env
        e.bundleURL = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/X/Build/Products/Debug/RecallForMac.app")
        if case .eligible = UpdateInstaller.eligibility(e) { Issue.record("development build must not self-update") }
        e.bundleURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")  // not writable
        if case .eligible = UpdateInstaller.eligibility(e) { Issue.record("unwritable location must not self-update") }
    }

    @Test func installSwapsBundleInPlace() throws {
        let dir = try tempDir()
        let current = try makeFakeApp(in: dir, version: "1.0.1")
        let newer = try makeFakeApp(in: try tempDir(), version: "1.0.2")
        var e = env
        e.bundleURL = current
        try UpdateInstaller.install(newer, over: e)
        #expect(Bundle(url: current)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.0.2")
        // No staging leftovers next to the app.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["RecallForMac.app"])
    }
}

extension ProviderTests {
    // Lives in the serialized provider suite because it shares MockURLProtocol.

    func releaseJSON(_ tag: String) -> [String: Any] {
        ["tag_name": tag, "html_url": "https://github.com/o/r/releases/tag/\(tag)", "body": "notes",
         "assets": [["name": "RecallForMac-\(tag).zip", "url": "https://api.github.com/repos/o/r/releases/assets/9",
                     "browser_download_url": "https://github.com/o/r/releases/download/\(tag)/RecallForMac.zip", "size": 5]]]
    }

    @Test func releaseClientHandlesResponses() async throws {
        MockURLProtocol.reset([(200, [:], releaseJSON("v1.0.2"))])
        let client = GitHubReleaseClient(repository: "o/r", configuration: MockURLProtocol.configuration)
        let release = try await client.latestRelease()
        #expect(release.version == SemanticVersion("1.0.2"))
        let req = MockURLProtocol.captured[0].request
        #expect(req.url?.absoluteString == "https://api.github.com/repos/o/r/releases/latest")
        // The repository is public: no credentials are ever sent.
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)

        MockURLProtocol.reset([(404, [:], ["message": "Not Found"])])
        await #expect(throws: UpdateError.notFound("o/r")) {
            _ = try await GitHubReleaseClient(repository: "o/r", configuration: MockURLProtocol.configuration).latestRelease()
        }

        MockURLProtocol.reset([(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "2000000000"], ["message": "rate limited"])])
        await #expect(throws: UpdateError.rateLimited(Date(timeIntervalSince1970: 2_000_000_000))) {
            _ = try await GitHubReleaseClient(repository: "o/r", configuration: MockURLProtocol.configuration).latestRelease()
        }

        MockURLProtocol.reset([(403, [:], ["message": "Forbidden"])])
        await #expect(throws: UpdateError.http(403)) {
            _ = try await GitHubReleaseClient(repository: "o/r", configuration: MockURLProtocol.configuration).latestRelease()
        }
    }

    @Test func downloadUsesThePublicLinkAndChecksSize() async throws {
        let asset = ReleaseAsset(name: "RecallForMac-1.0.2.zip",
                                 browserURL: URL(string: "https://github.com/o/r/releases/download/v1.0.2/RecallForMac-1.0.2.zip")!,
                                 size: 2, digest: nil)
        MockURLProtocol.responses = [(200, [:], Data([0x50, 0x4B]))]
        MockURLProtocol.captured = []
        let progress = ProgressBox()
        let file = try await UpdateInstaller().download(asset, configuration: MockURLProtocol.configuration) { progress.value = $0 }
        #expect(try Data(contentsOf: file) == Data([0x50, 0x4B]))
        #expect(progress.value == 1)
        let req = MockURLProtocol.captured[0].request
        #expect(req.url == asset.browserURL)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)

        // A truncated download is rejected.
        MockURLProtocol.responses = [(200, [:], Data([1]))]
        await #expect(throws: UpdateError.self) {
            _ = try await UpdateInstaller().download(asset, configuration: MockURLProtocol.configuration) { _ in }
        }
    }
}

final class ProgressBox: @unchecked Sendable {
    var value: Double = 0
}
