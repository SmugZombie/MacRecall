import AppKit
import RecallCore
import SwiftUI

/// A note in the timeline, search results and the Notes list.
struct NoteRow: View {
    let note: NoteRecord
    var snippet: String? = nil
    var selected = false
    var showDate = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "note.text")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(showDate ? note.createdAt.formatted(date: .abbreviated, time: .shortened) : note.createdAt.timeString)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    StatusPill(text: "Note", color: .orange)
                    if let project = note.projectName { StatusPill(text: project, color: .accentColor) }
                }
                if let snippet, !snippet.isEmpty {
                    HighlightedText(snippet: snippet).lineLimit(4)
                } else if !note.text.isEmpty {
                    Text(note.text).lineLimit(4)
                }
                if !note.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(note.attachments.filter(\.isImage).prefix(4)) { a in
                            StoredImage(relativePath: a.path, maxPixel: 240)
                                .frame(width: 72, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        let files = note.attachments.filter { !$0.isImage }
                        if !files.isEmpty {
                            Label(files.count == 1 ? files[0].fileName : "\(files.count) files", systemImage: "paperclip")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Shared context-menu actions for a note.
struct NoteMenu: View {
    let note: NoteRecord
    let projects: [ProjectRecord]
    var onEdit: () -> Void
    var onDelete: () -> Void
    @EnvironmentObject private var state: AppState

    var body: some View {
        Button("Edit Note…", action: onEdit)
        Menu("Assign to Project") {
            Button("None") { setProject(nil) }
            Divider()
            ForEach(projects) { p in Button(p.name) { setProject(p.id) } }
        }
        Divider()
        Button("Delete Note…", role: .destructive, action: onDelete)
    }

    private func setProject(_ id: Int64?) {
        try? state.store?.setNoteProject(id: note.id, projectID: id)
        state.historyChanged()
    }
}

/// The inspector for a note: full text and attachments, which open or export decrypted.
struct NoteDetailView: View {
    let noteID: Int64
    var onClose: () -> Void

    @EnvironmentObject private var state: AppState
    @State private var note: NoteRecord?
    @State private var editing: NoteRecord?
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Note", systemImage: "note.text").font(.headline)
                Spacer()
                if let note {
                    Button { editing = note } label: { Image(systemName: "pencil") }.help("Edit note")
                    Button { confirmDelete = true } label: { Image(systemName: "trash") }.help("Delete note")
                }
                Button(action: onClose) { Image(systemName: "xmark") }.help("Close")
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            if let note {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.createdAt.formatted(date: .complete, time: .shortened)).font(.subheadline)
                            if note.updatedAt.timeIntervalSince(note.createdAt) >= 60 {
                                Text("Edited \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let project = note.projectName { StatusPill(text: project, color: .accentColor) }
                        if !note.text.isEmpty {
                            Text(note.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(note.attachments.filter(\.isImage)) { a in
                            VStack(alignment: .leading, spacing: 4) {
                                StoredImage(relativePath: a.path, maxPixel: 1600)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onTapGesture(count: 2) { open(a) }
                                attachmentActions(a)
                            }
                        }
                        let files = note.attachments.filter { !$0.isImage }
                        if !files.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(files) { a in
                                    HStack(spacing: 8) {
                                        Image(nsImage: AttachmentFiles.icon(for: a.contentType)).resizable().frame(width: 32, height: 32)
                                        VStack(alignment: .leading) {
                                            Text(a.fileName).lineLimit(1).truncationMode(.middle)
                                            Text(ByteCountFormatter.string(fromByteCount: a.byteCount, countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Open") { open(a) }
                                        Button("Save As…") { saveAs(a) }
                                    }
                                }
                            }
                        }
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView("Note deleted", systemImage: "note.text")
            }
        }
        // The inspector column's size comes from inspectorColumnWidth, never from the note's content.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .task(id: "\(noteID)-\(state.revision)") { note = try? state.store?.note(id: noteID) }
        .sheet(item: $editing) { note in EditNoteSheet(note: note) }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete) {
            Button("Delete Note", role: .destructive) {
                state.deleteNote(id: noteID)
                onClose()
            }
        } message: {
            Text("The note and its attached files will be permanently removed from Recall. The original files aren't affected.")
        }
    }

    private func attachmentActions(_ a: NoteAttachment) -> some View {
        HStack {
            Text(a.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Open") { open(a) }.controlSize(.small)
            Button("Save As…") { saveAs(a) }.controlSize(.small)
        }
    }

    private func open(_ a: NoteAttachment) {
        guard let store = state.store else { return }
        do { try AttachmentFiles.open(a, store: store); error = nil } catch { self.error = error.localizedDescription }
    }

    private func saveAs(_ a: NoteAttachment) {
        guard let store = state.store else { return }
        do { try AttachmentFiles.saveAs(a, store: store); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct EditNoteSheet: View {
    let note: NoteRecord
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NoteDraft()
    @State private var importing = false

    var body: some View {
        NoteEditor(draft: $draft, importing: $importing, title: "Edit Note",
                   caption: "Written \(note.createdAt.formatted(date: .abbreviated, time: .shortened))", saveTitle: "Save",
                   onSave: {
                       try await state.saveNote(draft, editing: note)
                       dismiss()
                   },
                   onCancel: { dismiss() })
            .onAppear { draft = NoteDraft(note: note) }
    }
}

/// Every note, newest first, grouped by day.
struct NotesView: View {
    @EnvironmentObject private var state: AppState
    @State private var notes: [NoteRecord] = []
    @State private var projects: [ProjectRecord] = []
    @State private var selectedNoteID: Int64?
    @State private var editing: NoteRecord?
    @State private var deleting: NoteRecord?
    @State private var hasMore = false
    private let pageSize = 200

    var body: some View {
        Group {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "note.text")
                } description: {
                    Text("Write a note from the menu bar, or press \(GlobalHotKey.newNoteDisplayString) anywhere. Notes are saved with the time you write them and appear in your timeline, search and daily summaries.")
                } actions: {
                    Button("New Note") { state.newNote() }
                }
            } else {
                List {
                    ForEach(days, id: \.self) { day in
                        Section(day.formatted(date: .complete, time: .omitted)) {
                            ForEach(notes.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: day) }) { note in
                                NoteRow(note: note, selected: selectedNoteID == note.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedNoteID = note.id }
                                    .contextMenu {
                                        NoteMenu(note: note, projects: projects, onEdit: { editing = note }, onDelete: { deleting = note })
                                    }
                            }
                        }
                    }
                    if hasMore {
                        Button("Show Older Notes") { Task { await load(count: notes.count + pageSize) } }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Notes")
        .toolbar {
            Button { state.newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                .help("New note (\(GlobalHotKey.newNoteDisplayString))")
        }
        .inspector(isPresented: Binding(get: { selectedNoteID != nil }, set: { if !$0 { selectedNoteID = nil } })) {
            if let id = selectedNoteID {
                NoteDetailView(noteID: id, onClose: { selectedNoteID = nil })
                    .inspectorColumnWidth(min: 320, ideal: 460, max: 800)
            }
        }
        .sheet(item: $editing) { EditNoteSheet(note: $0) }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { note in
            Button("Delete Note", role: .destructive) {
                if selectedNoteID == note.id { selectedNoteID = nil }
                state.deleteNote(id: note.id)
            }
        } message: { _ in
            Text("The note and its attached files will be permanently removed from Recall.")
        }
        .task(id: state.revision) { await load(count: max(pageSize, notes.count)) }
    }

    private var days: [Date] {
        var seen: [Date] = []
        for note in notes {
            let day = Calendar.current.startOfDay(for: note.createdAt)
            if seen.last != day { seen.append(day) }
        }
        return seen
    }

    private func load(count: Int) async {
        guard let store = state.store else { return }
        projects = (try? store.projects()) ?? []
        let page = (try? store.notes(from: .distantPast, to: .distantFuture, limit: count)) ?? []
        notes = page
        hasMore = page.count == count
    }
}
