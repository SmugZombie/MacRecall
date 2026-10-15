import RecallCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var updates = UpdateController.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let release = updates.availableRelease {
                Button { open(WindowID.update) } label: {
                    Label("Update available: \(release.version.description) — Install…", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }
            Divider()
            recordingControls
            Divider()
            QuickNoteView { attach in state.newNote(attach: attach) }
            Divider()
            aiStatus
            Divider()
            HStack {
                Button { open(WindowID.main) } label: { Label("Timeline", systemImage: "clock") }
                Button { NavigationRequest.shared.section = .search; open(WindowID.main) } label: { Label("Search", systemImage: "magnifyingglass") }
                Button { NavigationRequest.shared.section = .notes; open(WindowID.main) } label: { Label("Notes", systemImage: "note.text") }
                Spacer()
                Button { activateApp(); openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Recall")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { state.refreshPermissions(); state.refreshQueue() }
    }

    private func open(_ id: String) {
        activateApp()
        openWindow(id: id)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: state.recordingState.symbol)
                .font(.title2)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.recordingState.label).font(.headline)
                if let last = state.lastCaptureAt {
                    Text("Last capture \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let reason = state.lastSkipReason {
                    Text("Skipped: \(reason.rawValue.replacingOccurrences(of: "_", with: " "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateColor: Color {
        switch state.recordingState {
        case .recording: return .red
        case .paused: return .secondary
        case .noPermission: return .orange
        case .suspended: return .secondary
        }
    }

    @ViewBuilder private var recordingControls: some View {
        if state.recordingState == .noPermission {
            Button("Grant Screen Recording Permission…") { open(WindowID.onboarding) }
        } else if case .paused = state.recordingState {
            Button { state.resume() } label: { Label("Resume Recording", systemImage: "play.fill") }
        } else {
            HStack {
                Button { state.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                Menu("Pause for…") {
                    Button("15 minutes") { state.pause(for: 15) }
                    Button("1 hour") { state.pause(for: 60) }
                    Button("4 hours") { state.pause(for: 240) }
                }
                .fixedSize()
                Spacer()
                Button { state.captureNow() } label: { Image(systemName: "camera") }
                    .help("Capture the active window now")
            }
        }
        Text("Toggle with \(GlobalHotKey.displayString)").font(.caption2).foregroundStyle(.tertiary)
    }

    @ViewBuilder private var aiStatus: some View {
        let q = state.queueStatus
        HStack {
            Image(systemName: aiSymbol).foregroundStyle(aiColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(aiTitle).font(.subheadline)
                Text("\(q.actionablePending) queued · \(q.counts.running) running" + (q.counts.failed > 0 ? " · \(q.counts.failed) failed" : "")
                     + (q.awaitingConfiguration.isEmpty ? "" : " · \(q.awaitingConfiguration.values.reduce(0, +)) need setup"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(q.aiPaused ? "Resume AI" : "Pause AI") { state.settings.aiProcessingEnabled.toggle() }
                .controlSize(.small)
        }
        Button { NavigationRequest.shared.section = .queue; open(WindowID.main) } label: { Text("View processing queue") }
            .buttonStyle(.link).font(.caption)
    }

    private var aiTitle: String {
        let q = state.queueStatus
        if q.aiPaused { return "AI processing paused" }
        if !state.settings.aiTransmissionAllowed { return "AI waiting for approval (Settings → AI)" }
        if !q.providerReachable { return "AI unavailable (\(state.settings.aiProvider.displayName) offline)" }
        if q.actionablePending > 50 { return "AI backlog" }
        return "AI ready"
    }
    private var aiSymbol: String { state.queueStatus.providerReachable && !state.queueStatus.aiPaused && state.settings.aiTransmissionAllowed ? "sparkles" : "sparkles.slash" }
    private var aiColor: Color {
        let q = state.queueStatus
        if q.aiPaused || !q.providerReachable || !state.settings.aiTransmissionAllowed { return .secondary }
        return q.actionablePending > 50 ? .orange : .accentColor
    }
}

/// Lets the menu bar ask the main window to show a particular section.
@MainActor
final class NavigationRequest: ObservableObject {
    static let shared = NavigationRequest()
    @Published var section: SidebarSection?
    @Published var captureID: Int64?
}
