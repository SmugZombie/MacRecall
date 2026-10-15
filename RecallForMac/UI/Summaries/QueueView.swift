import AppKit
import RecallCore
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var jobs: [JobRecord] = []
    @State private var selection: JobRecord.ID?
    @State private var filter: ProcessingStatus?

    var body: some View {
        let q = state.queueStatus
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                stat("Queued", q.actionablePending)
                stat("Running", q.counts.running)
                stat("Failed", q.counts.failed)
                VStack(alignment: .leading) {
                    let name = state.settings.aiProvider.displayName
                    Label(q.providerReachable ? "\(name) connected" : "\(name) unavailable",
                          systemImage: q.providerReachable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(q.providerReachable ? .green : .secondary)
                    Text(state.settings.aiTransmissionAllowed
                         ? "AI jobs wait while the provider is unavailable; OCR continues."
                         : "AI jobs wait until you approve sending data to \(state.settings.aiDestination) in Settings → AI.")
                        .font(.caption).foregroundStyle(.secondary)
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
            if !q.awaitingConfiguration.isEmpty { setupBanner(q.awaitingConfiguration) }
            let runnable = q.counts.byType.filter { q.awaitingConfiguration[$0.key] == nil }
            if !runnable.isEmpty {
                HStack {
                    ForEach(runnable.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { type, n in
                        StatusPill(text: "\(type.rawValue.replacingOccurrences(of: "_", with: " ")): \(n)")
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error = q.lastError {
                Text("Last error: \(error)").font(.caption).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            HStack {
                Picker("Show", selection: $filter) {
                    Text("All").tag(ProcessingStatus?.none)
                    Text("Failed").tag(Optional(ProcessingStatus.failed))
                    Text("Pending").tag(Optional(ProcessingStatus.pending))
                    Text("Running").tag(Optional(ProcessingStatus.running))
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text("Select a job to see its full error.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Table(jobs, selection: $selection) {
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
            .contextMenu(forSelectionType: JobRecord.ID.self) { ids in
                if let job = jobs.first(where: { ids.contains($0.id) }) {
                    Button("Copy Error") { copy(job.lastError ?? "") }.disabled(job.lastError == nil)
                    Button("Retry") { retry(job) }.disabled(job.status != .failed)
                }
            }
            if let job = jobs.first(where: { $0.id == selection }) {
                Divider()
                detail(job)
            }
        }
        .navigationTitle("Processing")
        .task(id: "\(state.queueStatus.counts.pending)-\(state.queueStatus.counts.failed)-\(state.queueStatus.counts.running)-\(String(describing: filter))") { reload() }
        .onAppear { state.refreshQueue() }
    }

    /// Jobs that can't run until a model is chosen. Not a backlog: they wait, and choosing a model processes them.
    private func setupBanner(_ waiting: [JobType: Int]) -> some View {
        let parts = waiting.sorted { $0.key.rawValue < $1.key.rawValue }.map { type, n -> String in
            switch type {
            case .embedding: return "\(n) embedding job\(n == 1 ? "" : "s") need an embedding model (semantic search)"
            case .visionAnalysis: return "\(n) screenshot\(n == 1 ? "" : "s") need a vision or summary model"
            case .sessionSummary, .dailySummary: return "\(n) summar\(n == 1 ? "y needs" : "ies need") a summary model"
            default: return "\(n) \(type.rawValue) job\(n == 1 ? "" : "s") waiting"
            }
        }
        // No .fixedSize(vertical:) on the text: at the near-zero width AppKit probes for the window's
        // minimum size, it reported a 2,000+ pt height and pushed the whole window's content off-screen.
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for setup, not a backlog").font(.subheadline.weight(.semibold))
                Text(parts.joined(separator: "; ") + ". They'll be processed once you choose a model in Settings → AI\(state.settings.aiProvider == .lmStudio ? " (LM Studio includes an embedding model such as nomic-embed-text)" : "").")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button("Open AI Settings…") { activateApp(); openSettings() }.fixedSize()
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func reload() { jobs = (try? state.store?.recentJobs(limit: 300, status: filter)) ?? [] }

    private func detail(_ job: JobRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(job.type.rawValue.replacingOccurrences(of: "_", with: " ")) · \(job.entityType) \(job.entityID)").font(.headline)
                StatusPill(text: job.status.rawValue, color: color(job.status))
                Text("\(job.attempts) attempt\(job.attempts == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if job.entityType == "capture" {
                    Button("Show Screenshot") {
                        NavigationRequest.shared.section = .today
                        NavigationRequest.shared.captureID = job.entityID
                    }
                }
                Button("Copy Error") { copy(job.lastError ?? "") }.disabled(job.lastError == nil)
                Button("Retry") { retry(job) }.disabled(job.status != .failed)
            }
            ScrollView {
                Text(job.lastError ?? "No error recorded.")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(job.lastError == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
        .padding(16)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func retry(_ job: JobRecord) {
        try? state.store?.retryJob(id: job.id)
        if job.type == .visionAnalysis { try? state.store?.setAIStatus(captureID: job.entityID, .pending) }
        state.refreshQueue()
        reload()
    }

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
