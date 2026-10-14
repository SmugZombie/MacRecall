import AppKit
import RecallCore
import SwiftUI

@main
struct RecallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            MenuBarLabel().environmentObject(state)
        }
        .menuBarExtraStyle(.window)

        Window("Recall", id: WindowID.main) {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateController.shared.check(userInitiated: true)
                    UpdateController.shared.showUpdateWindow = true
                }
                // ⌃⌥⌘P is registered globally (GlobalHotKey), so it isn't bound here as well.
                Button(state.recordingState == .recording ? "Pause Recording" : "Resume Recording") { state.toggleRecording() }
            }
        }

        Window("Software Update", id: WindowID.update) {
            UpdateView()
        }
        .windowResizability(.contentSize)

        Window("Welcome to Recall", id: WindowID.onboarding) {
            OnboardingView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

/// The status item icon. It renders at launch, which makes it the place to open
/// onboarding for a dockless app that otherwise shows no window on first run.
private struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var updates = UpdateController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: state.recordingState.symbol)
            .accessibilityLabel(state.recordingState.label)
            .task {
                if !state.settings.onboardingCompleted || !state.hasScreenPermission {
                    activateApp()
                    openWindow(id: WindowID.onboarding)
                }
            }
            // The update controller asks for its window from the background; this view is always alive.
            .onChange(of: updates.showUpdateWindow) {
                if updates.showUpdateWindow {
                    activateApp()
                    openWindow(id: WindowID.update)
                    updates.showUpdateWindow = false
                }
            }
    }
}

enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
    static let update = "update"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.start()
            UpdateController.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.shutdown() }
    }

    /// Closing the last window keeps the menu bar app (and recording) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Brings the (dockless) app forward before showing a window.
@MainActor
func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
}
