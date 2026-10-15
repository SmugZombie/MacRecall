import AppKit
import RecallCore
import SwiftUI

struct CaptureDetailView: View {
    let captureID: Int64
    /// When set (e.g. search results), Previous/Next step through these IDs instead of the whole timeline.
    var sequence: [Int64]? = nil
    var sequenceName = "Result"
    var onClose: (() -> Void)? = nil
    var onSelect: (Int64) -> Void

    @EnvironmentObject private var state: AppState
    @State private var capture: CaptureRecord?
    @State private var session: SessionRecord?
    @State private var related: [CaptureRecord] = []
    @State private var previousID: Int64?
    @State private var nextID: Int64?
    @State private var position: (index: Int, count: Int)?
    @State private var viewing: CaptureRecord?

    var body: some View {
        ScrollView {
            if let capture {
                VStack(alignment: .leading, spacing: 14) {
                    navigation(capture)
                    StoredImage(relativePath: capture.imagePath)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture(count: 2) { viewing = capture }
                        .help("Double-click to view full size")
                    metadata(capture)
                    aiSection(capture)
                    if let session { sessionSection(session) }
                    ocrSection(capture)
                    if related.count > 1 { relatedSection }
                }
                .padding(16)
            } else {
                ProgressView().padding(40)
            }
        }
        .task(id: "\(captureID)-\(state.revision)") { load() }
        .sheet(item: $viewing) { capture in
            ScreenshotViewer(capture: capture) { exportScreenshot(capture) }
        }
    }

    private func load() {
        guard let store = state.store, let c = try? store.capture(id: captureID) else { capture = nil; return }
        capture = c
        session = c.sessionID.flatMap { try? store.session(id: $0) }
        if let sequence, let i = sequence.firstIndex(of: c.id) {
            previousID = i > 0 ? sequence[i - 1] : nil
            nextID = i + 1 < sequence.count ? sequence[i + 1] : nil
            position = (i + 1, sequence.count)
        } else {
            previousID = (try? store.previousCapture(before: c.capturedAt))?.id
            nextID = (try? store.nextCapture(after: c.capturedAt))?.id
            position = nil
        }
        if let sid = c.sessionID {
            let all = (try? store.captures(inSession: sid)) ?? []
            if let i = all.firstIndex(where: { $0.id == c.id }) {
                related = Array(all[max(0, i - 6)..<min(all.count, i + 7)])
            }
        } else {
            related = []
        }
    }

    // ⌘[ / ⌘] rather than bare arrow keys, which belong to whatever text field has focus.
    private func navigation(_ c: CaptureRecord) -> some View {
        HStack {
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
            }
            Button { if let p = previousID { onSelect(p) } } label: { Image(systemName: "chevron.left") }
                .disabled(previousID == nil).keyboardShortcut("[", modifiers: .command)
                .help(position == nil ? "Previous screenshot (⌘[)" : "Previous \(sequenceName.lowercased()) (⌘[)")
            Spacer()
            VStack(spacing: 1) {
                Text(c.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.headline.monospacedDigit())
                    .help("UTC: \(c.capturedAt.formatted(.iso8601))  ·  Time zone: \(c.timezone)")
                if let position {
                    Text("\(sequenceName) \(position.index) of \(position.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { if let n = nextID { onSelect(n) } } label: { Image(systemName: "chevron.right") }
                .disabled(nextID == nil).keyboardShortcut("]", modifiers: .command)
                .help(position == nil ? "Next screenshot (⌘])" : "Next \(sequenceName.lowercased()) (⌘])")
        }
    }

    private func metadata(_ c: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AppIcon(bundleIdentifier: c.bundleIdentifier, size: 20)
                Text(c.applicationName).font(.headline)
                ProcessingBadge(capture: c)
                Spacer()
                Menu {
                    Button("View Full Size") { viewing = c }
                    Button("Export Screenshot…") { exportScreenshot(c) }
                    Button("Copy OCR Text") { copy(c.ocrText) }.disabled(c.ocrText.isEmpty)
                    Divider()
                    Button("Analyze Now") { state.prioritize(captureID: c.id) }
                    Button("Retry OCR") {
                        try? state.store?.enqueueJob(.ocr, entityType: "capture", entityID: c.id, priority: 100)
                        state.refreshQueue()
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if !c.windowTitle.isEmpty {
                Text(c.windowTitle).font(.callout).textSelection(.enabled)
            }
            let seen = c.lastSeenAt.timeIntervalSince(c.capturedAt)
            Text("\(c.width)×\(c.height)" + (seen > 1 ? " · unchanged for \(formatDuration(seen))" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func aiSection(_ c: CaptureRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let json = c.aiJSON?.data(using: .utf8), let a = try? JSONDecoder().decode(ActivityAnalysis.self, from: json) {
                    HStack {
                        Text(a.activity).font(.headline)
                        if let p = a.project { StatusPill(text: p, color: .accentColor) }
                        Spacer()
                        Text("confidence \(Int(a.confidence * 100))%").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(a.description).textSelection(.enabled)
                    if !a.topics.isEmpty {
                        Text(a.topics.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    switch c.aiStatus {
                    case .pending: Text("Waiting for AI analysis.").foregroundStyle(.secondary)
                    case .running: Text("Analyzing…").foregroundStyle(.secondary)
                    case .failed: Text("AI analysis failed. Use “Analyze Now” to retry.").foregroundStyle(.secondary)
                    case .skipped: Text("No AI model configured.").foregroundStyle(.secondary)
                    case .done: Text("No description.").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("AI description", systemImage: "sparkles") }
    }

    private func sessionSection(_ s: SessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title).font(.headline)
                Text("\(timeRange(s.startedAt, s.endedAt)) · \(formatDuration(s.activeSeconds)) active · \(s.captureCount) screenshots")
                    .font(.caption).foregroundStyle(.secondary)
                if !s.summary.isEmpty { Text(s.summary).textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Session", systemImage: "rectangle.stack") }
    }

    private func ocrSection(_ c: CaptureRecord) -> some View {
        GroupBox {
            Group {
                if c.ocrText.isEmpty {
                    Text(c.ocrStatus == .done ? "No text recognized." : "Text recognition \(c.ocrStatus.rawValue).")
                        .foregroundStyle(.secondary)
                } else {
                    Text(c.ocrText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Label("Recognized text", systemImage: "text.viewfinder")
                if let conf = c.ocrConfidence { Text("\(Int(conf * 100))%").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Related screenshots").font(.headline)
            ScrollView(.horizontal) {
                LazyHStack {
                    ForEach(related) { r in
                        StoredImage(relativePath: r.thumbnailPath, maxPixel: 240)
                            .frame(width: 110, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(r.id == captureID ? Color.accentColor : .clear, lineWidth: 2))
                            .onTapGesture { onSelect(r.id) }
                    }
                }
            }
            .frame(height: 76)
        }
    }

    /// Screenshots are encrypted on disk, so other apps get a decrypted copy only by exporting one.
    private func exportScreenshot(_ c: CaptureRecord) {
        guard let store = state.store else { return }
        let data: Data
        do {
            data = try store.vault.read(c.imagePath)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let panel = NSSavePanel()
        let ext = (c.imagePath as NSString).pathExtension
        let stamp = c.capturedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateTimeSeparator(.space).timeSeparator(.omitted))
        panel.nameFieldStringValue = "\(c.applicationName) \(stamp).\(ext)"
        panel.message = "The exported copy isn't encrypted."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Full-resolution view of one screenshot, decrypted in memory.
private struct ScreenshotViewer: View {
    let capture: CaptureRecord
    let onExport: () -> Void
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var error: String?
    @State private var actualSize = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(capture.applicationName) · \(capture.capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.headline)
                Spacer()
                Picker("", selection: $actualSize) {
                    Text("Fit").tag(false)
                    Text("Actual Size").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button("Export…", action: onExport)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            Group {
                if let image {
                    if actualSize {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).frame(width: image.size.width, height: image.size.height)
                        }
                    } else {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(12)
                    }
                } else if let error {
                    ContentUnavailableView("Can't Show Screenshot", systemImage: "lock.fill", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, idealWidth: 1100, minHeight: 560, idealHeight: 760)
        .task {
            guard let vault = state.store?.vault else { return }
            do {
                image = try await ImageCache.shared.image(capture.imagePath, maxPixel: nil, vault: vault)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
