# TODO

## Encrypt the database

Screenshots and thumbnails are encrypted at rest since 1.1.0, but `Data.noindex/recall.sqlite` is still plain
SQLite. It holds recognized text, AI descriptions, window titles, session summaries and embeddings, which are
arguably more sensitive than the images because they're searchable.

- Replace the system SQLite with SQLCipher so FTS5 search keeps working.
- Keep the database key in the same keychain keyring as the screenshot keys, and cover it with the recovery key.
- Migrate existing databases with `sqlcipher_export`, keeping a plain copy only until the encrypted one verifies.
- The MCP server (`RecallForMac --mcp`) opens the database read-only; it will need the key too.

Background and limits: [design/screenshot-encryption.md](design/screenshot-encryption.md) (step 2 of the suggested order).

## Share note attachments through MCP

`get_note` lists attachments by name, type and size but never returns their contents. Images could come back as MCP
image content and text files as text, behind their own opt-in like screenshots; other types would stay listed only.

