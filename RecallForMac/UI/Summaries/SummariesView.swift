import AppKit
import RecallCore
import SwiftUI

struct SummariesView: View {
    @EnvironmentObject private var state: AppState
    @State private var date = Date()
    @State private var summary: DailySummaryRecord?
    @State private var generating = false
    @State private var error: String?

    private var dayKey: Int64 { DailySummaryService.dayKey(for: date) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DatePicker("Day", selection: $date, in: ...Date(), displayedComponents: .date)
                    .frame(maxWidth: 220)
                Spacer()
                if generating { ProgressView().controlSize(.small) }
                Button(summary == nil ? "Generate" : "Regenerate") { generate() }
                    .disabled(generating)
                    .help("Rebuild from the current sessions, projects and AI results")
                Button { copy() } label: { Label("Copy Markdown", systemImage: "doc.on.doc") }
                    .disabled(summary == nil)
            }
            .padding(12)
            Divider()
            ScrollView {
                if let summary {
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownBlocks(markdown: summary.summary)
                        Text("Generated \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary).padding(.top, 12)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(.red).padding(40)
                } else {
                    ContentUnavailableView("No summary yet", systemImage: "doc.text",
                                           description: Text("Generate a summary of this day's observed activity. Times are computed from captures; the overview paragraph needs a summary model."))
                }
            }
        }
        .navigationTitle("Daily Summaries")
        .task(id: "\(dayKey)-\(state.revision)") { load() }
    }

    private func load() {
        summary = try? state.store?.dailySummary(localDate: DailySummaryService.localDateString(dayKey), timezone: TimeZone.current.identifier)
        error = nil
    }

    private func generate() {
        guard let store = state.store else { return }
        generating = true
        let settings = state.settings
        let ai: (any AIProvider)? = state.queueStatus.providerReachable && settings.aiTransmissionAllowed ? state.ai : nil
        let key = dayKey
        state.updateSessions()
        Task {
            defer { generating = false }
            do {
                summary = try await DailySummaryService(store: store, ai: ai, settings: { settings }).generate(dayKey: key)
            } catch {
                // Fall back to the facts-only version if the model fails.
                do {
                    summary = try await DailySummaryService(store: store, ai: nil, settings: { settings }).generate(dayKey: key)
                    self.error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func copy() {
        guard let summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.summary, forType: .string)
    }
}

/// Minimal block-level Markdown renderer (headings, bullets, paragraphs) on top of inline AttributedString parsing.
struct MarkdownBlocks: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(.title.bold()).padding(.bottom, 4)
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(.title3.bold()).padding(.top, 10)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(line.dropFirst(2))))
            }
        } else if line.hasPrefix("  ") {
            Text(inline(line.trimmingCharacters(in: .whitespaces))).foregroundStyle(.secondary).padding(.leading, 14)
        } else if !line.isEmpty {
            Text(inline(line))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
