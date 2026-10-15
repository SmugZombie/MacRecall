import Foundation
import UniformTypeIdentifiers

public enum NoteError: Error, LocalizedError, Equatable {
    case empty
    case attachmentTooLarge(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .empty: return "Write something or attach a file."
        case .attachmentTooLarge(let name):
            return "“\(name)” is larger than \(ByteCountFormatter.string(fromByteCount: Int64(RecallStore.maxAttachmentBytes), countStyle: .file)), the most a note can hold."
        case .notFound: return "The note no longer exists."
        }
    }
}

extension RecallStore {
    /// Attachments are copied into the library and decrypted in memory, so they're capped.
    public static let maxAttachmentBytes = 100 * 1024 * 1024

    static let noteSelect = "SELECT n.*, p.name AS project_name FROM notes n LEFT JOIN projects p ON p.id = n.project_id"

    // MARK: Writing

    /// Saves a note stamped `date`. Attached files are copied into the library, encrypted.
    @discardableResult
    public func addNote(text: String, projectID: Int64? = nil, attachments: [NewNoteAttachment] = [],
                        at date: Date = Date(), timezone: String = TimeZone.current.identifier) throws -> NoteRecord {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { throw NoteError.empty }
        let stored = try storeAttachmentFiles(attachments, at: date)
        do {
            let id = try db.transaction {
                let id = try db.insert("INSERT INTO notes (created_at, updated_at, timezone, text, project_id) VALUES (?, ?, ?, ?, ?)",
                                       [date, date, timezone, text, projectID])
                try insertAttachmentRows(stored, noteID: id, at: date)
                return id
            }
            return try note(id: id)!
        } catch {
            removeFiles(stored.map(\.path))
            throw error
        }
    }

    /// Changes a note's text and project, and adds or removes attachments. The note keeps its original time.
    @discardableResult
    public func updateNote(id: Int64, text: String, projectID: Int64?, adding: [NewNoteAttachment] = [],
                           removing removedIDs: Set<Int64> = [], at date: Date = Date()) throws -> NoteRecord {
        guard let existing = try note(id: id) else { throw NoteError.notFound }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let removed = existing.attachments.filter { removedIDs.contains($0.id) }
        guard !text.isEmpty || existing.attachments.count - removed.count + adding.count > 0 else { throw NoteError.empty }
        let stored = try storeAttachmentFiles(adding, at: date)
        do {
            try db.transaction {
                try db.run("UPDATE notes SET text = ?, project_id = ?, updated_at = ? WHERE id = ?", [text, projectID, date, id])
                for a in removed { try db.run("DELETE FROM note_attachments WHERE id = ?", [a.id]) }
                try insertAttachmentRows(stored, noteID: id, at: date)
            }
        } catch {
            removeFiles(stored.map(\.path))
            throw error
        }
        removeFiles(removed.map(\.path))
        return try note(id: id)!
    }

    public func setNoteProject(id: Int64, projectID: Int64?) throws {
        try db.run("UPDATE notes SET project_id = ? WHERE id = ?", [projectID, id])
    }

    /// Deletes a note and its attached files.
    public func deleteNote(id: Int64) throws {
        let paths = try db.query("SELECT path FROM note_attachments WHERE note_id = ?", [id]).compactMap { $0.string("path") }
        try db.transaction {
            try db.run("DELETE FROM note_attachments WHERE note_id = ?", [id])
            try db.run("DELETE FROM notes WHERE id = ?", [id])
        }
        removeFiles(paths)
    }

    private struct StoredAttachment {
        var fileName: String
        var path: String
        var contentType: String
        var byteCount: Int
        var isImage: Bool
    }

    /// Writes the files before their rows, so a crash leaves at worst an orphan file that cleanup removes.
    private func storeAttachmentFiles(_ attachments: [NewNoteAttachment], at date: Date) throws -> [StoredAttachment] {
        for a in attachments where a.data.count > Self.maxAttachmentBytes { throw NoteError.attachmentTooLarge(a.fileName) }
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.dateFormat = "yyyy-MM"
        var stored: [StoredAttachment] = []
        do {
            for a in attachments {
                let name = Self.cleanFileName(a.fileName)
                let ext = (name as NSString).pathExtension.lowercased()
                let type = UTType(filenameExtension: ext) ?? .data
                let isImage = type.conforms(to: .image) && ImageProcessing.load(a.data, maxPixel: 64) != nil
                let path = "attachments/\(month.string(from: date))/\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
                try vault.write(a.data, to: path)
                stored.append(StoredAttachment(fileName: name, path: path, contentType: type.identifier, byteCount: a.data.count, isImage: isImage))
            }
        } catch {
            removeFiles(stored.map(\.path))
            throw error
        }
        return stored
    }

    private func insertAttachmentRows(_ stored: [StoredAttachment], noteID: Int64, at date: Date) throws {
        for a in stored {
            try db.run("""
                INSERT INTO note_attachments (note_id, file_name, path, content_type, byte_count, is_image, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [noteID, a.fileName, a.path, a.contentType, a.byteCount, a.isImage, date])
        }
    }

    static func cleanFileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return last.isEmpty || last == "/" ? "Attachment" : last
    }

    private func removeFiles(_ relativePaths: [String]) {
        for path in relativePaths where !path.isEmpty { try? FileManager.default.removeItem(at: paths.absolute(path)) }
    }

    // MARK: Reading

    public func note(id: Int64) throws -> NoteRecord? {
        try notes(sql: "\(Self.noteSelect) WHERE n.id = ?", [id]).first
    }

    public func notes(ids: [Int64]) throws -> [NoteRecord] {
        guard !ids.isEmpty else { return [] }
        let found = try notes(sql: "\(Self.noteSelect) WHERE n.id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))", ids)
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Notes written in a range, newest first unless `ascending`.
    public func notes(from start: Date, to end: Date, projectID: Int64? = nil, ascending: Bool = false,
                      limit: Int = 500, offset: Int = 0) throws -> [NoteRecord] {
        var sql = "\(Self.noteSelect) WHERE n.created_at >= ? AND n.created_at < ?"
        var params: [SQLBindable] = [start, end]
        if let projectID {
            sql += " AND n.project_id = ?"
            params.append(projectID)
        }
        sql += " ORDER BY n.created_at \(ascending ? "ASC" : "DESC") LIMIT ? OFFSET ?"
        params += [limit, offset]
        return try notes(sql: sql, params)
    }

    public func noteCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM notes"))
    }

    /// An attachment's contents, decrypted in memory.
    public func attachmentData(_ attachment: NoteAttachment) throws -> Data {
        try vault.read(attachment.path)
    }

    private func notes(sql: String, _ params: [SQLBindable]) throws -> [NoteRecord] {
        var notes = try db.query(sql, params).map { row in
            NoteRecord(id: row.int("id")!, createdAt: row.date("created_at") ?? .distantPast,
                       updatedAt: row.date("updated_at") ?? .distantPast,
                       timezone: row.string("timezone") ?? TimeZone.current.identifier, text: row.string("text") ?? "",
                       projectID: row.int("project_id"), projectName: row.string("project_name"), attachments: [])
        }
        guard !notes.isEmpty else { return [] }
        let ids = notes.map(\.id)
        let rows = try db.query("""
            SELECT * FROM note_attachments WHERE note_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))
            ORDER BY id
            """, ids)
        var byNote: [Int64: [NoteAttachment]] = [:]
        for row in rows {
            let a = NoteAttachment(id: row.int("id")!, noteID: row.int("note_id") ?? 0, fileName: row.string("file_name") ?? "",
                                   path: row.string("path") ?? "", contentType: row.string("content_type") ?? "",
                                   byteCount: row.int("byte_count") ?? 0, isImage: row.bool("is_image"))
            byNote[a.noteID, default: []].append(a)
        }
        for i in notes.indices { notes[i].attachments = byNote[notes[i].id] ?? [] }
        return notes
    }
}
