import Foundation

extension RecallStore {
    static let imagesEncryptedKey = "images_encrypted"
    static let imageEncryptionCursorKey = "image_encryption_cursor"

    /// True once screenshots from before encryption have been encrypted.
    public func imagesEncrypted() throws -> Bool {
        try setting(Self.imagesEncryptedKey) == "1"
    }

    /// Encrypts up to `limit` captures' unencrypted files, oldest first, resuming where the last call
    /// stopped. Returns false while captures remain. Keeps covering new captures after the first full
    /// pass, because an older version of Recall (after a downgrade, or running alongside) writes
    /// unencrypted files.
    @discardableResult
    public func encryptStoredImages(limit: Int = 200) throws -> Bool {
        let cursor = Int64(try setting(Self.imageEncryptionCursorKey) ?? "") ?? 0
        let rows = try db.query("SELECT id, image_path, thumbnail_path FROM captures WHERE id > ? ORDER BY id LIMIT ?",
                                [cursor, limit])
        for row in rows {
            for key in ["image_path", "thumbnail_path"] {
                guard let rel = row.string(key), !rel.isEmpty,
                      FileManager.default.fileExists(atPath: paths.absolute(rel).path) else { continue }
                do {
                    try vault.encryptInPlace(rel)
                } catch let failure as ScreenshotVault.Failure {
                    // Without a key nothing can be encrypted; stop and retry later rather than skip files.
                    throw failure
                } catch {
                    // An unreadable file can't leak anything; it stays as it is.
                    continue
                }
            }
            try setSetting(Self.imageEncryptionCursorKey, String(row.int("id")!))
        }
        guard rows.count < limit else { return false }
        if try !imagesEncrypted() { try setSetting(Self.imagesEncryptedKey, "1") }
        return true
    }
}
