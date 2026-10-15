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

## View screenshots through MCP

Agents can read a capture's text but not its screenshot (`get_capture` says the image stays in Recall). Add a
`get_screenshot` tool that returns the image as MCP `image` content, so an agent can look at what was on screen.

- **Separate opt-in.** Images reveal more than the redacted text, and they go to the agent's model provider. Add its own
  toggle under Settings → Privacy → AI agent access, off by default, and refuse the tool while it's off.
- **Keychain.** The `--mcp` process decrypts through `ScreenshotVault`. It's the same binary, so the keychain should hand
  it the key without a prompt; verify with a release build. If the key is unavailable, return a clear error.
- **Size.** Downscale (e.g. `maxPixel` 1600) and send JPEG to keep responses small; offer the thumbnail as a cheaper option.
- Redaction already blacks out sensitive lines in the stored image, so no extra pass is needed.
- Update the server instructions, `get_capture`'s screenshot line, the README tool table and the tests.
