import CoreGraphics
import CryptoKit
import Foundation

/// Where the screenshot keys live. The newest key encrypts new files; older ones stay for reading.
public protocol ScreenshotKeyStore: Sendable {
    /// Returns an empty list when no key has been created yet, and throws when keys exist but can't be read.
    func loadKeys() throws -> [Data]
    func saveKeys(_ keys: [Data]) throws
}

/// One login-keychain item, readable without a prompt only by builds signed like this one.
public struct KeychainScreenshotKeyStore: ScreenshotKeyStore {
    static let account = "screenshots.keyring"

    public init() {}

    public func loadKeys() throws -> [Data] {
        guard let data = try Keychain.data(account: Self.account) else { return [] }
        guard let keys = try? JSONDecoder().decode([Data].self, from: data) else { throw ScreenshotVault.Failure.unreadableKeyring }
        return keys
    }

    public func saveKeys(_ keys: [Data]) throws {
        try Keychain.setData(try JSONEncoder().encode(keys), account: Self.account)
    }
}

/// For tests and previews.
public final class InMemoryScreenshotKeyStore: ScreenshotKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Data]

    public init(keys: [Data] = []) { self.keys = keys }

    public func loadKeys() throws -> [Data] { lock.withLock { keys } }
    public func saveKeys(_ keys: [Data]) throws { lock.withLock { self.keys = keys } }
}

/// Encrypts screenshots and thumbnails at rest so other programs can't read them off disk.
///
/// File layout: `RCE1` + 8-byte key ID + AES-GCM combined box (nonce, ciphertext, tag). The file's
/// path inside the library is authenticated, so encrypted files can't be swapped for one another.
/// Decrypted images only ever exist in memory.
public final class ScreenshotVault: @unchecked Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        /// The keychain couldn't be read or written; nothing was stored unencrypted.
        case keyUnavailable(String)
        /// Encrypted with a key that isn't on this Mac. Importing its recovery key restores access.
        case missingKey
        case corrupt
        case unreadableKeyring
        case invalidRecoveryKey

        public var errorDescription: String? {
            switch self {
            case .keyUnavailable(let reason): return "The screenshot encryption key is unavailable. \(reason)"
            case .missingKey: return "This screenshot was encrypted with a key that isn't on this Mac. Import its recovery key in Settings → Privacy."
            case .corrupt: return "The screenshot file is damaged or was modified."
            case .unreadableKeyring: return "The screenshot keys in the keychain are unreadable."
            case .invalidRecoveryKey: return "The file doesn't contain a Recall recovery key."
            }
        }
    }

    static let magic = Data("RCE1".utf8)
    static let keyIDLength = 8
    static let recoveryPrefix = "recall-key-v1:"

    public let paths: StoragePaths
    private let keyStore: any ScreenshotKeyStore
    private let lock = NSLock()
    private var cached: (current: Data, keys: [Data: SymmetricKey])?
    /// A denied keychain prompt would otherwise reappear on every capture.
    private var lastFailure: (error: Failure, at: Date)?
    static let retryInterval: TimeInterval = 60

    public init(paths: StoragePaths, keyStore: any ScreenshotKeyStore) {
        self.paths = paths
        self.keyStore = keyStore
    }

    // MARK: Files

    public func write(_ data: Data, to relativePath: String) throws {
        try ImageProcessing.writeAtomically(try seal(data, path: relativePath), to: paths.absolute(relativePath))
    }

    public func read(_ relativePath: String) throws -> Data {
        try open(try Data(contentsOf: paths.absolute(relativePath)), path: relativePath)
    }

    public func image(_ relativePath: String, maxPixel: Int? = nil) throws -> CGImage {
        guard let image = ImageProcessing.load(try read(relativePath), maxPixel: maxPixel) else { throw Failure.corrupt }
        return image
    }

    /// Encrypts an unencrypted file in place. Returns false if it was already encrypted.
    @discardableResult
    func encryptInPlace(_ relativePath: String) throws -> Bool {
        let url = paths.absolute(relativePath)
        // Most files are already encrypted; the header answers that without reading the image.
        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: Self.magic.count) ?? Data()
        try handle.close()
        guard !Self.isSealed(header) else { return false }
        try write(try Data(contentsOf: url), to: relativePath)
        return true
    }

    // MARK: Encryption

    static func isSealed(_ data: Data) -> Bool { data.starts(with: magic) }

    static func keyID(_ key: Data) -> Data { Data(SHA256.hash(data: key).prefix(keyIDLength)) }

    func seal(_ data: Data, path: String) throws -> Data {
        let (id, key) = try currentKey()
        guard let box = try AES.GCM.seal(data, using: key, authenticating: Data(path.utf8)).combined else { throw Failure.corrupt }
        return Self.magic + id + box
    }

    func open(_ data: Data, path: String) throws -> Data {
        // Written before encryption, or by an older version since; migration encrypts it later.
        guard Self.isSealed(data) else { return data }
        let headerEnd = data.startIndex + Self.magic.count + Self.keyIDLength
        guard data.count > Self.magic.count + Self.keyIDLength else { throw Failure.corrupt }
        let id = Data(data[(data.startIndex + Self.magic.count)..<headerEnd])
        guard let key = try keyring().keys[id] else { throw Failure.missingKey }
        do {
            let box = try AES.GCM.SealedBox(combined: data[headerEnd...])
            return try AES.GCM.open(box, using: key, authenticating: Data(path.utf8))
        } catch {
            throw Failure.corrupt
        }
    }

    // MARK: Keys

    private func currentKey() throws -> (Data, SymmetricKey) {
        let ring = try keyring()
        return (ring.current, ring.keys[ring.current]!)
    }

    /// Loads the keys once. Only a keychain that has no keys at all gets a new one; read errors are
    /// reported, never answered with a fresh key that would replace the real one.
    private func keyring() throws -> (current: Data, keys: [Data: SymmetricKey]) {
        try lock.withLock {
            if let cached { return cached }
            if let lastFailure, Date().timeIntervalSince(lastFailure.at) < Self.retryInterval { throw lastFailure.error }
            var stored: [Data]
            do {
                stored = try keyStore.loadKeys()
                if stored.isEmpty {
                    stored = [SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }]
                    try keyStore.saveKeys(stored)
                }
            } catch {
                let failure = error as? Failure ?? .keyUnavailable(error.localizedDescription)
                lastFailure = (failure, Date())
                throw failure
            }
            lastFailure = nil
            let ring = (current: Self.keyID(stored.last!),
                        keys: Dictionary(stored.map { (Self.keyID($0), SymmetricKey(data: $0)) }, uniquingKeysWith: { a, _ in a }))
            cached = ring
            return ring
        }
    }

    // MARK: Recovery

    /// Every key, so screenshots from before a reset can be opened too. Anyone holding this text
    /// and a copy of the library can view the screenshots.
    public func exportRecoveryKey() throws -> String {
        _ = try keyring()
        let keys = try keyStore.loadKeys()
        return """
        Recall for Mac — screenshot recovery key
        Keep this file private. Anyone with it and a copy of your Recall library can view your screenshots.
        Import it in Recall → Settings → Privacy → Screenshot encryption.

        \(keys.map { Self.recoveryPrefix + $0.base64EncodedString() }.joined(separator: "\n"))

        """
    }

    /// Adds the keys in an exported recovery key. Returns how many weren't already on this Mac.
    @discardableResult
    public func importRecoveryKey(_ text: String) throws -> Int {
        let imported = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(Self.recoveryPrefix) }
            .compactMap { Data(base64Encoded: String($0.dropFirst(Self.recoveryPrefix.count))) }
            .filter { $0.count == 32 }
        guard !imported.isEmpty else { throw Failure.invalidRecoveryKey }
        _ = try keyring()
        return try lock.withLock {
            let existing = try keyStore.loadKeys()
            let known = Set(existing.map(Self.keyID))
            var seen = known
            let added = imported.filter { seen.insert(Self.keyID($0)).inserted }
            guard !added.isEmpty else { return 0 }
            // Imported keys go first so the newest key on this Mac keeps encrypting new files.
            try keyStore.saveKeys(added + existing)
            cached = nil
            lastFailure = nil
            return added.count
        }
    }
}
