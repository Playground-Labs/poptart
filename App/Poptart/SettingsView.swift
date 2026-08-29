import PoptartApplication
import SwiftUI
import SystemIntegration

/// A thin projection of ``SettingsModel``.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    let launch: ApplicationLaunchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(launch.status.message, systemImage: "waveform")
                    .font(.headline)

                dictationSection
                modelPackSection
                vocabularySection
                historySection
                permissionsSection
                aboutSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .task { await model.refreshMicrophones() }
    }

    private var dictationSection: some View {
        GroupBox("Dictation") {
            VStack(alignment: .leading, spacing: 12) {
                Picker(
                    "Microphone",
                    selection: Binding(
                        get: { model.selectedMicrophoneIdentifier ?? "" },
                        set: { identifier in
                            guard !identifier.isEmpty else { return }
                            Task { await model.selectMicrophone(identifier) }
                        }
                    )
                ) {
                    if model.selectedMicrophoneIdentifier == nil {
                        Text("System input device").tag("")
                    }
                    ForEach(model.microphones) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                if let message = model.microphoneMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }

                Picker(
                    "Dictation shortcut",
                    selection: Binding(
                        get: { model.shortcut.binding },
                        set: { binding in Task { await model.shortcut.select(binding) } }
                    )
                ) {
                    ForEach(ShortcutBinding.allCases, id: \.self) { binding in
                        Text(binding.displayName).tag(binding)
                    }
                }
                if let message = model.shortcut.deferredMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }

                Toggle(
                    "Launch Poptart at login",
                    isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { enabled in Task { await model.setLaunchesAtLogin(enabled) } }
                    )
                )
                if let message = model.launchAtLoginMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelPackSection: some View {
        GroupBox("Model Pack") {
            VStack(alignment: .leading, spacing: 10) {
                if let pack = model.modelPack {
                    Text("Version \(pack.version)")
                    Text("\(pack.storageDescription) on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(pack.cleanupDescription)
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(pack.licenses) { license in
                        Link("\(license.role): \(license.name)", destination: license.url)
                            .font(.caption)
                    }
                } else {
                    Text("No verified Model Pack is active.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check for Updates") { Task { await model.checkForModelPackUpdate() } }
                    Button("Update Model Pack") { Task { await model.updateModelPack() } }
                        .disabled(model.availableModelPack == nil)
                    Button("Repair Model Pack") { Task { await model.repairModelPack() } }
                }
                .disabled(model.modelPackActivity.isWorking)
                if let status = model.modelPackActivity.statusText {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var vocabularySection: some View {
        GroupBox("Personal Vocabulary") {
            VStack(alignment: .leading, spacing: 8) {
                Text("One name, acronym, or term per line. Terms stay encrypted on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.vocabularyDraft)
                    .font(.body.monospaced())
                    .frame(minHeight: 110)
                    .border(.quaternary)
                HStack {
                    Button("Save Vocabulary") { Task { await model.saveVocabulary() } }
                    Button("Revert") { Task { await model.loadVocabulary() } }
                }
                if let message = model.vocabularyMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historySection: some View {
        GroupBox("History") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.historyRetentionDescription)
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear History", role: .destructive) {
                    Task { await model.clearHistory() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionsSection: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 8) {
                permissionRow("Microphone", model.permissions.microphone)
                permissionRow("Accessibility", model.permissions.accessibility)
                permissionRow("Input Monitoring", model.permissions.keyboardMonitoring)
                HStack {
                    Button("Request Missing Permissions") {
                        Task { await model.requestMissingPermissions() }
                    }
                    Button("Refresh") { Task { await model.refreshPermissions() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionRow(_ title: String, _ state: PermissionState) -> some View {
        Label(
            "\(title): \(state.rawValue)",
            systemImage: state.isGranted ? "checkmark.circle" : "exclamationmark.circle"
        )
    }

    private var aboutSection: some View {
        GroupBox("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Poptart \(model.applicationVersion)")
                Link("Source code", destination: model.sourceURL)
                Button("Check for Poptart Updates") { model.checkForApplicationUpdate() }
                if let message = model.applicationUpdateMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text(
                    """
                    Poptart makes no background network requests. Downloads, repairs, and update \
                    checks happen only when you start them.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
