import AppKit
import RecallCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var ollamaOK: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundStyle(.tint)
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
            if !state.hasScreenPermission {
                Text("After enabling Recall in System Settings, macOS may ask you to quit and reopen the app.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
            }

            step(title: "Accessibility",
                 detail: "Recommended. Lets Recall identify exactly which window has focus and read its title. Without it, Recall uses the frontmost window of the active app.",
                 granted: state.hasAccessibility,
                 action: ("Grant Access…", { state.requestAccessibility(); openPrivacyPane("Privacy_Accessibility") }))

            step(title: "Ollama (optional)",
                 detail: "Local AI for descriptions, summaries and semantic search. Capture, text recognition, the timeline and keyword search work without it.",
                 granted: ollamaOK ?? false,
                 action: ("Check", { Task { ollamaOK = await state.checkOllama() } }))

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
            ollamaOK = await state.checkOllama()
            // Permissions are granted in System Settings; poll while this window is open.
            while !Task.isCancelled {
                state.refreshPermissions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
