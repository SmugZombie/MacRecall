# Recall for macOS

A native, local-first activity history for macOS. Recall captures the **focused window** at a regular interval, extracts text with Apple Vision, groups captures into work sessions, and makes everything searchable — by keyword out of the box, and semantically when a local [Ollama](https://ollama.com) server is available.

Everything is stored under `~/Library/Application Support/RecallForMac/`. There is no telemetry, account or cloud sync; the only network traffic is to the Ollama endpoint you configure.

## Build & run

Requirements: macOS 14+, Xcode 16+ (developed with Xcode 27).

```sh
open RecallForMac.xcodeproj          # then Run (⌘R)
# or
xcodebuild -project RecallForMac.xcodeproj -scheme RecallForMac build
```

Core logic tests (SwiftPM):

```sh
cd Packages/RecallCore && swift test
```

> **Signing:** the project signs ad hoc ("Sign to Run Locally"). macOS ties Screen Recording and Accessibility grants to the code signature, so with ad hoc signing you may need to re-grant permissions after rebuilding. Set your Development Team in the target's Signing settings to avoid this.

On first launch Recall shows a setup window for **Screen Recording** (required) and **Accessibility** (recommended, for exact focused-window identification). It lives in the menu bar; closing the window keeps recording. Toggle recording anywhere with **⌃⌥⌘P**.

### Optional: AI with Ollama

```sh
ollama pull qwen2.5vl        # vision: describes screenshots
ollama pull llama3.2         # summary: session titles, daily overviews, Q&A
ollama pull nomic-embed-text # embedding: semantic search
```

Pick the models in **Settings → AI**. Recall never downloads models itself. With no vision model, the summary model analyzes recognized text only. If Ollama is offline, AI jobs wait in the durable queue; capture, OCR, timeline and keyword search keep working.

## Architecture

```
RecallForMac.xcodeproj
RecallForMac/                 SwiftUI app target (thin)
  App/                        RecallApp (MenuBarExtra + windows), AppState, global hot key
  UI/                         Timeline, Search, Projects, Summaries, Queue, Settings, Onboarding
Packages/RecallCore/          All logic, unit-tested with `swift test`
  Database/                   SQLite wrapper (WAL, FKs), migrations, FTS5 triggers, repositories
  Capture/                    ActiveWindowResolver, ScreenshotService (ScreenCaptureKit),
                              CaptureCoordinator, image encoding + perceptual dedupe
  Monitoring/                 App activation, lock/unlock, sleep/wake, idle, battery, secure input
  OCR/                        Apple Vision text recognition
  AI/                         OllamaService, structured-output validation, JobProcessor, AIJobQueue
  Activity/                   Deterministic SessionBuilder, ProjectClassifier, daily summaries
  Search/                     Query interpretation, FTS5 search, vector index, hybrid RRF, grounded Q&A
  Privacy/                    CapturePolicy, sensitive-content redaction, retention
```

### Capture pipeline

1. **Policy first.** `CapturePolicy` checks pause state, lock/sleep, idle, battery, exclusions and secure keyboard input *before* any pixels are read.
2. **Focused window.** `ActiveWindowResolver` reads the focused window through Accessibility and matches it to an `SCWindow` by frame and title. Without Accessibility it uses the frontmost on-screen window of the active process (CGWindowList z-order). If no window can be identified the capture is skipped and the reason logged — it never falls back to a full-display screenshot.
3. **Capture.** `SCScreenshotManager` with a `desktopIndependentWindow` filter; ScreenCaptureKit downsizes to the configured maximum.
4. **Dedupe.** A 64-bit dHash *plus* a 32×32 luminance grid. dHash alone misses small text changes (a new terminal line); the grid catches them. Unchanged frames extend the previous capture's `last_seen_at` instead of storing a new file.
5. **Redaction (if enabled).** OCR runs inline; lines matching sensitive-content rules are blacked out in the image and replaced in the text *before* anything is written.
6. **Persist** atomically (temp file + rename), then enqueue OCR / analysis / embedding jobs.

### Durable job queue

Jobs live in the `ai_jobs` table with a partial unique index so a pending/running job can't be queued twice. Workers claim by priority then recency (new and user-requested work jumps the backlog). Transient failures back off exponentially up to 5 attempts; an Ollama outage returns the job to the queue without spending an attempt. Jobs left `running` by a crash are recovered at startup.

### Sessions

`SessionBuilder` is deterministic and LLM-free: idle/lock/sleep interruptions and gaps split sessions; differing projects never share one; a *sustained* vocabulary change (two consecutive off-topic captures) starts a new session, while a single glance at chat or mail does not. AI results later add titles and summaries but never override a user's edits.

### Search

`HybridSearch` interprets dates ("before lunch yesterday", "last Tuesday") and app references ("terminal", "browser") into filters, runs FTS5 (BM25) and vector similarity, and fuses them with reciprocal-rank fusion. User input never reaches FTS5 raw: every term is quoted. "Ask" answers come from the summary model using only retrieved records; each claim must cite `[C<id>]`/`[S<id>]`, citations to records that were not supplied are stripped, and an answer without valid citations is reported as insufficient evidence.

## Status against the spec

| Phase | State |
|---|---|
| 1 Foundation | Done — menu bar, main window, settings persistence, onboarding, launch at login |
| 2 Capture | Done — needs manual validation on multi-monitor/Spaces setups |
| 3 Timeline & persistence | Done — sessions list, lazy thumbnails, scrubber, detail inspector, retention |
| 4 OCR & keyword search | Done |
| 5 Ollama | Done — model discovery & capability check, structured output, durable queue |
| 6 Sessions & summaries | Done — merge/split/rename/reassign, daily Markdown summaries |
| 7 Natural-language search | Done — hybrid retrieval, date interpretation, cited answers |
| 8 Release | Partial — see below |

### Known gaps

- **Encrypted storage** is not implemented. The system SQLite has no encryption; options are SQLCipher (adds a dependency) or encrypting image files with a Keychain-held key. Today the data relies on FileVault.
- **Vector search** is an exact streaming scan behind a `VectorIndex` protocol — fine for a single user's history (especially time-filtered), replaceable with sqlite-vec/HNSW later.
- **Notifications** and a configurable hot key are not implemented (the hot key is fixed to ⌃⌥⌘P).
- **Notarization**: hardened runtime is on, but distribution signing/notarization needs a Developer ID.
- Project "learning" is limited to rule matching plus the AI's project hint; there is no suggestion UI for new projects yet.
- On macOS 15+, the OS periodically re-asks the user to confirm continued screen recording for apps using ScreenCaptureKit. That is system behavior and can't be suppressed.
