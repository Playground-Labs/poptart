import PoptartApplication
import SwiftUI
import SystemIntegration

/// A thin projection of ``SettingsModel``. The window borrows the Indicator's vocabulary: one ink
/// on the window ground, sections laid flat and parted by hairlines, every control on one edge.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    let launch: ApplicationLaunchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                section { dictationSection }
                section { modelPackSection }
                section { vocabularySection }
                section { historySection }
                section { permissionsSection }
                section { aboutSection }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.outlined)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform")
            Text(launch.status.message)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text("Poptart \(model.applicationVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// Every section: a hairline, then its rows on the ground. No box, no fill, no colour.
    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionDivider()
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
        }
    }

    // MARK: Dictation

    @ViewBuilder private var dictationSection: some View {
        SectionLabel("Dictation")

        LabeledRow(label: "Microphone") {
            MicrophoneInputPicker(model: model)
        }

        LabeledRow(label: "Shortcut") {
            VStack(alignment: .leading, spacing: 6) {
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
                .labelsHidden()
                .frame(width: Theme.controlWidth)

                hint("Hold to record, release to insert")
                if let message = model.shortcut.deferredMessage { hint(message) }
            }
        }

        LabeledRow(label: "Open at login") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Open at login",
                    isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { enabled in Task { await model.setLaunchesAtLogin(enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)

                if let message = model.launchAtLoginMessage { hint(message) }
            }
        }
    }

    // MARK: Model Pack

    @ViewBuilder private var modelPackSection: some View {
        HStack(spacing: 8) {
            SectionLabel("Model Pack")
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Check for Updates") { Task { await model.checkForModelPackUpdate() } }
                Button("Update") { Task { await model.updateModelPack() } }
                    .disabled(model.availableModelPack == nil)
                Button("Repair") { Task { await model.repairModelPack() } }
            }
            .disabled(model.modelPackActivity.isWorking)
        }

        LabeledRow(label: "Installed") {
            VStack(alignment: .leading, spacing: 4) {
                if let pack = model.modelPack {
                    Text("Version \(pack.version) · \(pack.storageDescription)")
                        .fixedSize(horizontal: false, vertical: true)
                    hint(pack.cleanupDescription)
                } else {
                    Text("No verified Model Pack is active.")
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let pack = model.modelPack, !pack.licenses.isEmpty {
            LabeledRow(label: "Licenses") {
                HStack(spacing: 12) {
                    ForEach(pack.licenses) { license in
                        Link(destination: license.url) {
                            Text("\(license.role.capitalized): \(license.name)").underline()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                    }
                }
            }
        }

        if let status = model.modelPackActivity.statusText { hint(status) }
    }

    // MARK: Personal Vocabulary

    @ViewBuilder private var vocabularySection: some View {
        HStack(spacing: 8) {
            SectionLabel("Personal Vocabulary")
            Spacer(minLength: 12)
            Button("Save") { Task { await model.saveVocabulary() } }
                .buttonStyle(.filled)
            Button("Revert") { Task { await model.loadVocabulary() } }
        }

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Terms")
                hint("One per line. Encrypted on this Mac.")
            }
            .frame(width: Theme.labelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $model.vocabularyDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 76)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                            .stroke(.primary, lineWidth: 1)
                    )
                if let message = model.vocabularyMessage { hint(message) }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SectionLabel("History")
                .frame(width: Theme.labelWidth, alignment: .leading)
            hint(model.historyRetentionDescription)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Clear History…", role: .destructive) {
                Task { await model.clearHistory() }
            }
        }
    }

    // MARK: Permissions

    @ViewBuilder private var permissionsSection: some View {
        HStack(spacing: 8) {
            SectionLabel("Permissions")
            Spacer(minLength: 12)
            Button("Request Missing") { Task { await model.requestMissingPermissions() } }
            Button("Refresh") { Task { await model.refreshPermissions() } }
        }

        HStack(spacing: 0) {
            permissionItem("Microphone", model.permissions.microphone)
            permissionItem("Accessibility", model.permissions.accessibility)
            permissionItem("Input Monitoring", model.permissions.keyboardMonitoring)
        }
    }

    /// Granted reads as a filled mark, denied as a crossed one, and not yet asked as an empty one:
    /// a silhouette, never a colour. The spoken label carries the state in words.
    private func permissionItem(_ title: String, _ state: PermissionState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: permissionSymbol(state))
            Text(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(state.rawValue)")
    }

    private func permissionSymbol(_ state: PermissionState) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle"
        case .undetermined: "circle"
        }
    }

    // MARK: About

    @ViewBuilder private var aboutSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            hint(
                """
                Poptart makes no background network requests. Downloads, repairs, and update \
                checks happen only when you start them.
                """
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Link(destination: model.sourceURL) {
                Text("Source code").underline()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.primary)

            Button { model.checkForApplicationUpdate() } label: {
                Text("Check for Poptart Updates").underline()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
        }

        if let message = model.applicationUpdateMessage { hint(message) }
    }

    /// The quiet line under a control: what a setting means, or what the Mac just said about it.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MicrophoneInputPicker: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(
                "Microphone input",
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
            .labelsHidden()
            .frame(width: Theme.controlWidth)

            if let message = model.microphoneMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.refreshMicrophones() }
    }
}
