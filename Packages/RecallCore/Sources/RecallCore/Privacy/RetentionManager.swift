import Foundation

public struct RetentionManager: Sendable {
    let store: RecallStore
    public init(store: RecallStore) { self.store = store }

    /// Deletes captures older than `days`, plus their files, embeddings and orphaned sessions.
    /// Notes are kept: the user wrote them on purpose, and deletes them one by one.
    @discardableResult
    public func enforce(retentionDays days: Int, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let removed = try store.deleteCaptures(from: .distantPast, to: cutoff)
        try store.purgeCompletedJobs(olderThan: now.addingTimeInterval(-7 * 86400))
        try store.db.run("DELETE FROM daily_summaries WHERE generated_at < ?", [cutoff])
        removeOrphanFiles()
        return removed
    }

    /// Removes image and attachment files with no database row (e.g. left by a crash between write and insert).
    public func removeOrphanFiles(olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        let known: Set<String>
        do {
            let rows = try store.db.query("SELECT image_path, thumbnail_path FROM captures")
            let attachments = try store.db.query("SELECT path FROM note_attachments")
            known = Set(rows.flatMap { [$0.string("image_path") ?? "", $0.string("thumbnail_path") ?? ""] }
                        + attachments.compactMap { $0.string("path") })
        } catch { return }
        let rootPath = store.paths.data.standardizedFileURL.path
        for dir in [store.paths.screenshots, store.paths.thumbnails, store.paths.attachments] {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                guard Date().timeIntervalSince(modified) > age else { continue }
                let rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                if !known.contains(rel) { try? fm.removeItem(at: url) }
            }
        }
    }
}
