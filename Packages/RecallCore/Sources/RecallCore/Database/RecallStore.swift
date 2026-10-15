import Foundation

/// On-disk layout under ~/Library/Application Support/RecallForMac/.
///
/// History lives in `Data.noindex/`: Spotlight skips folders ending in `.noindex`, and it would
/// otherwise index the screenshots, including the text it recognizes inside images.
public struct StoragePaths: Sendable {
    public let root: URL
    public var data: URL { root.appendingPathComponent("Data.noindex", isDirectory: true) }
    public var database: URL { data.appendingPathComponent("recall.sqlite") }
    public var screenshots: URL { data.appendingPathComponent("screenshots", isDirectory: true) }
    public var thumbnails: URL { data.appendingPathComponent("thumbnails", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }

    public init(root: URL) { self.root = root }

    public static var `default`: StoragePaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StoragePaths(root: base.appendingPathComponent("RecallForMac", isDirectory: true))
    }

    public func createDirectories() throws {
        try migrateLegacyLayout()
        for dir in [root, data, screenshots, thumbnails, logs, exports] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Belt and braces alongside the .noindex name.
        let marker = data.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        // Keep history out of Time Machine.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
    }

    /// Version 1.0.0 kept the database and images directly under `root`; move them into `data`.
    func migrateLegacyLayout() throws {
        let fm = FileManager.default
        let legacyDB = root.appendingPathComponent("recall.sqlite")
        guard fm.fileExists(atPath: legacyDB.path), !fm.fileExists(atPath: database.path) else { return }
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        for name in ["recall.sqlite", "recall.sqlite-wal", "recall.sqlite-shm", "screenshots", "thumbnails"] {
            let from = root.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: data.appendingPathComponent(name)) }
        }
    }

    /// Image paths are stored relative to `data` so the library can be moved.
    public func absolute(_ relative: String) -> URL { data.appendingPathComponent(relative) }
}

public struct TimelineFilter: Sendable, Equatable {
    public var bundleIdentifiers: Set<String> = []
    public var projectID: Int64?

    public init(bundleIdentifiers: Set<String> = [], projectID: Int64? = nil) {
        self.bundleIdentifiers = bundleIdentifiers
        self.projectID = projectID
    }
}

/// Repository facade over the SQLite database. Each domain lives in an extension.
public final class RecallStore: @unchecked Sendable {
    public let db: SQLiteDatabase
    public let paths: StoragePaths
    /// Reads and writes screenshots and thumbnails, encrypted at rest.
    public let vault: ScreenshotVault

    public init(paths: StoragePaths, keyStore: any ScreenshotKeyStore = KeychainScreenshotKeyStore()) throws {
        try paths.createDirectories()
        self.paths = paths
        self.db = try SQLiteDatabase(path: paths.database.path)
        self.vault = ScreenshotVault(paths: paths, keyStore: keyStore)
        try Migrations.migrate(db)
    }

    /// In-memory store for tests and previews.
    public init(inMemoryWithRoot root: URL, keyStore: any ScreenshotKeyStore = InMemoryScreenshotKeyStore()) throws {
        self.paths = StoragePaths(root: root)
        try paths.createDirectories()
        self.db = try SQLiteDatabase(path: ":memory:")
        self.vault = ScreenshotVault(paths: paths, keyStore: keyStore)
        try Migrations.migrate(db)
    }

    // MARK: Applications & windows

    @discardableResult
    public func upsertApplication(bundleIdentifier: String, name: String, at date: Date = Date()) throws -> Int64 {
        try db.transaction {
            try db.run("""
                INSERT INTO applications (bundle_identifier, name, first_seen, last_seen) VALUES (?, ?, ?, ?)
                ON CONFLICT(bundle_identifier) DO UPDATE SET name = excluded.name, last_seen = excluded.last_seen
                """, [bundleIdentifier, name, date, date])
            return try db.scalarInt("SELECT id FROM applications WHERE bundle_identifier = ?", [bundleIdentifier])
        }
    }

    @discardableResult
    public func upsertWindow(applicationID: Int64, systemWindowID: UInt32, title: String, at date: Date = Date()) throws -> Int64 {
        try db.transaction {
            try db.run("""
                INSERT INTO windows (application_id, system_window_id, title, first_seen, last_seen) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(application_id, system_window_id, title) DO UPDATE SET last_seen = excluded.last_seen
                """, [applicationID, Int64(systemWindowID), title, date, date])
            return try db.scalarInt(
                "SELECT id FROM windows WHERE application_id = ? AND system_window_id = ? AND title = ?",
                [applicationID, Int64(systemWindowID), title])
        }
    }

    public func applications() throws -> [ApplicationRecord] {
        try db.query("SELECT id, bundle_identifier, name FROM applications ORDER BY name COLLATE NOCASE").map {
            ApplicationRecord(id: $0.int("id")!, bundleIdentifier: $0.string("bundle_identifier") ?? "", name: $0.string("name") ?? "")
        }
    }

    // MARK: Captures

    static let captureSelect = """
        SELECT c.*, a.name AS app_name, a.bundle_identifier AS bundle_identifier, COALESCE(w.title, '') AS window_title
        FROM captures c
        JOIN applications a ON a.id = c.application_id
        LEFT JOIN windows w ON w.id = c.window_id
        """

    static func capture(from row: Row) -> CaptureRecord {
        CaptureRecord(
            id: row.int("id")!,
            applicationID: row.int("application_id") ?? 0,
            applicationName: row.string("app_name") ?? "",
            bundleIdentifier: row.string("bundle_identifier") ?? "",
            windowID: row.int("window_id"),
            windowTitle: row.string("window_title") ?? "",
            capturedAt: row.date("captured_at") ?? .distantPast,
            lastSeenAt: row.date("last_seen_at") ?? .distantPast,
            timezone: row.string("timezone") ?? TimeZone.current.identifier,
            imagePath: row.string("image_path") ?? "",
            thumbnailPath: row.string("thumbnail_path") ?? "",
            imageHash: row.string("image_hash") ?? "",
            width: Int(row.int("width") ?? 0),
            height: Int(row.int("height") ?? 0),
            ocrText: row.string("ocr_text") ?? "",
            ocrConfidence: row.double("ocr_confidence"),
            ocrStatus: ProcessingStatus(rawValue: row.string("ocr_status") ?? "") ?? .pending,
            aiStatus: ProcessingStatus(rawValue: row.string("ai_status") ?? "") ?? .pending,
            aiDescription: row.string("ai_description") ?? "",
            aiJSON: row.string("ai_json"),
            projectID: row.int("project_id"),
            sessionID: row.int("activity_session_id"),
            redacted: row.bool("redacted"))
    }

    @discardableResult
    public func insertCapture(_ new: NewCapture) throws -> CaptureRecord {
        let appID = try upsertApplication(bundleIdentifier: new.bundleIdentifier, name: new.applicationName, at: new.capturedAt)
        let windowID = try upsertWindow(applicationID: appID, systemWindowID: new.systemWindowID, title: new.windowTitle, at: new.capturedAt)
        let ocrStatus: ProcessingStatus = new.ocrText == nil ? .pending : .done
        let id = try db.insert("""
            INSERT INTO captures (application_id, window_id, captured_at, last_seen_at, timezone, pid, image_path,
                thumbnail_path, image_hash, width, height, ocr_text, ocr_confidence, ocr_status, redacted, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [appID, windowID, new.capturedAt, new.capturedAt, new.timezone, Int(new.pid), new.imagePath,
                  new.thumbnailPath, new.imageHash, new.width, new.height, new.ocrText ?? "", new.ocrConfidence,
                  ocrStatus.rawValue, new.redacted, new.metadataJSON])
        return try capture(id: id)!
    }

    /// Records that unchanged content was still visible, extending its duration.
    public func extendCapture(id: Int64, lastSeen: Date) throws {
        try db.run("UPDATE captures SET last_seen_at = MAX(last_seen_at, ?) WHERE id = ?", [lastSeen, id])
    }

    public func capture(id: Int64) throws -> CaptureRecord? {
        try db.queryOne("\(Self.captureSelect) WHERE c.id = ?", [id]).map(Self.capture(from:))
    }

    public func captures(ids: [Int64]) throws -> [CaptureRecord] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try db.query("\(Self.captureSelect) WHERE c.id IN (\(placeholders))", ids)
        let byID = Dictionary(uniqueKeysWithValues: rows.map(Self.capture(from:)).map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// A page of captures in a time range, newest first unless `ascending`.
    public func captures(from start: Date, to end: Date, filter: TimelineFilter = TimelineFilter(),
                         ascending: Bool = false, limit: Int = 200, offset: Int = 0) throws -> [CaptureRecord] {
        var sql = "\(Self.captureSelect) WHERE c.captured_at >= ? AND c.captured_at < ?"
        var params: [SQLBindable] = [start, end]
        if !filter.bundleIdentifiers.isEmpty {
            sql += " AND a.bundle_identifier IN (\(Array(repeating: "?", count: filter.bundleIdentifiers.count).joined(separator: ",")))"
            params += filter.bundleIdentifiers.sorted() as [SQLBindable]
        }
        if let projectID = filter.projectID {
            sql += " AND (c.project_id = ? OR c.activity_session_id IN (SELECT id FROM sessions WHERE project_id = ?))"
            params += [projectID, projectID]
        }
        sql += " ORDER BY c.captured_at \(ascending ? "ASC" : "DESC") LIMIT ? OFFSET ?"
        params += [limit, offset]
        return try db.query(sql, params).map(Self.capture(from:))
    }

    /// Lightweight (id, time, app) rows for scrubbing through a range without loading OCR text.
    public func captureMarks(from start: Date, to end: Date, limit: Int = 20000) throws -> [CaptureMark] {
        try db.query("""
            SELECT c.id, c.captured_at, a.name FROM captures c JOIN applications a ON a.id = c.application_id
            WHERE c.captured_at >= ? AND c.captured_at < ? ORDER BY c.captured_at LIMIT ?
            """, [start, end, limit]).map {
            CaptureMark(id: $0.int("id")!, capturedAt: $0.date("captured_at") ?? .distantPast, applicationName: $0.string("name") ?? "")
        }
    }

    public func captures(inSession sessionID: Int64) throws -> [CaptureRecord] {
        try db.query("\(Self.captureSelect) WHERE c.activity_session_id = ? ORDER BY c.captured_at", [sessionID])
            .map(Self.capture(from:))
    }

    public func previousCapture(before date: Date) throws -> CaptureRecord? {
        try db.queryOne("\(Self.captureSelect) WHERE c.captured_at < ? ORDER BY c.captured_at DESC LIMIT 1", [date])
            .map(Self.capture(from:))
    }

    public func nextCapture(after date: Date) throws -> CaptureRecord? {
        try db.queryOne("\(Self.captureSelect) WHERE c.captured_at > ? ORDER BY c.captured_at ASC LIMIT 1", [date])
            .map(Self.capture(from:))
    }

    public func latestCapture() throws -> CaptureRecord? {
        try db.queryOne("\(Self.captureSelect) ORDER BY c.captured_at DESC LIMIT 1").map(Self.capture(from:))
    }

    /// Captures not yet assigned to a session, oldest first.
    public func unsessionedCaptures(before date: Date, limit: Int = 2000) throws -> [CaptureRecord] {
        try db.query("\(Self.captureSelect) WHERE c.activity_session_id IS NULL AND c.captured_at < ? ORDER BY c.captured_at LIMIT ?",
                     [date, limit]).map(Self.capture(from:))
    }

    public func updateOCR(captureID: Int64, text: String, confidence: Double?, status: ProcessingStatus) throws {
        try db.run("UPDATE captures SET ocr_text = ?, ocr_confidence = ?, ocr_status = ? WHERE id = ?",
                   [text, confidence, status.rawValue, captureID])
    }

    public func setOCRStatus(captureID: Int64, _ status: ProcessingStatus) throws {
        try db.run("UPDATE captures SET ocr_status = ? WHERE id = ?", [status.rawValue, captureID])
    }

    public func updateAI(captureID: Int64, description: String, json: String?, status: ProcessingStatus) throws {
        try db.run("UPDATE captures SET ai_description = ?, ai_json = ?, ai_status = ? WHERE id = ?",
                   [description, json, status.rawValue, captureID])
    }

    public func setAIStatus(captureID: Int64, _ status: ProcessingStatus) throws {
        try db.run("UPDATE captures SET ai_status = ? WHERE id = ?", [status.rawValue, captureID])
    }

    public func setCaptureProject(captureID: Int64, projectID: Int64?) throws {
        try db.run("UPDATE captures SET project_id = ? WHERE id = ?", [projectID, captureID])
    }

    // MARK: Events

    public func logEvent(_ type: ActivityEventType, at date: Date = Date(), applicationID: Int64? = nil,
                         windowID: Int64? = nil, metadata: [String: String] = [:]) throws {
        let json = (try? String(data: JSONEncoder().encode(metadata), encoding: .utf8)) ?? "{}"
        try db.run("INSERT INTO activity_events (timestamp, event_type, application_id, window_id, metadata_json) VALUES (?, ?, ?, ?, ?)",
                   [date, type.rawValue, applicationID, windowID, json])
    }

    public func events(from start: Date, to end: Date, types: [ActivityEventType]? = nil) throws -> [ActivityEvent] {
        var sql = """
            SELECT e.*, a.name AS app_name, w.title AS window_title FROM activity_events e
            LEFT JOIN applications a ON a.id = e.application_id
            LEFT JOIN windows w ON w.id = e.window_id
            WHERE e.timestamp >= ? AND e.timestamp < ?
            """
        var params: [SQLBindable] = [start, end]
        if let types, !types.isEmpty {
            sql += " AND e.event_type IN (\(Array(repeating: "?", count: types.count).joined(separator: ",")))"
            params += types.map(\.rawValue) as [SQLBindable]
        }
        sql += " ORDER BY e.timestamp"
        return try db.query(sql, params).compactMap { row in
            guard let type = ActivityEventType(rawValue: row.string("event_type") ?? "") else { return nil }
            let meta = (row.string("metadata_json")?.data(using: .utf8))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            return ActivityEvent(id: row.int("id")!, timestamp: row.date("timestamp") ?? .distantPast, type: type,
                                 applicationName: row.string("app_name"), windowTitle: row.string("window_title"),
                                 metadata: meta)
        }
    }

    // MARK: Settings (small key/value values that belong with the data, not UserDefaults)

    public func setting(_ key: String) throws -> String? {
        try db.queryOne("SELECT value FROM settings WHERE key = ?", [key])?.string("value")
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }
}
