import AppKit
import RecallCore
import SwiftUI
import UniformTypeIdentifiers

/// A note being written or edited.
struct NoteDraft: Equatable {
    var text = ""
    var projectID: Int64?
    var attachments: [DraftAttachment] = []

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }

    init() {}

    init(note: NoteRecord) {
        text = note.text
        projectID = note.projectID
        attachments = note.attachments.map(DraftAttachment.init(existing:))
    }
}

/// A file in a draft: newly attached (its contents read when it was attached), or already saved with the note.
struct DraftAttachment: Identifiable, Equatable {
    let id: String
    var fileName: String
    var byteCount: Int64
    var isImage: Bool
    var newAttachment: NewNoteAttachment?
    var existing: NoteAttachment?

    init(existing: NoteAttachment) {
        id = "saved-\(existing.id)"
        fileName = existing.fileName
        byteCount = existing.byteCount
        isImage = existing.isImage
        self.existing = existing
    }

    init(fileName: String, data: Data) {
        id = UUID().uuidString
        self.fileName = fileName
        byteCount = Int64(data.count)
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
        isImage = type.conforms(to: .image) && NSImage(data: data) != nil
        newAttachment = NewNoteAttachment(fileName: fileName, data: data)
    }

    /// Reads a file now, so the note keeps it as it was when attached.
    static func load(_ url: URL) throws -> DraftAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true { throw AttachError.folder(url.lastPathComponent) }
        if let size = values.fileSize, size > RecallStore.maxAttachmentBytes { throw NoteError.attachmentTooLarge(url.lastPathComponent) }
        return DraftAttachment(fileName: url.lastPathComponent, data: try Data(contentsOf: url))
    }

    /// Files copied in Finder, or else an image (such as a screenshot copied to the clipboard).
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) throws -> [DraftAttachment] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return try urls.map(load)
        }
        if let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(pngData) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            return [DraftAttachment(fileName: "Pasted Image \(f.string(from: Date())).png", data: png)]
        }
        return []
    }

    static func pasteboardHasAttachment(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private static func pngData(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    enum AttachError: Error, LocalizedError {
        case folder(String)
        var errorDescription: String? {
            switch self {
            case .folder(let name): return "“\(name)” is a folder. Attach the files inside it, or compress it first."
            }
        }
    }
}

/// Opens or exports a note's attachment. Opening needs a decrypted copy on disk; it goes in a private
/// temporary folder that Recall empties when it starts and quits.
enum AttachmentFiles {
    static var openDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RecallForMac-Opened", isDirectory: true)
    }

    @MainActor static func open(_ attachment: NoteAttachment, store: RecallStore) throws {
        let data = try store.attachmentData(attachment)
        let dir = openDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(attachment.fileName)
        try data.write(to: url)
        NSWorkspace.shared.open(url)
    }

    @MainActor static func saveAs(_ attachment: NoteAttachment, store: RecallStore) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.fileName
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try store.attachmentData(attachment).write(to: url, options: .atomic)
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: openDirectory)
    }

    static func icon(for contentType: String) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(contentType) ?? .data)
    }
}

/// Text, attachments and project for a note; used by the New Note window and for editing.
struct NoteEditor: View {
    @Binding var draft: NoteDraft
    @Binding var importing: Bool
    var title: String
    var caption: String
    var saveTitle: String
    var onSave: () async throws -> Void
    var onCancel: () -> Void
    var cancelTitle = "Cancel"
    /// Escape cancels. Off where cancelling throws the text away.
    var escapeCancels = true

    @EnvironmentObject private var state: AppState
    @State private var projects: [ProjectRecord] = []
    @State private var error: String?
    @State private var saving = false
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $draft.text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 150)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                  lineWidth: dropTargeted ? 2 : 1))
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("Completed work on…, took lunch from 12 to 1, sent the report…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
            if !draft.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(draft.attachments) { attachment in
                        DraftAttachmentRow(attachment: attachment) { draft.attachments.removeAll { $0.id == attachment.id } }
                    }
                }
            }
            HStack {
                Button { importing = true } label: { Label("Attach Files…", systemImage: "paperclip") }
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .help("Attach the files or image on the clipboard")
                Picker("Project", selection: $draft.projectID) {
                    Text("No project").tag(Int64?.none)
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if escapeCancels {
                    Button(cancelTitle, action: onCancel).keyboardShortcut(.cancelAction)
                } else {
                    Button(cancelTitle, action: onCancel)
                }
                Button(saveTitle) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.isEmpty || saving)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("⌘↩ saves. Drop files here to attach them. Attached files are copied into Recall and encrypted, as they are now; later changes to the originals aren't picked up.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 520)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): add(urls)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .onAppear {
            projects = (try? state.store?.projects()) ?? []
            focused = true
        }
    }

    private func add(_ urls: [URL]) {
        do {
            draft.attachments += try urls.map(DraftAttachment.load)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func paste() {
        do {
            let pasted = try DraftAttachment.fromPasteboard()
            if pasted.isEmpty { error = "The clipboard has no files or images." } else { draft.attachments += pasted; error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await onSave()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct DraftAttachmentRow: View {
    let attachment: DraftAttachment
    var compact = false
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            preview.frame(width: compact ? 18 : 28, height: compact ? 18 : 28).clipShape(RoundedRectangle(cornerRadius: 3))
            Text(attachment.fileName).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove")
        }
        .font(compact ? .caption : .body)
    }

    @ViewBuilder private var preview: some View {
        if let existing = attachment.existing {
            if existing.isImage {
                StoredImage(relativePath: existing.path, maxPixel: 96)
            } else {
                Image(nsImage: AttachmentFiles.icon(for: existing.contentType)).resizable()
            }
        } else if attachment.isImage, let data = attachment.newAttachment?.data, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (attachment.fileName as NSString).pathExtension) ?? .data))
                .resizable()
        }
    }
}

/// The New Note window, opened from the menu bar or with ⌃⌥⌘N. Closing it keeps the draft.
struct NoteWindow: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NoteEditor(draft: $state.noteDraft, importing: $state.noteWindowImporting, title: "New Note",
                   caption: "Saved with the time you click Save", saveTitle: "Save Note",
                   onSave: {
                       try await state.saveNote(state.noteDraft)
                       state.noteDraft = NoteDraft()
                       dismissWindow(id: WindowID.note)
                   },
                   onCancel: {
                       state.noteDraft = NoteDraft()
                       dismissWindow(id: WindowID.note)
                   },
                   cancelTitle: "Discard", escapeCancels: false)
    }
}

/// The note field in the menu bar: type, press ⌘↩. Files go through the New Note window, whose
/// file picker can't close the menu bar panel out from under it.
struct QuickNoteView: View {
    @EnvironmentObject private var state: AppState
    var openWindow: (_ attach: Bool) -> Void
    @State private var saving = false
    @State private var savedAt: Date?
    @State private var error: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Add a note — e.g. “Finished the API review”", text: $state.noteDraft.text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
            ForEach(state.noteDraft.attachments) { attachment in
                DraftAttachmentRow(attachment: attachment, compact: true) {
                    state.noteDraft.attachments.removeAll { $0.id == attachment.id }
                }
            }
            HStack(spacing: 10) {
                Button { openWindow(true) } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("Attach files…")
                Button { openWindow(false) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help("Open in a window (\(GlobalHotKey.newNoteDisplayString))")
                if let savedAt, Date().timeIntervalSince(savedAt) < 4 {
                    Label("Saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button("Save Note") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .disabled(state.noteDraft.isEmpty || saving)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            do {
                state.noteDraft.attachments += try urls.map(DraftAttachment.load)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func save() {
        saving = true
        let draft = state.noteDraft
        Task {
            defer { saving = false }
            do {
                try await state.saveNote(draft)
                // Keep anything typed while saving.
                if state.noteDraft == draft { state.noteDraft = NoteDraft() }
                error = nil
                savedAt = Date()
                try? await Task.sleep(for: .seconds(4))
                savedAt = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
