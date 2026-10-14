import AppKit
import RecallCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            CaptureSettings().tabItem { Label("Capture", systemImage: "camera") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            StorageSettings().tabItem { Label("Storage", systemImage: "internaldrive") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: Capture

private struct CaptureSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Toggle("Recording enabled", isOn: $state.settings.recordingEnabled)
            LabeledContent("Capture every") {
                HStack {
                    Slider(value: $state.settings.captureInterval, in: 10...300, step: 5)
                    Text("\(Int(state.settings.captureInterval)) s").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            Toggle("Also capture when the focused window changes", isOn: $state.settings.captureOnWindowChange)
            Section("Images") {
                Picker("Format", selection: $state.settings.imageFormat) {
                    Text("HEIC (smaller)").tag(ImageFormat.heic)
                    Text("JPEG").tag(ImageFormat.jpeg)
                }
                LabeledContent("Quality") {
                    Slider(value: $state.settings.compressionQuality, in: 0.2...1)
                }
                LabeledContent("Maximum size") {
                    HStack {
                        TextField("Width", value: $state.settings.maxImageWidth, format: .number).frame(width: 70)
                        Text("×")
                        TextField("Height", value: $state.settings.maxImageHeight, format: .number).frame(width: 70)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Duplicate detection") {
                    VStack(alignment: .leading) {
                        Slider(value: $state.settings.dedupSensitivity, in: 0...1)
                        Text("Higher sensitivity stores more frames with small changes.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Include mouse cursor", isOn: $state.settings.captureCursor)
            }
            Section("Activity") {
                LabeledContent("Idle after") {
                    Picker("", selection: $state.settings.idleTimeout) {
                        ForEach([60.0, 120, 300, 600, 900, 1800], id: \.self) { Text("\(Int($0 / 60)) min").tag($0) }
                    }.labelsHidden()
                }
                Toggle("Pause capture on battery power", isOn: $state.settings.pauseOnBattery)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy

private struct PrivacySettings: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmDeleteAll = false
    @State private var deleteFrom = Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
    @State private var deleteTo = Date()
    @State private var message: String?
    @State private var newRuleName = ""
    @State private var newRulePattern = ""

    var body: some View {
        Form {
            Section("Excluded applications") {
                ForEach(state.settings.excludedBundleIdentifiers, id: \.self) { bundle in
                    HStack {
                        AppIcon(bundleIdentifier: bundle, size: 16)
                        Text(Self.name(for: bundle))
                        Text(bundle).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { state.settings.excludedBundleIdentifiers.removeAll { $0 == bundle } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu("Add Running App") {
                        ForEach(runningApps, id: \.self) { bundle in
                            Button(Self.name(for: bundle)) { add(bundle) }
                        }
                    }
                    Button("Choose App…") { chooseApp() }
                }
                Text("Excluded apps are never captured — the check happens before any pixels are read. Password fields (secure input) are always skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Retention") {
                Stepper("Keep screenshots for \(state.settings.retentionDays) days", value: $state.settings.retentionDays, in: 1...3650)
                Toggle("Delete older history automatically", isOn: $state.settings.automaticCleanup)
            }
            Section("Sensitive content") {
                Toggle("Redact matching text before storing or sending to AI", isOn: $state.settings.redactionEnabled)
                if state.settings.redactionEnabled {
                    ForEach($state.settings.sensitiveRules.rules) { $rule in
                        Toggle(rule.name, isOn: $rule.enabled).help(rule.pattern)
                    }
                    HStack {
                        TextField("Rule name", text: $newRuleName).frame(width: 140)
                        TextField("Regular expression", text: $newRulePattern)
                        Button("Add") {
                            guard (try? NSRegularExpression(pattern: newRulePattern)) != nil else { message = "Invalid regular expression."; return }
                            state.settings.sensitiveRules.rules.append(.init(name: newRuleName, pattern: newRulePattern))
                            newRuleName = ""; newRulePattern = ""
                        }
                        .disabled(newRuleName.isEmpty || newRulePattern.isEmpty)
                    }
                    Text("Matching lines are blacked out in the screenshot and replaced in recognized text. OCR can miss secrets, so this is a safety net, not a guarantee — exclude sensitive apps too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Delete history") {
                HStack {
                    DatePicker("From", selection: $deleteFrom).labelsHidden()
                    Text("to")
                    DatePicker("To", selection: $deleteTo).labelsHidden()
                    Button("Delete Range") {
                        let n = (try? state.store?.deleteCaptures(from: deleteFrom, to: deleteTo)) ?? 0
                        message = "Deleted \(n) screenshots."
                        state.historyChanged()
                    }
                }
                HStack {
                    Button("Delete Last Hour") {
                        let n = (try? state.store?.deleteCaptures(from: Date().addingTimeInterval(-3600), to: .distantFuture)) ?? 0
                        message = "Deleted \(n) screenshots."
                        state.historyChanged()
                    }
                    Button("Clear AI Data") {
                        try? state.store?.clearAIMetadata()
                        message = "AI descriptions, summaries and embeddings were removed."
                        state.historyChanged()
                    }
                    Button("Rebuild Search Index") {
                        try? state.store?.rebuildSearchIndexes()
                        message = "Search index rebuilt."
                    }
                    Spacer()
                    Button("Delete All History…", role: .destructive) { confirmDeleteAll = true }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all history?", isPresented: $confirmDeleteAll) {
            Button("Delete Everything", role: .destructive) {
                try? state.store?.deleteAllHistory()
                message = "All history deleted."
                state.historyChanged()
            }
        } message: {
            Text("All screenshots, recognized text, sessions and summaries will be permanently removed. Projects are kept.")
        }
    }

    private var runningApps: [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !state.settings.excludedBundleIdentifiers.contains($0) && $0 != Bundle.main.bundleIdentifier }
            .sorted { Self.name(for: $0) < Self.name(for: $1) }
    }

    private func add(_ bundle: String) {
        if !state.settings.excludedBundleIdentifiers.contains(bundle) { state.settings.excludedBundleIdentifiers.append(bundle) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier { add(bundle) }
    }

    static func name(for bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: AI

private struct AISettings: View {
    @EnvironmentObject private var state: AppState
    @State private var endpoint = ""
    @State private var models: [OllamaModel] = []
    @State private var capabilities: [String: [String]] = [:]
    @State private var connection: String?
    @State private var testing = false
    @State private var confirmRemote = false

    var body: some View {
        Form {
            Section("Ollama server") {
                HStack {
                    TextField("Endpoint", text: $endpoint).onSubmit { apply() }
                    Button("Apply") { apply() }.disabled(endpoint == state.settings.ollamaEndpoint)
                    Button("Test") { Task { await test() } }.disabled(testing)
                }
                if let connection { Text(connection).font(.caption).foregroundStyle(.secondary) }
                if state.settings.endpointIsRemote {
                    Label("Screenshots and recognized text are sent to \(state.settings.ollamaEndpoint), which is not this Mac.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Models") {
                modelPicker("Vision", selection: $state.settings.visionModel, capability: "vision",
                            help: "Describes screenshots. Without one, the summary model analyzes recognized text only.")
                modelPicker("Summary", selection: $state.settings.summaryModel, capability: "completion",
                            help: "Session titles, daily overviews and answers to questions.")
                modelPicker("Embedding", selection: $state.settings.embeddingModel, capability: "embedding",
                            help: "Semantic search. Changing it requires re-embedding history.")
                if models.isEmpty {
                    Text("No models found. Install one with e.g. `ollama pull qwen2.5vl` — Recall never downloads models itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Processing") {
                Toggle("Background AI processing", isOn: $state.settings.aiProcessingEnabled)
                Stepper("Concurrent requests: \(state.settings.maxConcurrentRequests)", value: $state.settings.maxConcurrentRequests, in: 1...8)
                Stepper("Request timeout: \(Int(state.settings.requestTimeout)) s", value: $state.settings.requestTimeout, in: 10...900, step: 10)
                Button("Reprocess Pending and Failed Screenshots") { state.reprocessPending() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            endpoint = state.settings.ollamaEndpoint
            Task { await test() }
        }
        .alert("Use a remote Ollama server?", isPresented: $confirmRemote) {
            Button("Use Remote Server", role: .destructive) {
                state.settings.remoteEndpointAcknowledged = true
                state.settings.ollamaEndpoint = endpoint
                Task { await test() }
            }
            Button("Cancel", role: .cancel) { endpoint = state.settings.ollamaEndpoint }
        } message: {
            Text("\(endpoint) is not on this Mac. Screenshots, recognized text and activity summaries will be sent to it over the network. Only use a server you control, ideally over an encrypted connection.")
        }
    }

    private func modelPicker(_ title: String, selection: Binding<String>, capability: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(title, selection: selection) {
                Text("None").tag("")
                ForEach(models) { model in
                    let caps = capabilities[model.name] ?? []
                    let suitable = caps.isEmpty || caps.contains(capability)
                    Text(model.name + (suitable ? "" : "  (no \(capability))")).tag(model.name)
                }
                if !selection.wrappedValue.isEmpty && !models.contains(where: { $0.name == selection.wrappedValue }) {
                    Text("\(selection.wrappedValue) (not installed)").tag(selection.wrappedValue)
                }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func apply() {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            connection = "Enter a URL such as http://127.0.0.1:11434"
            return
        }
        endpoint = trimmed
        if !OllamaEndpoint.isLoopback(trimmed) {
            confirmRemote = true
        } else {
            state.settings.ollamaEndpoint = trimmed
            Task { await test() }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            models = try await state.ollama.listModels()
            for model in models {
                capabilities[model.name] = (try? await state.ollama.capabilities(of: model.name)) ?? []
            }
            connection = "Connected to \(state.settings.ollamaEndpoint) — \(models.count) models"
        } catch {
            models = []
            connection = error.localizedDescription
        }
        _ = await state.checkOllama()
    }
}

// MARK: Storage

private struct StorageSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var stats: StorageStats?
    @State private var cleaning = false

    var body: some View {
        Form {
            if let stats {
                LabeledContent("Total disk usage", value: ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))
                LabeledContent("Screenshots", value: "\(stats.captureCount)")
                LabeledContent("Images", value: ByteCountFormatter.string(fromByteCount: stats.imageBytes, countStyle: .file))
                LabeledContent("Database", value: ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file))
                LabeledContent("Oldest screenshot", value: stats.oldestCapture?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            } else {
                ProgressView()
            }
            if let root = state.store?.paths.root {
                LabeledContent("Location") {
                    Button(root.path) { NSWorkspace.shared.open(root) }.buttonStyle(.link)
                }
            }
            HStack {
                Button("Apply Retention Now") {
                    cleaning = true
                    state.runRetention()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await load()
                        cleaning = false
                    }
                }
                .disabled(cleaning)
                Button("Refresh") { Task { await load() } }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        guard let store = state.store else { return }
        stats = await Task.detached { try? store.storageStats() }.value
    }
}

// MARK: General

private struct GeneralSettings: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Toggle("Open Recall at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
            LabeledContent("Pause/resume shortcut", value: GlobalHotKey.displayString)
            Toggle("Show time zone in timestamps", isOn: $state.settings.showTimezone)
            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    PermissionStatus(granted: state.hasScreenPermission)
                }
                LabeledContent("Accessibility") {
                    PermissionStatus(granted: state.hasAccessibility)
                }
                Button("Open Permission Setup…") { activateApp(); openWindow(id: WindowID.onboarding) }
            }
            Section {
                Text("Recall stores everything locally in ~/Library/Application Support/RecallForMac. It has no telemetry, accounts or cloud sync; the only network traffic is to the Ollama server you configure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionStatus: View {
    let granted: Bool
    var body: some View {
        Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(granted ? .green : .orange)
    }
}
