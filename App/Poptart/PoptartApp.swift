import AppKit
import Foundation
import Observation
import PoptartApplication
import SwiftUI

@main
struct PoptartApp: App {
    @State private var root = AppRoot()

    var body: some Scene {
        MenuBarExtra("Poptart", systemImage: root.menuBarSymbol) {
            PoptartMenu(root: root)
        }
        .menuBarExtraStyle(.menu)

        Window("Poptart", id: "poptart") {
            RootView(root: root)
                .frame(minWidth: 720, minHeight: 560)
                .task { await root.start() }
        }
        .defaultSize(width: 860, height: 660)
    }
}

/// Holds whatever the application managed to build. A Mac that will not give Poptart its support
/// directory or Keychain key still gets an explanation instead of a blank window.
@MainActor
@Observable
final class AppRoot {
    private(set) var environment: AppEnvironment?
    private(set) var failure: String?
    private var started = false

    var menuBarSymbol: String {
        environment?.launch.status.isReady == true ? "waveform" : "waveform.badge.exclamationmark"
    }

    var statusMessage: String {
        if let failure { return failure }
        guard let environment else { return "Starting Poptart…" }
        if !environment.onboarding.isComplete { return "Finish setting Poptart up." }
        return environment.launch.status.message
    }

    /// Releases the event tap and deadlines before the process goes away.
    func stop() async {
        await environment?.stop()
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            let environment = try AppEnvironment.make(downloader: .system)
            self.environment = environment
            await environment.start()
        } catch {
            failure = "Poptart could not open its local storage on this Mac."
        }
    }
}

private struct PoptartMenu: View {
    let root: AppRoot
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(root.statusMessage)
        Divider()
        Button("Open Poptart…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "poptart")
        }
        Button("Quit Poptart") {
            Task {
                await root.stop()
                NSApp.terminate(nil)
            }
        }
    }
}

private struct RootView: View {
    let root: AppRoot

    var body: some View {
        if let failure = root.failure {
            ContentUnavailableView(
                "Poptart cannot start",
                systemImage: "exclamationmark.triangle",
                description: Text(failure)
            )
        } else if let environment = root.environment {
            if environment.onboarding.isComplete {
                MainWindow(environment: environment)
            } else {
                OnboardingView(environment: environment)
            }
        } else {
            ProgressView("Starting Poptart…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MainWindow: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            SettingsView(model: environment.settings, launch: environment.launch)
                .tabItem { Label("Settings", systemImage: "gearshape") }
            HistoryView(model: environment.history)
                .tabItem { Label("History", systemImage: "clock") }
        }
        .padding(16)
    }
}
