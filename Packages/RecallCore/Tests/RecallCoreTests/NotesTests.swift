import CoreGraphics
import Foundation
import Testing
@testable import RecallCore

@Suite struct NotesTests {
    func jpegData(width: Int = 40, height: Int = 20) throws -> Data {
        let image = try #require(ImageProcessing.draw(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        })
        return try ImageProcessing.encode(image, format: .jpeg, quality: 0.9)
    }

    @Test func addReadAndListNotes() throws {
        let store = try makeStore()
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let project = try store.createProject(name: "Atlas")
        let note = try store.addNote(text: "  Completed work on the billing export\nShipped to staging  ", projectID: project, at: t)
        #expect(note.text == "Completed work on the billing export\nShipped to staging")
        #expect(note.title == "Completed work on the billing export")
        #expect(note.createdAt == t)
        #expect(note.projectName == "Atlas")
        try store.addNote(text: "Took lunch from 12 to 1", at: t.addingTimeInterval(3600))

        let listed = try store.notes(from: t.addingTimeInterval(-1), to: t.addingTimeInterval(7200))
        #expect(listed.map(\.text.first) == ["T", "C"])  // newest first
        #expect(try store.notes(from: t.addingTimeInterval(-1), to: t.addingTimeInterval(7200), projectID: project).count == 1)
        #expect(throws: NoteError.empty) { try store.addNote(text: "  \n ") }
    }

    @Test func attachmentsAreCopiedEncryptedAndReadable() throws {
        let store = try makeStore()
        let secret = Data("quarterly-figures: 42".utf8)
        let png = try jpegData()
        let note = try store.addNote(text: "Finished the report", attachments: [
            NewNoteAttachment(fileName: "/Users/me/Desktop/report.txt", data: secret),
            NewNoteAttachment(fileName: "chart.jpg", data: png),
        ])
        #expect(note.attachments.map(\.fileName) == ["report.txt", "chart.jpg"])
        #expect(note.attachments.map(\.isImage) == [false, true])
        #expect(note.attachments[0].contentType == "public.plain-text")
        #expect(note.attachments[0].byteCount == Int64(secret.count))

        // On disk the file is encrypted; through the store it's the original.
        let onDisk = try Data(contentsOf: store.paths.absolute(note.attachments[0].path))
        #expect(ScreenshotVault.isSealed(onDisk))
        #expect(onDisk.range(of: secret) == nil)
        #expect(try store.attachmentData(note.attachments[0]) == secret)
        #expect(try store.vault.image(note.attachments[1].path).width == 40)

        // A file that isn't really an image isn't treated as one.
        let fake = try store.addNote(text: "", attachments: [NewNoteAttachment(fileName: "broken.png", data: Data("nope".utf8))])
        #expect(fake.attachments[0].isImage == false)
    }

    @Test func oversizedAttachmentIsRefusedWithoutLeavingFiles() throws {
        let store = try makeStore()
        let big = NewNoteAttachment(fileName: "huge.bin", data: Data(count: RecallStore.maxAttachmentBytes + 1))
        #expect(throws: NoteError.attachmentTooLarge("huge.bin")) {
            try store.addNote(text: "x", attachments: [NewNoteAttachment(fileName: "ok.txt", data: Data("ok".utf8)), big])
        }
        #expect(try store.noteCount() == 0)
        let files = FileManager.default.enumerator(at: store.paths.attachments, includingPropertiesForKeys: nil)?.allObjects ?? []
        #expect(files.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }.isEmpty)
    }

    @Test func editAndDeleteRemoveFilesAndIndex() throws {
        let store = try makeStore()
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let note = try store.addNote(text: "draft of the zephyr proposal", attachments: [
            NewNoteAttachment(fileName: "a.txt", data: Data("a".utf8)),
            NewNoteAttachment(fileName: "b.txt", data: Data("b".utf8)),
        ], at: t)
        let removedFile = store.paths.absolute(note.attachments[0].path)

        let edited = try store.updateNote(id: note.id, text: "final zephyr proposal sent", projectID: nil,
                                          adding: [NewNoteAttachment(fileName: "c.txt", data: Data("c".utf8))],
                                          removing: [note.attachments[0].id], at: t.addingTimeInterval(600))
        #expect(edited.createdAt == t)
        #expect(edited.updatedAt == t.addingTimeInterval(600))
        #expect(edited.attachments.map(\.fileName) == ["b.txt", "c.txt"])
        #expect(!FileManager.default.fileExists(atPath: removedFile.path))

        let search = KeywordSearch(store: store)
        #expect(try search.searchNotes("draft").isEmpty)
        #expect(try search.searchNotes("final").map(\.entityID) == [note.id])
        // Attachment names are searchable, and follow edits.
        #expect(try search.searchNotes("c.txt").map(\.entityID) == [note.id])
        #expect(try search.searchNotes("a.txt").isEmpty)

        let remaining = edited.attachments.map { store.paths.absolute($0.path) }
        try store.deleteNote(id: note.id)
        #expect(try store.note(id: note.id) == nil)
        #expect(try search.searchNotes("final").isEmpty)
        #expect(remaining.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM note_attachments") == 0)
    }

    @Test func projectChangesFollowNotes() throws {
        let store = try makeStore()
        let atlas = try store.createProject(name: "Atlas")
        let note = try store.addNote(text: "kickoff", projectID: atlas)
        var project = try #require(try store.project(id: atlas))
        project.name = "Borealis"
        try store.updateProject(project)
        #expect(try KeywordSearch(store: store).searchNotes("borealis").map(\.entityID) == [note.id])
        try store.deleteProject(id: atlas)
        #expect(try store.note(id: note.id)?.projectID == nil)
        #expect(try KeywordSearch(store: store).searchNotes("borealis").isEmpty)
    }

    @Test func hybridSearchFindsNotes() async throws {
        let store = try makeStore()
        let now = Date()
        let note = try store.addNote(text: "Sent the invoices to Acme", at: now.addingTimeInterval(-60))
        try addCapture(store, at: now.addingTimeInterval(-120), ocr: "invoices draft")
        let results = try await HybridSearch(store: store, ai: nil, embeddingModel: "").search("invoices", now: now)
        try #require(results.notes.map(\.id) == [note.id])
        #expect(results.notes[0].snippet.contains("«invoices»"))
        #expect(results.captures.count == 1)

        // A time-only query lists the period's notes; an app filter excludes them (notes have no app).
        let today = try await HybridSearch(store: store, ai: nil, embeddingModel: "").search("today", now: now)
        #expect(today.notes.map(\.id) == [note.id])
        let inTerminal = try await HybridSearch(store: store, ai: nil, embeddingModel: "")
            .search("invoices", applicationNames: ["Terminal"], now: now)
        #expect(inTerminal.notes.isEmpty)

        // An app mentioned in the query filters captures, not notes.
        let slack = try store.addNote(text: "Finished the Slack integration", at: now.addingTimeInterval(-30))
        try addCapture(store, app: "Slack", bundle: "com.tinyspeck.slackmacgap", title: "general", at: now.addingTimeInterval(-90))
        let mentioned = try await HybridSearch(store: store, ai: nil, embeddingModel: "").search("slack integration", now: now)
        #expect(mentioned.notes.map(\.id).contains(slack.id))
    }

    @Test func groundedAnswersCanCiteNotes() {
        let a = GroundedAnswerer.validate("You had lunch at noon [N3], not [N9].", captureIDs: [], sessionIDs: [], noteIDs: [3])
        #expect(a.sufficientEvidence)
        #expect(a.citations == [.note(3)])
        #expect(!a.text.contains("[N9]"))
    }

    @Test func dailySummaryListsNotes() throws {
        let store = try makeStore()
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9))!
        let service = DailySummaryService(store: store, ai: nil, settings: { RecallSettings() })
        let key = DailySummaryService.dayKey(for: day)

        let note = try store.addNote(text: "Completed work on the importer\nAll tests green",
                                     attachments: [NewNoteAttachment(fileName: "notes.md", data: Data("x".utf8))], at: day)
        // Notes alone make a day worth summarizing.
        let notesOnly = service.markdown(for: key, facts: try service.facts(for: key), narrative: nil)
        #expect(notesOnly.contains("## Notes"))
        #expect(notesOnly.contains("09:00 Completed work on the importer [note \(note.id)]"))
        #expect(notesOnly.contains("  All tests green"))
        #expect(notesOnly.contains("Attached: notes.md"))
        #expect(!notesOnly.contains("No activity was captured"))

        try addCapture(store, at: day.addingTimeInterval(60), ocr: "importer.swift")
        let full = service.markdown(for: key, facts: try service.facts(for: key), narrative: nil)
        #expect(full.contains("## Notes"))
        #expect(full.contains("## Time"))
    }

    @Test func retentionKeepsNotesButDeleteAllRemovesThem() throws {
        let store = try makeStore()
        let old = Date().addingTimeInterval(-90 * 86400)
        let note = try store.addNote(text: "old note", attachments: [NewNoteAttachment(fileName: "a.txt", data: Data("a".utf8))], at: old)
        try addCapture(store, at: old)
        let retention = RetentionManager(store: store)
        #expect(try retention.enforce(retentionDays: 30) == 1)
        retention.removeOrphanFiles(olderThan: 0)
        #expect(try store.note(id: note.id) != nil)
        #expect(FileManager.default.fileExists(atPath: store.paths.absolute(note.attachments[0].path).path))

        try store.deleteAllHistory()
        #expect(try store.noteCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: store.paths.absolute(note.attachments[0].path).path))
        #expect(try KeywordSearch(store: store).searchNotes("old").isEmpty)
    }

    @Test func orphanAttachmentFilesAreRemoved() throws {
        let store = try makeStore()
        let orphan = store.paths.attachments.appendingPathComponent("2026-01/orphan.txt")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphan)
        RetentionManager(store: store).removeOrphanFiles(olderThan: 0)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func rebuildingIndexesKeepsNotesSearchable() throws {
        let store = try makeStore()
        let note = try store.addNote(text: "quasar migration", attachments: [NewNoteAttachment(fileName: "plan.pdf", data: Data("%PDF".utf8))])
        try store.rebuildSearchIndexes()
        #expect(try KeywordSearch(store: store).searchNotes("quasar").map(\.entityID) == [note.id])
        #expect(try KeywordSearch(store: store).searchNotes("plan.pdf").map(\.entityID) == [note.id])
        let stats = try store.storageStats()
        #expect(stats.noteCount == 1)
    }
}
