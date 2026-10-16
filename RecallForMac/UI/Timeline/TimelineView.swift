import RecallCore
import SwiftUI

struct TimelineView: View {
    let title: String
    let range: DateInterval
    var projectID: Int64? = nil

    @EnvironmentObject private var state: AppState
    @ObservedObject private var nav = NavigationRequest.shared
    @State private var sessions: [SessionRecord] = []
    @State private var expanded: Set<Int64> = []
    @State private var selectedCaptureID: Int64?
    @State private var appFilter: String?
    @State private var applications: [ApplicationRecord] = []
    @State private var marks: [CaptureMark] = []
    @State private var scrubIndex: Double = 0
    @State private var hasMore = true
    @State private var renaming: SessionRecord?
    @State private var editingSummary: SessionRecord?
    @State private var projects: [ProjectRecord] = []
    @State private var notes: [NoteRecord] = []
    @State private var selectedNoteID: Int64?
    @State private var editingNote: NoteRecord?
    @State private var deletingNote: NoteRecord?
    @State private var deletingSession: SessionRecord?
    private let pageSize = 60

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sessions.isEmpty && notes.isEmpty {
                ContentUnavailableView("No activity", systemImage: "clock",
                                       description: Text(state.recordingState == .recording
                                                         ? "Captures appear here as you work. Sessions are grouped about a minute after capture."
                                                         : state.recordingState.label))
            } else {
                list
            }
        }
        .navigationTitle(title)
        .inspector(isPresented: Binding(get: { selectedCaptureID != nil || selectedNoteID != nil },
                                        set: { if !$0 { selectedCaptureID = nil; selectedNoteID = nil } })) {
            if let id = selectedNoteID {
                NoteDetailView(noteID: id, onClose: { selectedNoteID = nil })
                    .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
            } else if let id = selectedCaptureID {
                CaptureDetailView(captureID: id, onClose: { selectedCaptureID = nil }, onSelect: { selectedCaptureID = $0 })
                    .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
            }
        }
        .onChange(of: selectedCaptureID) { if selectedCaptureID != nil { selectedNoteID = nil } }
        .onChange(of: selectedNoteID) { if selectedNoteID != nil { selectedCaptureID = nil } }
        .sheet(item: $editingNote) { EditNoteSheet(note: $0) }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { deletingNote != nil }, set: { if !$0 { deletingNote = nil } }),
                            presenting: deletingNote) { note in
            Button("Delete Note", role: .destructive) {
                if selectedNoteID == note.id { selectedNoteID = nil }
                state.deleteNote(id: note.id)
            }
        } message: { _ in
            Text("The note and its attached files will be permanently removed from Recall.")
        }
        .confirmationDialog("Delete this session and its screenshots?",
                            isPresented: Binding(get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } }),
                            presenting: deletingSession) { session in
            Button("Delete \(session.captureCount) Screenshot\(session.captureCount == 1 ? "" : "s")", role: .destructive) {
                deleteSession(session)
            }
        } message: { session in
            Text(CaptureDeletionText.message(count: session.captureCount) + " The session is removed too.")
        }
        .task(id: TaskKey(range: range, revision: state.revision, app: appFilter, project: projectID)) { await reload() }
        .onChange(of: nav.captureID) { consumeRequestedCapture() }
        .onAppear { consumeRequestedCapture() }
        .sheet(item: $editingSummary) { session in
            EditSummarySheet(session: session) { text in
                try? state.store?.setSessionSummary(id: session.id, summary: text)
                state.historyChanged()
                state.refreshQueue()  // clearing the summary queues a new one
            }
        }
        .sheet(item: $renaming) { session in
            RenameSessionSheet(session: session) { newTitle in
                try? state.store?.renameSession(id: session.id, title: newTitle)
                state.historyChanged()
            }
        }
    }

    private struct TaskKey: Hashable {
        var range: DateInterval
        var revision: Int
        var app: String?
        var project: Int64?
    }

    // MARK: Header with filters and scrubber

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let total = sessions.reduce(0) { $0 + $1.activeSeconds }
                Text("\(sessions.count) sessions · \(formatDuration(total)) active" + (notes.isEmpty ? "" : " · \(notes.count) note\(notes.count == 1 ? "" : "s")"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { state.newNote() } label: { Image(systemName: "square.and.pencil") }.help("New note (\(GlobalHotKey.newNoteDisplayString))")
                Picker("Application", selection: $appFilter) {
                    Text("All applications").tag(String?.none)
                    ForEach(applications) { app in Text(app.name).tag(Optional(app.bundleIdentifier)) }
                }
                .frame(maxWidth: 240)
                Button { state.updateSessions() } label: { Image(systemName: "arrow.clockwise") }.help("Regroup recent captures")
            }
            if marks.count > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.below.rectangle").foregroundStyle(.secondary)
                    Slider(value: $scrubIndex, in: 0...Double(marks.count - 1), step: 1) { editing in
                        if !editing { selectScrubbed() }
                    }
                    .onChange(of: scrubIndex) { selectScrubbed() }
                    let mark = marks[min(marks.count - 1, Int(scrubIndex))]
                    Text("\(mark.capturedAt.formatted(date: range.duration > 90_000 ? .abbreviated : .omitted, time: .shortened)) · \(mark.applicationName)")
                        .font(.caption.monospacedDigit()).frame(width: 200, alignment: .leading)
                }
                .help("Scrub through every screenshot in this period")
            }
        }
        .padding(12)
    }

    private func selectScrubbed() {
        guard !marks.isEmpty else { return }
        selectedCaptureID = marks[min(marks.count - 1, max(0, Int(scrubIndex)))].id
    }

    // MARK: Session list

    private enum Item: Identifiable {
        case session(SessionRecord)
        case note(NoteRecord)

        var id: String {
            switch self {
            case .session(let s): return "s\(s.id)"
            case .note(let n): return "n\(n.id)"
            }
        }

        var date: Date {
            switch self {
            case .session(let s): return s.startedAt
            case .note(let n): return n.createdAt
            }
        }
    }

    /// Sessions and notes, newest first. While older sessions are still to load, notes older than the
    /// loaded ones wait too, so they appear in order.
    private var items: [Item] {
        let cutoff = hasMore ? sessions.last?.startedAt : nil
        let shown = notes.filter { cutoff == nil || $0.createdAt >= cutoff! }
        return (sessions.map(Item.session) + shown.map(Item.note)).sorted { $0.date > $1.date }
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                switch item {
                case .session(let session):
                    SessionRow(session: session, expanded: expanded.contains(session.id), selectedCaptureID: $selectedCaptureID,
                               appFilter: appFilter)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if expanded.contains(session.id) { expanded.remove(session.id) } else { expanded.insert(session.id) }
                        }
                        .contextMenu { sessionMenu(session) }
                        .onAppear { if session.id == sessions.last?.id && hasMore { Task { await loadMore() } } }
                case .note(let note):
                    NoteRow(note: note, selected: selectedNoteID == note.id, showDate: range.duration > 90_000)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedNoteID = note.id }
                        .contextMenu {
                            NoteMenu(note: note, projects: projects, onEdit: { editingNote = note }, onDelete: { deletingNote = note })
                        }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder private func sessionMenu(_ session: SessionRecord) -> some View {
        Button("Rename…") { renaming = session }
        Button("Edit Summary…") { editingSummary = session }
        Menu("Assign to Project") {
            Button("None") { setProject(session, nil) }
            Divider()
            ForEach(projects) { p in Button(p.name) { setProject(session, p.id) } }
        }
        if let index = sessions.firstIndex(of: session), index + 1 < sessions.count {
            let earlier = sessions[index + 1]
            Button("Merge with Previous Session (\(earlier.startedAt.timeString))") {
                try? state.store?.mergeSessions(target: earlier.id, others: [session.id])
                state.historyChanged()
            }
        }
        Button(session.summarySource == "user" ? "Regenerate Summary (keeps your text)" : "Regenerate Summary") {
            try? state.store?.enqueueJob(.sessionSummary, entityType: "session", entityID: session.id, priority: 90)
            state.refreshQueue()
        }
        Divider()
        Button("Delete Session and Screenshots…", role: .destructive) { deletingSession = session }
    }

    private func deleteSession(_ session: SessionRecord) {
        guard let ids = try? state.store?.captures(inSession: session.id).map(\.id) else { return }
        if let selected = selectedCaptureID, ids.contains(selected) { selectedCaptureID = nil }
        expanded.remove(session.id)
        state.deleteCaptures(ids)
    }

    /// Another view (e.g. Processing → Show Screenshot) asked for a capture to be opened.
    private func consumeRequestedCapture() {
        if let id = nav.captureID {
            selectedCaptureID = id
            nav.captureID = nil
        }
    }

    private func setProject(_ session: SessionRecord, _ projectID: Int64?) {
        try? state.store?.setSessionProject(id: session.id, projectID: projectID, source: "user")
        state.historyChanged()
    }

    // MARK: Loading

    private func reload() async {
        guard let store = state.store else { return }
        applications = (try? store.applications()) ?? []
        projects = (try? store.projects()) ?? []
        let page = (try? store.sessions(from: range.start, to: range.end, projectID: projectID, limit: pageSize)) ?? []
        sessions = filter(page)
        hasMore = page.count == pageSize
        // Notes belong to no application, so an application filter hides them.
        notes = appFilter == nil ? ((try? store.notes(from: range.start, to: range.end, projectID: projectID, limit: 2000)) ?? []) : []
        marks = ((try? store.captureMarks(from: range.start, to: range.end)) ?? []).filter { mark in
            guard let appFilter else { return true }
            return applications.first { $0.bundleIdentifier == appFilter }?.name == mark.applicationName
        }
        if !marks.isEmpty && scrubIndex > Double(marks.count - 1) { scrubIndex = Double(marks.count - 1) }
    }

    private func loadMore() async {
        guard let store = state.store else { return }
        let page = (try? store.sessions(from: range.start, to: range.end, projectID: projectID, limit: pageSize, offset: sessions.count)) ?? []
        sessions += filter(page)
        hasMore = page.count == pageSize
    }

    private func filter(_ page: [SessionRecord]) -> [SessionRecord] {
        guard let appFilter else { return page }
        return page.filter { $0.bundleIdentifiers.contains(appFilter) }
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let expanded: Bool
    @Binding var selectedCaptureID: Int64?
    var appFilter: String?
    @EnvironmentObject private var state: AppState
    @State private var captures: [CaptureRecord] = []
    @State private var deleting: CaptureRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if let thumb = session.thumbnailPath {
                    StoredImage(relativePath: thumb, maxPixel: 320)
                        .frame(width: 128, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(timeRange(session.startedAt, session.endedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("· \(formatDuration(session.activeSeconds))").font(.caption).foregroundStyle(.secondary)
                        ForEach(session.bundleIdentifiers.prefix(5), id: \.self) { AppIcon(bundleIdentifier: $0, size: 14) }
                        if let project = session.projectName {
                            StatusPill(text: project, color: .accentColor)
                        }
                    }
                    Text(session.title.isEmpty ? "Activity" : session.title).font(.headline).lineLimit(2)
                    if !session.summary.isEmpty {
                        Text(session.summary).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                    } else if session.titleSource == "deterministic" {
                        Text("\(session.captureCount) screenshots · summary pending").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.tertiary)
            }
            if expanded {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(captures) { capture in
                            VStack(alignment: .leading, spacing: 2) {
                                StoredImage(relativePath: capture.thumbnailPath, maxPixel: 320)
                                    .frame(width: 160, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5)
                                        .stroke(selectedCaptureID == capture.id ? Color.accentColor : .clear, lineWidth: 2))
                                HStack(spacing: 4) {
                                    AppIcon(bundleIdentifier: capture.bundleIdentifier, size: 12)
                                    Text(capture.capturedAt.timeString).font(.caption2.monospacedDigit())
                                }
                            }
                            .onTapGesture { selectedCaptureID = capture.id }
                            .contextMenu {
                                Button("Split Session Here") {
                                    _ = try? state.store?.splitSession(id: session.id, at: capture.capturedAt)
                                    state.historyChanged()
                                }
                                Divider()
                                Button("Delete Screenshot…", role: .destructive) { deleting = capture }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 124)
                .confirmationDialog("Delete this screenshot?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                    presenting: deleting) { capture in
                    Button("Delete Screenshot", role: .destructive) {
                        if selectedCaptureID == capture.id { selectedCaptureID = nil }
                        state.deleteCaptures([capture.id])
                    }
                } message: { _ in
                    Text(CaptureDeletionText.message(count: 1))
                }
                .task(id: "\(session.id)-\(state.revision)") {
                    let all = (try? state.store?.captures(inSession: session.id)) ?? []
                    captures = appFilter.map { f in all.filter { $0.bundleIdentifier == f } } ?? all
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct EditSummarySheet: View {
    let session: SessionRecord
    let onSave: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Summary").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 440, height: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Text("AI won't overwrite a summary you write. Clear it to let AI summarize this session again.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = session.summary }
    }
}

struct RenameSessionSheet: View {
    let session: SessionRecord
    let onSave: (String) -> Void
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Session").font(.headline)
            TextField("Title", text: $title).frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(title); dismiss() }.keyboardShortcut(.defaultAction).disabled(title.isEmpty)
            }
        }
        .padding(20)
        .onAppear { title = session.title }
    }
}
