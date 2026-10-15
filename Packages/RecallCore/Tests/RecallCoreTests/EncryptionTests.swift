import CoreGraphics
import Foundation
import Testing
@testable import RecallCore

/// A keychain that has keys but refuses to hand them over (locked, or a denied prompt).
private final class FailingKeyStore: ScreenshotKeyStore, @unchecked Sendable {
    struct Locked: Error {}
    var saves = 0
    var loads = 0
    func loadKeys() throws -> [Data] { loads += 1; throw Locked() }
    func saveKeys(_ keys: [Data]) throws { saves += 1 }
}

@Suite struct ScreenshotVaultTests {
    func jpeg() throws -> Data {
        let image = ImageProcessing.draw(width: 64, height: 40) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        }!
        return try ImageProcessing.encode(image, format: .jpeg, quality: 0.8)
    }

    @Test func roundTripsAndIsUnreadableOnDisk() throws {
        let store = try makeStore()
        let data = try jpeg()
        try store.vault.write(data, to: "screenshots/a.jpg")
        let onDisk = try Data(contentsOf: store.paths.absolute("screenshots/a.jpg"))
        #expect(ScreenshotVault.isSealed(onDisk))
        #expect(ImageProcessing.load(onDisk) == nil)
        #expect(try store.vault.read("screenshots/a.jpg") == data)
        #expect(try store.vault.image("screenshots/a.jpg").width == 64)
    }

    @Test func filesAreBoundToTheirPathAndTamperEvident() throws {
        let store = try makeStore()
        try store.vault.write(try jpeg(), to: "screenshots/a.jpg")
        let fm = FileManager.default
        try fm.copyItem(at: store.paths.absolute("screenshots/a.jpg"), to: store.paths.absolute("screenshots/b.jpg"))
        #expect(throws: ScreenshotVault.Failure.corrupt) { try store.vault.read("screenshots/b.jpg") }

        var bytes = try Data(contentsOf: store.paths.absolute("screenshots/a.jpg"))
        bytes[bytes.count - 20] ^= 0xFF
        try bytes.write(to: store.paths.absolute("screenshots/a.jpg"))
        #expect(throws: ScreenshotVault.Failure.corrupt) { try store.vault.read("screenshots/a.jpg") }
    }

    @Test func olderVersionsFilesStayReadableAndGetEncryptedLater() throws {
        let store = try makeStore()
        let data = try jpeg()
        #expect(try store.encryptStoredImages())
        #expect(try store.imagesEncrypted())
        // Written unencrypted after migration finished, by an older version running alongside or after a downgrade.
        let c = try addCapture(store, at: Date())
        try ImageProcessing.writeAtomically(data, to: store.paths.absolute(c.imagePath))
        #expect(try store.vault.read(c.imagePath) == data)
        #expect(try store.encryptStoredImages())
        #expect(ScreenshotVault.isSealed(try Data(contentsOf: store.paths.absolute(c.imagePath))))
        #expect(try store.vault.read(c.imagePath) == data)
    }

    @Test func lostKeyIsRecoveredByImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-tests-\(UUID().uuidString)")
        let original = try RecallStore(inMemoryWithRoot: root)
        let data = try jpeg()
        try original.vault.write(data, to: "screenshots/a.jpg")
        let recovery = try original.vault.exportRecoveryKey()

        // Same library, empty keychain: new captures get a new key, old ones stay locked.
        let reset = try RecallStore(inMemoryWithRoot: root, keyStore: InMemoryScreenshotKeyStore())
        #expect(throws: ScreenshotVault.Failure.missingKey) { try reset.vault.read("screenshots/a.jpg") }
        try reset.vault.write(data, to: "screenshots/new.jpg")

        #expect(try reset.vault.importRecoveryKey("notes\n" + recovery) == 1)
        #expect(try reset.vault.importRecoveryKey(recovery) == 0)
        #expect(try reset.vault.read("screenshots/a.jpg") == data)
        #expect(try reset.vault.read("screenshots/new.jpg") == data)
        // The newer key keeps encrypting: the original keyring can't read new files.
        try reset.vault.write(data, to: "screenshots/newer.jpg")
        #expect(throws: ScreenshotVault.Failure.missingKey) { try original.vault.read("screenshots/newer.jpg") }

        #expect(throws: ScreenshotVault.Failure.invalidRecoveryKey) { try reset.vault.importRecoveryKey("recall-key-v1:short") }
    }

    @Test func unreadableKeychainIsNeverReplacedWithANewKey() throws {
        let keys = FailingKeyStore()
        let store = try RecallStore(inMemoryWithRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-tests-\(UUID().uuidString)"), keyStore: keys)
        #expect(throws: ScreenshotVault.Failure.self) { try store.vault.write(try jpeg(), to: "screenshots/a.jpg") }
        #expect(keys.saves == 0)
        // Retrying right away doesn't ask the keychain (and the user) again.
        #expect(throws: ScreenshotVault.Failure.self) { try store.vault.write(try jpeg(), to: "screenshots/b.jpg") }
        #expect(keys.loads == 1)
        #expect(!FileManager.default.fileExists(atPath: store.paths.absolute("screenshots/a.jpg").path))
    }

    @Test func migrationEncryptsExistingFilesInBatches() throws {
        let store = try makeStore()
        let data = try jpeg()
        var captures: [CaptureRecord] = []
        for i in 0..<3 {
            let c = try addCapture(store, at: Date().addingTimeInterval(Double(i)))
            try ImageProcessing.writeAtomically(data, to: store.paths.absolute(c.imagePath))
            try ImageProcessing.writeAtomically(data, to: store.paths.absolute(c.thumbnailPath))
            captures.append(c)
        }
        // A capture whose files were already deleted doesn't stop migration.
        try addCapture(store, at: Date().addingTimeInterval(10))

        #expect(try store.encryptStoredImages(limit: 2) == false)
        #expect(try !store.imagesEncrypted())
        #expect(try store.encryptStoredImages(limit: 2) == false)
        #expect(try store.encryptStoredImages(limit: 2) == true)
        #expect(try store.imagesEncrypted())
        for c in captures {
            for rel in [c.imagePath, c.thumbnailPath] {
                #expect(ScreenshotVault.isSealed(try Data(contentsOf: store.paths.absolute(rel))))
                #expect(try store.vault.read(rel) == data)
            }
        }
    }
}
