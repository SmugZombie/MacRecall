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
            Section("Clipboard") {
                Toggle(isOn: $state.settings.captureScreenClippings) {
                    Text("Save screen clippings")
                    Text("Stores screenshots you take to the clipboard (⌃⇧⌘4, or ⌃⇧⌘3 for the whole screen).")
                }
                Toggle(isOn: $state.settings.captureCopiedImages) {
                    Text("Save copied images")
                    Text("Stores images you copy from apps, such as Copy Image in a browser or ⌘C in Preview.")
                }
                Text("Saved images are attributed to the app in front when you copied them, and are read, redacted and analyzed like other screenshots. Nothing is saved while recording is paused or when the app in front is excluded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text("Notes you write are kept until you delete them, or delete all history below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScreenshotEncryptionSection()
            MCPAccessSection()
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
            Text("All screenshots, recognized text, sessions, summaries and notes (with their attachments) will be permanently removed. Projects are kept.")
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
    @State private var apiKey = ""
    @State private var region = ""
    @State private var authMode: BedrockAuthMode = .apiKey
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var profile = ""
    @State private var models: [AIModel] = []
    @State private var connection: (ok: Bool, message: String)?
    @State private var testing = false
    @State private var confirmReembed = false

    private var provider: AIProviderKind { state.settings.aiProvider }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $state.settings.aiProvider) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                Text(providerBlurb).font(.caption).foregroundStyle(.secondary)
            }
            if state.settings.providerIsRemote { approvalSection }
            if provider == .appleIntelligence { appleIntelligenceLimits }
            connectionSection
            modelsSection
            Section("Processing") {
                Toggle("Background AI processing", isOn: $state.settings.aiProcessingEnabled)
                Stepper("Concurrent requests: \(state.settings.maxConcurrentRequests)", value: $state.settings.maxConcurrentRequests, in: 1...8)
                Stepper("Request timeout: \(Int(state.settings.requestTimeout)) s", value: $state.settings.requestTimeout, in: 10...900, step: 10)
                HStack {
                    Button("Reprocess Pending and Failed Screenshots") { state.reprocessPending() }
                    Button("Re-embed History…") { confirmReembed = true }.disabled(state.settings.embeddingModel.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadDrafts(); Task { await test() } }
        .onChange(of: state.settings.aiProvider) { loadDrafts(); models = []; connection = nil; Task { await test() } }
        .confirmationDialog("Re-embed all history?", isPresented: $confirmReembed) {
            Button("Re-embed") { state.rebuildEmbeddings() }
        } message: {
            Text("Every screenshot and session is embedded again with \(state.settings.embeddingModel) for semantic search."
                 + (provider.isCloud ? " With a cloud provider this sends all recognized text to \(provider.displayName) and incurs usage costs." : ""))
        }
    }

    private var providerBlurb: String {
        switch provider {
        case .ollama: return "Runs models locally with Ollama (ollama.com)."
        case .lmStudio: return "Runs models locally with LM Studio's OpenAI-compatible server (Developer tab → Start Server)."
        case .openAI: return "OpenAI's API, or any OpenAI-compatible service via a custom base URL. Requires an API key."
        case .bedrock: return "Amazon Bedrock in your AWS account. Authenticate with a Bedrock API key, IAM access keys, or an AWS CLI profile (including SSO)."
        case .appleIntelligence: return "Apple's on-device model, built into macOS 26. Nothing leaves this Mac, there's nothing to install or pay for, and no approval is needed."
        }
    }

    // MARK: Apple Intelligence

    private var appleIntelligenceLimits: some View {
        Section {
            limit("eye.slash", "No screenshot vision",
                  "The model can't read images. Screenshots are described from their recognized text and window title, so charts, photos, designs and anything OCR misses aren't described.")
            limit("text.badge.minus", "Short memory",
                  "It reads about 4,000 tokens at a time (roughly 10 pages of text). Long screens, busy sessions, full days and Ask questions with many results are shortened in the middle to fit.")
            limit("gauge.with.dots.needle.33percent", "A small model",
                  "Summaries and answers are plainer and more often miss nuance than with large local models or cloud models such as OpenAI's or Bedrock's.")
            limit("magnifyingglass", "Simpler semantic search",
                  "Search uses Apple's NaturalLanguage embeddings, which find related wording less reliably than dedicated embedding models, and work best for languages written in the Latin alphabet. After switching, use Re-embed History so older activity is searchable.")
            limit("hand.raised", "Safety guardrails",
                  "Apple's model can decline some content. Those screenshots or sessions are marked failed and skipped, not retried.")
            limit("checkmark.shield", "Requirements",
                  "macOS 26 Tahoe or later on Apple silicon, with Apple Intelligence turned on in System Settings and a supported language.")
        } header: {
            Text("Compared with other providers")
        } footer: {
            Text("You can switch providers at any time; each provider keeps its own model choices and search index.")
        }
    }

    private func limit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
    }

    // MARK: Remote approval

    private var approvalSection: some View {
        Section {
            if state.settings.aiTransmissionAllowed {
                Label("Screenshots and recognized text are sent to \(state.settings.aiDestination).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Revoke Approval") {
                    state.settings.acknowledgedRemoteTargets.removeAll { $0 == state.settings.remoteTargetKey }
                }
            } else {
                Label("AI is paused until you approve this destination.", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                Text("Using \(provider.displayName) sends screenshots, recognized text and activity summaries to \(state.settings.aiDestination), outside this Mac. "
                     + (provider.isCloud ? "Each analyzed screenshot is a billable request — with capture every \(Int(state.settings.captureInterval)) s that can add up. " : "")
                     + "Redaction rules apply to text before it is sent, but can't catch everything in images.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Allow Sending Data to \(provider.displayName)") { state.settings.acknowledgeRemoteTarget() }
            }
        } header: { Text("Data leaves this Mac") }
    }

    // MARK: Connection

    @ViewBuilder private var connectionSection: some View {
        Section("Connection") {
            switch provider {
            case .ollama:
                TextField("Endpoint", text: $endpoint, prompt: Text("http://127.0.0.1:11434"))
            case .lmStudio:
                TextField("Endpoint", text: $endpoint, prompt: Text(OpenAICompatibleProvider.defaultLMStudioEndpoint))
                SecureField("API key (optional)", text: $apiKey)
            case .openAI:
                TextField("Base URL", text: $endpoint, prompt: Text(OpenAICompatibleProvider.defaultOpenAIEndpoint))
                SecureField("API key", text: $apiKey, prompt: Text("sk-…"))
            case .appleIntelligence:
                if let reason = AppleIntelligenceProvider.unavailabilityReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Label("Ready on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .bedrock:
                TextField("Region", text: $region, prompt: Text("us-east-1"))
                Picker("Authentication", selection: $authMode) {
                    ForEach(BedrockAuthMode.allCases) { Text($0.displayName).tag($0) }
                }
                switch authMode {
                case .apiKey:
                    SecureField("Bedrock API key", text: $apiKey)
                case .accessKeys:
                    TextField("Access key ID", text: $accessKeyID, prompt: Text("AKIA…"))
                    SecureField("Secret access key", text: $secretAccessKey)
                    SecureField("Session token (optional)", text: $sessionToken)
                case .profile:
                    TextField("Profile", text: $profile, prompt: Text("default"))
                    Text("Static keys are read from ~/.aws/credentials. SSO and other profile types are resolved with the AWS CLI (`aws configure export-credentials`), so sign in with the CLI first.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(provider == .appleIntelligence ? "Check Again" : "Save & Test") { apply() }.keyboardShortcut(.defaultAction)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let connection {
                Text(connection.message)
                    .font(.caption)
                    .foregroundStyle(connection.ok ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider.isCloud || provider == .lmStudio {
                Text("Keys are stored in your login keychain.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Models

    private var modelsSection: some View {
        Section("Models") {
            if provider == .appleIntelligence {
                LabeledContent("Vision") { Text("Not available").foregroundStyle(.secondary) }
                Text("Apple's model reads text only, so the summary model describes screenshots from their recognized text.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ModelField(title: "Vision", selection: $state.settings.visionModel, models: models, capability: .vision,
                           help: "Describes screenshots. Without one, the summary model analyzes recognized text only.")
            }
            ModelField(title: "Summary", selection: $state.settings.summaryModel, models: models, capability: .completion,
                       help: "Session titles, daily overviews and answers to questions.")
            ModelField(title: "Embedding", selection: $state.settings.embeddingModel, models: models, capability: .embedding,
                       help: "Semantic search. After changing it, re-embed history so older activity is searchable.")
            Text(modelHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelHint: String {
        switch provider {
        case .ollama: return "Install models with e.g. `ollama pull qwen2.5vl`, `ollama pull llama3.2`, `ollama pull nomic-embed-text`. Recall never downloads models itself."
        case .lmStudio: return "Download models in LM Studio. A vision-capable (VLM) model can serve as both vision and summary model."
        case .openAI: return "A vision-capable chat model can serve as both vision and summary model; use a text-embedding model for search."
        case .bedrock: return "Many current models must be invoked through an inference profile ID (e.g. one starting with “us.” or “global.”). Embeddings support Amazon Titan Text Embeddings and Cohere Embed. Model access must be enabled in the Bedrock console."
        case .appleIntelligence: return "Apple Intelligence has one text model (\(AppleIntelligenceProvider.languageModel)) and uses Apple's NaturalLanguage embeddings (\(AppleIntelligenceProvider.embeddingModel)); both are selected for you. Clear one to stop that kind of processing."
        }
    }

    // MARK: Actions

    private func loadDrafts() {
        let s = state.settings
        switch s.aiProvider {
        case .ollama: endpoint = s.ollamaEndpoint; apiKey = ""
        case .lmStudio: endpoint = s.lmStudioEndpoint; apiKey = Keychain.get(.lmStudioAPIKey) ?? ""
        case .openAI: endpoint = s.openAIEndpoint; apiKey = Keychain.get(.openAIAPIKey) ?? ""
        case .bedrock:
            region = s.bedrockRegion
            authMode = s.bedrockAuthMode
            profile = s.bedrockProfile
            apiKey = Keychain.get(.bedrockAPIKey) ?? ""
            accessKeyID = Keychain.get(.awsAccessKeyID) ?? ""
            secretAccessKey = Keychain.get(.awsSecretAccessKey) ?? ""
            sessionToken = Keychain.get(.awsSessionToken) ?? ""
        case .appleIntelligence: break
        }
    }

    private func apply() {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
        if provider != .bedrock && provider != .appleIntelligence {
            guard let url = URL(string: trimmedEndpoint), url.scheme == "http" || url.scheme == "https", url.host != nil else {
                connection = (false, "Enter a full URL, e.g. \(provider == .ollama ? "http://127.0.0.1:11434" : OpenAICompatibleProvider.defaultLMStudioEndpoint)")
                return
            }
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .ollama:
            state.settings.ollamaEndpoint = trimmedEndpoint
        case .lmStudio:
            state.settings.lmStudioEndpoint = trimmedEndpoint
            Keychain.set(key, for: .lmStudioAPIKey)
        case .openAI:
            state.settings.openAIEndpoint = trimmedEndpoint
            Keychain.set(key, for: .openAIAPIKey)
        case .bedrock:
            state.settings.bedrockRegion = region.trimmingCharacters(in: .whitespaces).isEmpty ? "us-east-1" : region.trimmingCharacters(in: .whitespaces)
            state.settings.bedrockAuthMode = authMode
            state.settings.bedrockProfile = profile.trimmingCharacters(in: .whitespaces).isEmpty ? "default" : profile.trimmingCharacters(in: .whitespaces)
            switch authMode {
            case .apiKey: Keychain.set(key, for: .bedrockAPIKey)
            case .accessKeys:
                Keychain.set(accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines), for: .awsAccessKeyID)
                Keychain.set(secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .awsSecretAccessKey)
                Keychain.set(sessionToken.trimmingCharacters(in: .whitespacesAndNewlines), for: .awsSessionToken)
            case .profile: break
            }
        case .appleIntelligence: break
        }
        state.credentialsChanged()
        Task { await test() }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        models = (try? await state.ai.listModels()) ?? []
        connection = await state.diagnoseAI()
    }
}

/// Free-text model ID with a menu of discovered models. Free text matters for Bedrock and OpenAI,
/// where credentials may not allow listing or the list may not include every usable ID.
private struct ModelField: View {
    let title: String
    @Binding var selection: String
    let models: [AIModel]
    let capability: ModelCapability
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                TextField(title, text: $selection, prompt: Text("None"))
                Menu {
                    Button("None") { selection = "" }
                    let suited = models.filter { $0.supports(capability) != false }
                    let others = models.filter { $0.supports(capability) == false }
                    if !suited.isEmpty { Divider() }
                    ForEach(suited) { model in Button(label(model)) { selection = model.name } }
                    if !others.isEmpty {
                        Menu("Other models") {
                            ForEach(others) { model in Button(label(model)) { selection = model.name } }
                        }
                    }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(models.isEmpty)
                .help(models.isEmpty ? "No models discovered — type a model ID" : "Choose a discovered model")
            }
            if let model = models.first(where: { $0.name == selection }), model.supports(capability) == false {
                Text("\(selection) doesn't report \(capability.rawValue) support.").font(.caption).foregroundStyle(.orange)
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func label(_ model: AIModel) -> String {
        var text = model.displayName.map { "\($0) — \(model.name)" } ?? model.name
        if let detail = model.detail { text += " (\(detail))" }
        return text
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
                LabeledContent("Notes", value: "\(stats.noteCount)")
                LabeledContent("Note attachments", value: ByteCountFormatter.string(fromByteCount: stats.attachmentBytes, countStyle: .file))
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
            Section("Startup") {
                Toggle("Open Recall at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
            }
            Section {
                LabeledContent("Pause or resume recording", value: GlobalHotKey.displayString)
                LabeledContent("New note", value: GlobalHotKey.newNoteDisplayString)
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                Text("These work from any app.")
            }
            UpdateSettingsSection()
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
                Text("Recall stores everything locally in ~/Library/Application Support/RecallForMac. It has no telemetry, accounts or cloud sync. Network traffic goes only to the AI provider you configure (remote providers require your approval first) and, if update checks are on, to GitHub for the latest release.")
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

/// Settings → Privacy → Screenshot encryption.
private struct ScreenshotEncryptionSection: View {
    @EnvironmentObject private var state: AppState
    @State private var message: String?

    var body: some View {
        Section("Screenshot encryption") {
            LabeledContent("Status") {
                if let problem = state.imageEncryptionProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if state.encryptingImages {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Encrypting existing screenshots…")
                    }
                } else {
                    Label("Encrypted", systemImage: "lock.fill").foregroundStyle(.green)
                }
            }
            HStack {
                Button("Export Recovery Key…") { exportKey() }
                Button("Import Recovery Key…") { importKey() }
                Spacer()
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Screenshots and thumbnails are encrypted with a key kept in your login keychain, so other apps can't read them from disk. If the key is lost (for example, after resetting the keychain or moving to a new Mac without it), your screenshots can't be opened. Export the recovery key and keep it somewhere safe and private; anyone with it and a copy of your library can view your screenshots.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func exportKey() {
        guard let vault = state.store?.vault else { return }
        let text: String
        do {
            text = try vault.exportRecoveryKey()
        } catch {
            message = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Recall Recovery Key.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Anyone with this file and a copy of your Recall library can view your screenshots."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            // Owner read/write only.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            message = "Recovery key saved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func importKey() {
        guard let vault = state.store?.vault else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a Recall recovery key."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try vault.importRecoveryKey(String(contentsOf: url, encoding: .utf8))
            message = added == 0 ? "This Mac already has that key." : "Imported \(added) key\(added == 1 ? "" : "s"). Locked screenshots can be opened again."
            ImageCache.shared.removeAll()
            state.historyChanged()
            state.encryptStoredImages()
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Settings → Privacy → AI agent access (MCP).
private struct MCPAccessSection: View {
    @EnvironmentObject private var state: AppState
    @State private var copied: String?
    @State private var lastAccess = MCPCommand.lastAccess()

    private var executable: String { Bundle.main.executablePath ?? "/Applications/RecallForMac.app/Contents/MacOS/RecallForMac" }
    private var claudeCodeCommand: String { "claude mcp add --scope user recall -- \"\(executable)\" \(MCPCommand.flag)" }
    private var jsonConfig: String {
        """
        {
          "mcpServers": {
            "recall": {
              "command": "\(executable)",
              "args": ["\(MCPCommand.flag)"]
            }
          }
        }
        """
    }

    var body: some View {
        Section("AI agent access (MCP)") {
            Toggle("Allow AI agents to read your history", isOn: $state.settings.mcpEnabled)
            if state.settings.mcpEnabled {
                Toggle(isOn: $state.settings.mcpScreenshotsEnabled) {
                    Text("Allow agents to view screenshots")
                    Text("Agents can fetch a capture's screenshot (decrypted, downscaled). Images can show more than the redacted text, such as photos, other people's messages and anything OCR missed.")
                }
                Toggle(isOn: $state.settings.mcpAttachmentsEnabled) {
                    Text("Allow agents to read note attachments")
                    Text("Agents can fetch files you attached to notes: images, and the text of text, code, CSV, JSON and PDF files. Redaction doesn't apply to attachments; they're shared as you attached them.")
                }
                LabeledContent("Claude Code") {
                    HStack(alignment: .top) {
                        Text(claudeCodeCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copied == "cli" ? "Copied" : "Copy") { copy(claudeCodeCommand, as: "cli") }
                    }
                }
                LabeledContent("Claude Desktop, Cursor and others") {
                    Button(copied == "json" ? "Copied" : "Copy JSON Configuration") { copy(jsonConfig, as: "json") }
                }
                if executable.contains("/DerivedData/") {
                    Label("This is a development build. Point agents at the copy in Applications so the path keeps working.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let lastAccess {
                Text("Last read by \(lastAccess.client) \(lastAccess.date.formatted(.relative(presentation: .named))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Lets MCP clients such as Claude Code, Claude Desktop or Cursor search your history and report on your usage: recognized text, AI descriptions, window titles, sessions, projects, summaries and app time. Access is read-only, and screenshots and note attachments are shared only if you allow them above. Whatever an agent reads goes to its AI model, so it leaves this Mac if the agent uses a cloud model. Turning this off blocks agents immediately.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { lastAccess = MCPCommand.lastAccess() }
    }

    private func copy(_ text: String, as id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = id
    }
}
