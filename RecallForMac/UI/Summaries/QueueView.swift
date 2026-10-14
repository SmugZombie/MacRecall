import RecallCore
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var state: AppState
    @State private var jobs: [JobRecord] = []

    var body: some View {
        let q = state.queueStatus
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                stat("Queued", q.counts.pending)
                stat("Running", q.counts.running)
                stat("Failed", q.counts.failed)
                VStack(alignment: .leading) {
                    Label(q.ollamaReachable ? "Ollama connected" : "Ollama offline",
                          systemImage: q.ollamaReachable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(q.ollamaReachable ? .green : .secondary)
                    Text("AI jobs wait while Ollama is offline; OCR continues.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("AI processing", isOn: $state.settings.aiProcessingEnabled).toggleStyle(.switch)
                Button("Retry Failed") {
                    try? state.store?.retryFailedJobs()
                    state.refreshQueue()
                    reload()
                }
                .disabled(q.counts.failed == 0)
            }
            .padding(16)
            if !q.counts.byType.isEmpty {
                HStack {
                    ForEach(q.counts.byType.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { type, n in
                        StatusPill(text: "\(type.rawValue.replacingOccurrences(of: "_", with: " ")): \(n)")
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error = q.lastError {
                Text("Last error: \(error)").font(.caption).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            Table(jobs) {
                TableColumn("Job") { Text($0.type.rawValue.replacingOccurrences(of: "_", with: " ")) }
                TableColumn("Target") { Text("\($0.entityType) \($0.entityID)").monospacedDigit() }
                TableColumn("Status") { job in
                    StatusPill(text: job.status.rawValue, color: color(job.status))
                }
                TableColumn("Priority") { Text("\($0.priority)").monospacedDigit() }.width(60)
                TableColumn("Attempts") { Text("\($0.attempts)").monospacedDigit() }.width(60)
                TableColumn("Created") { Text($0.createdAt.formatted(date: .omitted, time: .standard)) }
                TableColumn("Error") { Text($0.lastError ?? "").foregroundStyle(.secondary).lineLimit(1).help($0.lastError ?? "") }
            }
        }
        .navigationTitle("Processing")
        .task(id: state.queueStatus) { reload() }
        .onAppear { state.refreshQueue() }
    }

    private func reload() { jobs = (try? state.store?.recentJobs(limit: 200)) ?? [] }

    private func stat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading) {
            Text("\(n)").font(.title2.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(_ s: ProcessingStatus) -> Color {
        switch s {
        case .pending: return .orange
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}
