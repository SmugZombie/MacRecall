import Foundation

extension RecallStore {
    // MARK: Embeddings

    public func saveEmbedding(entityType: String, entityID: Int64, model: String, vector: [Float], entityTime: Date) throws {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try db.run("""
            INSERT INTO embeddings (entity_type, entity_id, model, dimensions, vector_data, entity_time, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, entity_id, model) DO UPDATE SET
                vector_data = excluded.vector_data, dimensions = excluded.dimensions, created_at = excluded.created_at
            """, [entityType, entityID, model, vector.count, data, entityTime, Date()])
    }

    /// Streams embeddings in pages so a full scan never holds every vector in memory.
    public func forEachEmbedding(model: String, entityTypes: [String], from start: Date, to end: Date,
                                 pageSize: Int = 2000, _ body: (String, Int64, [Float]) throws -> Void) throws {
        var lastID: Int64 = 0
        let types = Array(repeating: "?", count: entityTypes.count).joined(separator: ",")
        while true {
            let rows = try db.query("""
                SELECT id, entity_type, entity_id, vector_data FROM embeddings
                WHERE model = ? AND entity_type IN (\(types)) AND entity_time >= ? AND entity_time < ? AND id > ?
                ORDER BY id LIMIT ?
                """, [model] + (entityTypes as [SQLBindable]) + [start, end, lastID, pageSize])
            if rows.isEmpty { return }
            for row in rows {
                lastID = row.int("id")!
                guard let data = row.data("vector_data") else { continue }
                let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                try body(row.string("entity_type") ?? "", row.int("entity_id") ?? 0, vector)
            }
        }
    }

    public func embeddingCount(model: String) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM embeddings WHERE model = ?", [model]))
    }

    // MARK: Deletion & retention

    /// Deletes captures (records and files) in a range. Returns the number removed.
    @discardableResult
    public func deleteCaptures(from start: Date, to end: Date) throws -> Int {
        var removed = 0
        while true {
            // Work in batches: delete rows first, then files, so a crash never leaves rows pointing at missing files.
            let rows = try db.query("SELECT id, image_path, thumbnail_path FROM captures WHERE captured_at >= ? AND captured_at < ? LIMIT 500",
                                    [start, end])
            if rows.isEmpty { break }
            let ids = rows.compactMap { $0.int("id") }
            try db.transaction {
                for id in ids { try db.run("DELETE FROM captures WHERE id = ?", [id]) }
            }
            for row in rows {
                for key in ["image_path", "thumbnail_path"] {
                    if let rel = row.string(key), !rel.isEmpty { try? FileManager.default.removeItem(at: paths.absolute(rel)) }
                }
            }
            removed += ids.count
        }
        try db.run("DELETE FROM activity_events WHERE timestamp >= ? AND timestamp < ?", [start, end])
        try deleteEmptySessions()
        return removed
    }

    public func deleteAllHistory() throws {
        try db.transaction {
            for table in ["captures", "sessions", "activity_events", "ai_jobs", "embeddings", "daily_summaries", "windows"] {
                try db.run("DELETE FROM \(table)")
            }
            try db.run("DELETE FROM applications")
        }
        for dir in [paths.screenshots, paths.thumbnails] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? db.execute("VACUUM")
    }

    /// Removes AI-generated metadata but keeps captures, OCR and user edits.
    public func clearAIMetadata() throws {
        try db.transaction {
            try db.run("UPDATE captures SET ai_description = '', ai_json = NULL, ai_status = 'pending'")
            try db.run("UPDATE sessions SET summary = '', summary_source = 'none' WHERE summary_source != 'user'")
            try db.run("UPDATE sessions SET classification_confidence = NULL")
            try db.run("UPDATE sessions SET title_source = 'deterministic' WHERE title_source = 'ai'")
            try db.run("DELETE FROM embeddings")
            try db.run("DELETE FROM daily_summaries")
            try db.run("DELETE FROM ai_jobs WHERE job_type != 'ocr'")
        }
    }

    /// Drops and rebuilds the full-text indexes from source tables.
    public func rebuildSearchIndexes() throws {
        try db.transaction {
            try db.run("DELETE FROM capture_fts")
            try db.run("DELETE FROM session_fts")
            try db.run("""
                INSERT INTO capture_fts(rowid, app_name, window_title, ocr_text, ai_description, project)
                SELECT c.id, a.name, COALESCE(w.title, ''), c.ocr_text, c.ai_description, COALESCE(p.name, '')
                FROM captures c JOIN applications a ON a.id = c.application_id
                LEFT JOIN windows w ON w.id = c.window_id
                LEFT JOIN sessions s ON s.id = c.activity_session_id
                LEFT JOIN projects p ON p.id = COALESCE(c.project_id, s.project_id)
                """)
            try db.run("""
                INSERT INTO session_fts(rowid, title, summary, project)
                SELECT s.id, s.title, s.summary, COALESCE(p.name, '') FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
                """)
        }
        try db.execute("INSERT INTO capture_fts(capture_fts) VALUES('optimize'); INSERT INTO session_fts(session_fts) VALUES('optimize');")
    }

    public func storageStats() throws -> StorageStats {
        let count = Int(try db.scalarInt("SELECT COUNT(*) FROM captures"))
        let oldest = try db.queryOne("SELECT MIN(captured_at) AS t FROM captures")?.date("t")
        func size(_ url: URL) -> Int64 {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in enumerator {
                total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
            return total
        }
        var dbBytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let attrs = try? FileManager.default.attributesOfItem(atPath: paths.database.path + suffix)
            dbBytes += (attrs?[.size] as? Int64) ?? 0
        }
        return StorageStats(captureCount: count, databaseBytes: dbBytes,
                            imageBytes: size(paths.screenshots) + size(paths.thumbnails), oldestCapture: oldest)
    }
}
