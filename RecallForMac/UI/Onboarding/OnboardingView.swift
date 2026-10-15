import AppKit
import RecallCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var aiOK: Bool?
    @State private var aiChecking = false
    @State private var aiMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading) {
                    Text("Welcome to Recall").font(.title.bold())
                    Text("A private, searchable history of what you worked on — stored only on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            step(title: "Screen Recording",
                 detail: "Required. Recall captures only the focused window every \(Int(state.settings.captureInterval)) seconds — never the whole screen.",
                 granted: state.hasScreenPermission,
                 action: ("Grant Access…", { state.requestScreenPermission(); openPrivacyPane("Privacy_ScreenCapture") }))
            if !state.hasScreenPermission || state.needsRelaunch || !state.hasAccessibility {
                permissionHelp
            }

            step(title: "Accessibility",
                 detail: "Recommended. Lets Recall identify exactly which window has focus and read its title. Without it, Recall uses the frontmost window of the active app.",
                 granted: state.hasAccessibility,
                 action: ("Grant Access…", { state.requestAccessibility(); openPrivacyPane("Privacy_Accessibility") }))

            step(title: "AI provider (optional): \(state.settings.aiProvider.displayName)",
                 detail: "Descriptions, summaries and semantic search, via Ollama or LM Studio on this Mac, or OpenAI / Amazon Bedrock in the cloud (change in Settings → AI). Capture, text recognition, the timeline and keyword search work without it.",
                 granted: aiOK ?? false,
                 action: (aiChecking ? "Checking…" : "Check Again", { Task { await checkAI() } }))
            if let aiMessage {
                Text(aiMessage)
                    .font(.caption)
                    .foregroundStyle(aiOK == true ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
            }

            Divider()
            Text("Password managers are excluded by default, password fields are never captured, and you can pause anytime with \(GlobalHotKey.displayString) or the menu bar icon.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Toggle("Open at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                Spacer()
                Button("Done") {
                    state.settings.onboardingCompleted = true
                    dismissWindow(id: WindowID.onboarding)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .task {
            await checkAI()
            // Permissions are granted in System Settings; poll while this window is open.
            while !Task.isCancelled {
                state.refreshPermissions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func checkAI() async {
        guard !aiChecking else { return }
        aiChecking = true
        defer { aiChecking = false }
        let result = await state.diagnoseAI()
        aiOK = result.ok
        aiMessage = result.message
    }

    @ViewBuilder private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.needsRelaunch {
                Text("Screen Recording is granted, but macOS only applies it after Recall restarts.")
            } else {
                Text("Already switched on in System Settings but still shown as missing? macOS ties permissions to the app's code signature, so an entry from an earlier build doesn't cover this one. Select Recall in the list, remove it with −, then grant access again.")
            }
            Button("Relaunch Recall") { state.relaunch() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 34)
    }

    private func step(title: String, detail: String, granted: Bool, action: (String, () -> Void)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { Button(action.0, action: action.1) }
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
