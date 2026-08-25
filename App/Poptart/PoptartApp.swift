import AppKit
import Foundation
import Persistence
import PoptartApplication
import SwiftUI
import SystemIntegration

@main
struct PoptartApp: App {
    @StateObject private var model = PoptartViewModel()

    var body: some Scene {
        MenuBarExtra("Poptart", systemImage: model.menuBarSymbol) {
            PoptartMenu(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Poptart", id: "settings") {
            SettingsView(model: model)
                .frame(minWidth: 640, minHeight: 520)
                .task { await model.startIfPossible() }
        }
        .defaultSize(width: 720, height: 600)
    }
}

@MainActor
private final class PoptartViewModel: ObservableObject {
    enum Status: Equatable {
        case setupRequired
        case permissionRequired(String)
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .setupRequired: "Install the verified Model Pack"
            case .permissionRequired(let permission): "Allow \(permission)"
            case .loading: "Loading local models…"
            case .ready: "Ready — hold Right Option to dictate"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var status: Status = .setupRequired
    @Published private(set) var history: [Persistence.DictationRecord] = []
    @Published var vocabularyText = ""
    @Published private(set) var modelPackPath = ""
    private var runtime: RuntimeAssembly?

    var menuBarSymbol: String {
        status == .ready ? "waveform" : "waveform.badge.exclamationmark"
    }

    func startIfPossible() async {
        guard runtime == nil, status != .loading else { return }
        let support: URL
        let activePack: ActiveApplicationModelPack?
        do {
            support = try supportDirectory()
            activePack = try ApplicationModelPackLocator.activePack(
                in: support.appendingPathComponent("ModelRuntime", isDirectory: true)
            )
        } catch {
            status = .failed("The verified Model Pack registry is unreadable. Use Repair Model Pack.")
            return
        }
        guard let activePack else {
            status = .setupRequired
            return
        }
        modelPackPath = activePack.layout.root.path
        status = .loading
        do {
            let runtime = try await RuntimeAssembly.start(
                modelPack: activePack.layout,
                applicationSupportDirectory: support,
                cleanupTokenCeiling: activePack.cleanupTokenCeiling
            )
            self.runtime = runtime
            status = .ready
            await reloadProtectedData()
        } catch RuntimeAssemblyError.microphonePermissionRequired {
            status = .permissionRequired("Microphone access")
        } catch RuntimeAssemblyError.accessibilityPermissionRequired {
            status = .permissionRequired("Accessibility access")
        } catch RuntimeAssemblyError.shortcutPermissionRequired {
            status = .permissionRequired("Input Monitoring")
        } catch {
            status = .failed("Local model startup failed. Repair or choose the Model Pack again.")
        }
    }

    func requestPermissions() async {
        _ = await RuntimeAssembly.requestMicrophonePermission()
        _ = SystemAccessibilityPermission().request()
        _ = SystemKeyboardMonitoringPermission().request()
        runtime = nil
        await startIfPossible()
    }

    func reloadProtectedData() async {
        guard let runtime else { return }
        history = (try? await runtime.historyStore.records()) ?? []
        vocabularyText = ((try? await runtime.vocabularyStore.terms()) ?? []).joined(separator: "\n")
    }

    func saveVocabulary() async {
        guard let runtime else { return }
        let terms = vocabularyText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try? await runtime.vocabularyStore.replaceTerms(Array(Set(terms)).sorted())
        await reloadProtectedData()
    }

    func clearHistory() async {
        guard let runtime else { return }
        try? await runtime.historyStore.clearHistory()
        await reloadProtectedData()
    }

    func deleteHistoryRecord(_ id: UUID) async {
        guard let runtime else { return }
        try? await runtime.historyStore.delete(id)
        await reloadProtectedData()
    }

    private func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Playground Labs/Poptart", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct PoptartMenu: View {
    @ObservedObject var model: PoptartViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status.label)
        Divider()
        Button("Open Poptart…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        Button("Quit Poptart") { NSApp.terminate(nil) }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: PoptartViewModel

    var body: some View {
        NavigationSplitView {
            List {
                Label("Voice Keyboard", systemImage: "waveform")
                Label("Personal Vocabulary", systemImage: "text.book.closed")
                Label("History", systemImage: "clock")
                Label("Privacy", systemImage: "lock.shield")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Poptart")
                        .font(.largeTitle.bold())
                    Text("A local-first voice keyboard. Hold Right Option, speak, then release.")
                        .foregroundStyle(.secondary)

                    GroupBox("Readiness") {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(model.status.label, systemImage: model.menuBarSymbol)
                            HStack {
                                Button("Allow Required Permissions") {
                                    Task { await model.requestPermissions() }
                                }
                                Button("Refresh Model Pack Status") {
                                    Task { await model.startIfPossible() }
                                }
                            }
                            if !model.modelPackPath.isEmpty {
                                Text(model.modelPackPath)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Personal Vocabulary") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("One exact term per line. Terms stay encrypted on this Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $model.vocabularyText)
                                .font(.body.monospaced())
                                .frame(minHeight: 100)
                                .border(.quaternary)
                            Button("Save Vocabulary") {
                                Task { await model.saveVocabulary() }
                            }
                        }
                    }

                    GroupBox("History — 30 day retention") {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.history.isEmpty {
                                Text("No retained Dictations.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.history.prefix(20)) { record in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.deliveredText.isEmpty ? record.rawTranscript : record.deliveredText)
                                            .lineLimit(2)
                                        Text(record.createdAt.formatted())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        Task { await model.deleteHistoryRecord(record.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                Divider()
                            }
                            Button("Clear History", role: .destructive) {
                                Task { await model.clearHistory() }
                            }
                        }
                    }

                    GroupBox("Privacy") {
                        Text("Audio is processed in memory and never recorded. Dictation, cursor context, vocabulary, and history never leave this Mac. Poptart has no telemetry or account.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(28)
            }
        }
    }
}
