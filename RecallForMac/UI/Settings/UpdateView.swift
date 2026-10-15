import RecallCore
import SwiftUI

/// The Software Update window.
struct UpdateView: View {
    @ObservedObject private var updates = UpdateController.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app").font(.system(size: 36)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text("You have \(updates.currentVersion).").foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(24)
        .frame(width: 560)
        // Pin the height to the content so the window grows when release notes arrive.
        // A bare minHeight made 200pt the window's minimum and clipped the buttons.
        .frame(minHeight: 200, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        if let r = updates.availableRelease { return "Recall \(r.version) is available" }
        switch updates.phase {
        case .checking: return "Checking for updates…"
        case .upToDate: return "Recall is up to date"
        case .failed: return "Couldn't check for updates"
        default: return "Software Update"
        }
    }

    @ViewBuilder private var content: some View {
        switch updates.phase {
        case .available(let release):
            notes(release)
            if case .ineligible(let reason) = updates.eligibility {
                Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Skip This Version") { updates.skip(release); dismissWindow() }
                Spacer()
                Button("Later") { updates.showUpdateWindow = false; dismissWindow() }
                if case .eligible = updates.eligibility {
                    Button("Install and Relaunch") { updates.install(release) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(release.asset == nil)
                } else {
                    Button("Download…") { updates.openReleasePage(release) }.keyboardShortcut(.defaultAction)
                }
            }
        case .downloading(let release, let fraction):
            notes(release)
            ProgressView(value: fraction) { Text("Downloading…") }
            HStack { Spacer(); Button("Cancel") { updates.cancel() } }
        case .verifying(let release):
            notes(release)
            ProgressView { Text("Verifying the download's checksum and code signature…") }
        case .installing:
            ProgressView { Text("Installing — Recall will relaunch.") }
        case .failed(let message):
            Text(message).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismissWindow() }
                Button("Try Again") { updates.check(userInitiated: true) }.keyboardShortcut(.defaultAction)
            }
        case .checking:
            ProgressView().frame(maxWidth: .infinity)
        case .upToDate, .idle:
            HStack { Spacer(); Button("OK") { dismissWindow() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func notes(_ release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Release notes").font(.headline)
                Spacer()
                Button("View on GitHub") { updates.openReleasePage(release) }.buttonStyle(.link)
            }
            ScrollView {
                MarkdownBlocks(markdown: release.notes.isEmpty ? "_No release notes._" : release.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 260)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Settings → General → Updates.
struct UpdateSettingsSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var updates = UpdateController.shared
    @Environment(\.openWindow) private var openWindow
    @State private var token = Keychain.get(.githubToken) ?? ""
    @State private var tokenSaved = false

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $state.settings.automaticUpdateChecks)
            LabeledContent("Installed version", value: updates.currentVersion)
            HStack {
                Button("Check Now") { updates.check(userInitiated: true); activateApp(); openWindow(id: WindowID.update) }
                    .disabled(updates.isBusy)
                if updates.phase == .checking { ProgressView().controlSize(.small) }
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if case .ineligible(let reason) = updates.eligibility {
                Text(reason + " You can still check and download updates.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                SecureField("GitHub token (private repositories only)", text: $token)
                Button(tokenSaved ? "Saved" : "Save") {
                    Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: .githubToken)
                    tokenSaved = true
                }
                .disabled(tokenSaved)
            }
            .onChange(of: token) { tokenSaved = false }
            Text("Updates come from github.com/\(UpdateController.repository). Checks send only a request for the latest release. Downloads are installed only if they're signed by the same developer as this copy. A token is only needed while the repository is private; use a fine-grained token with read-only Contents access.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: String {
        switch updates.phase {
        case .available(let r): return "Version \(r.version) is available"
        case .failed(let m): return m
        default:
            guard let last = updates.lastChecked else { return "Never checked" }
            return "Last checked \(last.formatted(.relative(presentation: .named)))"
        }
    }
}
