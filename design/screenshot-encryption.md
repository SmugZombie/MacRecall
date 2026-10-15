# Proposal: encrypt screenshots so only Recall can read them

**Status:** step 1 (screenshot and thumbnail encryption, migration, recovery keys) is implemented on the
`screenshot-encryption` branch. Database encryption and Touch ID are not started.

## Problem

Recall isn't sandboxed, so any program running as the user can silently read
`~/Library/Application Support/RecallForMac/Data.noindex/screenshots` and `thumbnails`.
FileVault only protects the disk while the Mac is off or before login.

Windows Recall was criticized for this in 2024, when a simple tool copied its history straight
off disk. Malware that steals browser data and wallets commonly sweeps `Application Support`
the same way.

## Proposed design

- **One key per install.** On first launch, Recall creates a random 256-bit key and stores it
  in the login keychain, next to the API keys (`Utilities/Keychain.swift`). It is stored with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it isn't synced to iCloud.
- **Encryption.** AES-GCM from CryptoKit, so there's no new dependency. File layout:
  `"RCE1"` magic + 12-byte nonce + ciphertext + 16-byte tag. The file's relative path is
  passed as additional authenticated data, so files can't be swapped. Overhead is 28 bytes per
  file plus a 4-byte header, and processing time is negligible on Apple silicon.
- **Where the change goes.** All image I/O goes through two places:
  - Write: `ImageProcessing.writeAtomically`, called from `CaptureCoordinator` for the
    screenshot and the thumbnail.
  - Read: `ImageProcessing.load`, used by `StoredImage` in the UI and by OCR in
    `JobProcessor`, and `ImageProcessing.jpegForModel`, used for vision analysis.

  Decrypt into memory and build the image from `Data`. Never write decrypted temp files.
- **Migration.** Readers accept both encrypted and plain files (checked by the magic header).
  A resumable background job encrypts existing files in place, with an atomic write per file.
  It's safe to interrupt.

## What it protects against, and what it doesn't

**Protects against:**
- Other programs copying screenshots off disk. They'd need the key, and the keychain only gives
  it to Recall without asking. Any other program triggers a macOS "wants to use your
  confidential information" prompt.
- The screenshots folder ending up in a backup, a sync tool, a support upload, or a copy to
  another drive.
- Other user accounts on the Mac, and Finder or Quick Look previews.

**Doesn't protect against:**
- The user clicking **Allow** on that keychain prompt, or anything with root access.
- Malware with Screen Recording permission. It can capture the screen itself.
- Images already sent to a cloud AI provider.
- **The database, which is the bigger gap.** OCR text, AI descriptions, window titles and
  summaries stay in plain text in SQLite. They're arguably more sensitive than the images,
  because they're searchable.

## Open decisions

1. **Scope: screenshots only, or the database too?** Encrypting the database means replacing the
   system SQLite with SQLCipher, an encrypted build of SQLite that keeps full-text search
   working. It's a bigger change.
   *Leaning:* screenshots first, the database in a later release.
2. **Touch ID.** Should opening Recall require Touch ID (LocalAuthentication)? That controls who
   can open the app, not who can read the files.
   The stronger version requires Touch ID to unlock the key itself. It needs the Data Protection
   keychain or a Secure Enclave key, which means adding a provisioning profile to the build.
   Releases are signed with a Developer ID today, with no provisioning profile.
3. **What happens if the key is lost?** If the keychain item is deleted, or the user moves to a
   new Mac without carrying the keychain over, the screenshots can't be recovered. Options:
   - Accept the loss. It's the most private option.
   - Add **Export recovery key…**, so the user keeps a copy of the key somewhere safe.

   *Leaning:* add the export option.
4. **Signing identity and keychain prompts.** The keychain only gives the key to builds signed
   with the same identity. Switching between Apple Development debug builds and Developer ID
   releases will prompt once for keychain access. Updates installed through the app keep working
   with no prompt. Ad hoc builds will prompt after every rebuild.

## As built (step 1)

- `Privacy/ScreenshotVault.swift` holds a keyring: a list of keys stored in one keychain item
  (`screenshots.keyring`). The newest key encrypts new files. The file header carries an 8-byte key ID
  (a SHA-256 prefix), so files encrypted with older or imported keys stay readable.
- If the keychain has no keyring, a new key is created. If the keychain can't be read, Recall reports
  it and never replaces the keyring. Captures fail instead of being written unencrypted. Keychain writes
  update in place.
- If the key is lost, new captures get a new key and keep working. Older screenshots show a lock until
  their recovery key is imported (Settings → Privacy → Screenshot encryption).
- Migration (`RecallStore.encryptStoredImages`) runs at launch and hourly in batches of 100, resuming
  from a saved cursor. It keeps covering new captures afterwards, because an older version (after a
  downgrade, or running alongside) writes unencrypted files. Unencrypted files stay readable until then.
- "Open in Preview" and "Reveal in Finder" are replaced by an in-app full-size viewer and
  **Export Screenshot…**, which writes a decrypted copy where the user chooses.

## Suggested order

1. Screenshot and thumbnail encryption, the migration job, and **Export recovery key…**
2. Database encryption with SQLCipher.
3. Optional Touch ID: first a lock on opening the app, then requiring Touch ID to unlock the key
   once a provisioning profile is added.
