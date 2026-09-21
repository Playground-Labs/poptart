import PoptartApplication
import SwiftUI
import SystemIntegration

/// A thin projection of ``OnboardingModel``. Every decision about which step comes next, what
/// blocks completion, and when the shortcut may be rebound belongs to the model.
///
/// One step is visible at a time: a progress strip above, the step's own body, and a footer whose
/// single Continue button asks the model what it should do — `acknowledgeExplanation()` on the
/// first step, `confirmFirstDictation()` on the last, and a move forward everywhere else. The line
/// beside Continue is ``OnboardingModel/continueBlocker``, the first of the model's blockers that
/// still applies.
struct OnboardingView: View {
    let environment: AppEnvironment
    @State private var firstDictationText = ""
    @FocusState private var firstDictationFieldFocused: Bool

    private var model: OnboardingModel { environment.onboarding }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressStrip
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.step.title)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.2)
                    stepDetail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            footer
        }
        .frame(minHeight: 520, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refresh() }
    }

    // MARK: Progress

    private var progressStrip: some View {
        let steps = OnboardingStep.allCases
        let position = steps.firstIndex(of: model.step) ?? steps.startIndex
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColour(at: index, current: position))
                        .frame(height: 3)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { model.visit(step) }
                        .accessibilityLabel(step.title)
                        .accessibilityAddTraits(model.canVisit(step) ? .isButton : [])
                }
            }
            SectionLabel("Step \(position + 1) of \(steps.count)")
        }
    }

    /// Steps already behind carry full ink, the one being worked on is half-lit, and the ones still
    /// ahead are only a hairline.
    private func barColour(at index: Int, current: Int) -> Color {
        if index < current { return .primary }
        if index == current { return .primary.opacity(0.45) }
        return Color(nsColor: .separatorColor)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepDetail: some View {
        switch model.step {
        case .explanation:
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    """
                    Poptart is a voice keyboard. Hold one key, speak, and release: the text appears \
                    where your cursor already is.
                    """
                )
                Text(
                    """
                    Recognition and Cleanup run on this Mac. Your audio is never written to disk, \
                    your Dictations and Personal Vocabulary are encrypted here, and Poptart sends \
                    nothing anywhere unless you start a model download, repair, or update yourself.
                    """
                )
                .foregroundStyle(.secondary)
            }

        case .microphonePermission:
            VStack(alignment: .leading, spacing: 16) {
                permissionStep(
                    explanation: "Poptart needs the microphone to hear a Dictation.",
                    state: model.requirements.permissions.microphone,
                    actionTitle: "Allow Microphone",
                    action: {
                        await model.requestMicrophonePermission()
                        await environment.refreshAfterExternalChange()
                    }
                )
                SectionDivider()
                LabeledRow(label: "Microphone") {
                    MicrophoneInputPicker(model: environment.settings)
                }
            }

        case .accessibilityPermission:
            permissionStep(
                explanation:
                    "Accessibility lets Poptart find your cursor and place text where you are typing.",
                state: model.requirements.permissions.accessibility,
                actionTitle: "Allow Accessibility",
                action: {
                    await model.requestAccessibilityPermission()
                    await environment.refreshAfterExternalChange()
                }
            )

        case .modelPack:
            modelPackStep

        case .offlineReadiness:
            VStack(alignment: .leading, spacing: 14) {
                Text("Confirm Poptart can dictate with the network switched off.")
                    .foregroundStyle(.secondary)
                Button("Run the readiness check") {
                    Task { await model.runOfflineReadinessCheck() }
                }
                .buttonStyle(.filled)
                if let report = model.readinessReport {
                    Label(
                        report.failureDescription
                            ?? "Poptart can turn speech into text with the network switched off.",
                        systemImage: report.isReady
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                }
            }

        case .shortcutTest:
            shortcutStep

        case .firstDictation:
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    """
                    Start the test, then hold \(model.shortcut.binding.displayName), say a sentence, \
                    and release. Your Dictation will appear here.
                    """
                )
                .foregroundStyle(.secondary)
                TextField("First Dictation test field", text: $firstDictationText)
                    .textFieldStyle(.roundedBorder)
                    .focused($firstDictationFieldFocused)
                HStack(spacing: 8) {
                    Button("Start the test") {
                        model.beginFirstDictationTest()
                        firstDictationFieldFocused = true
                    }
                    .buttonStyle(.filled)
                    Button("I dictated something") {
                        Task { await model.confirmFirstDictation() }
                    }
                    .buttonStyle(.outlined)
                }
                if let message = model.firstDictationMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func permissionStep(
        explanation: String,
        state: PermissionState,
        actionTitle: String,
        action: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(explanation).foregroundStyle(.secondary)
            Label(
                state.isGranted ? "Granted" : "Not granted",
                systemImage: state.isGranted ? "checkmark.circle.fill" : "circle"
            )
            HStack(spacing: 8) {
                Button(actionTitle) { Task { await action() } }
                    .buttonStyle(.filled)
                Button("Check again") { Task { await model.refresh() } }
                    .buttonStyle(.outlined)
            }
        }
    }

    // MARK: Model Pack

    private var modelPackStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                """
                One verified pack holds both models. Nothing downloads until you choose it, and \
                nothing leaves this Mac afterwards.
                """
            )
            .foregroundStyle(.secondary)

            if let offer = model.installState.offer {
                modelPackTable(offer)
            }

            HStack(spacing: 8) {
                if let offer = model.installState.offer {
                    Button("Download Model Pack (\(ByteSize.description(offer.downloadBytes)))") {
                        Task {
                            await model.installModelPack()
                            await environment.refreshAfterExternalChange()
                        }
                    }
                    .buttonStyle(.filled)
                } else {
                    Button("Show what will download") { Task { await model.describeModelPack() } }
                        .buttonStyle(.filled)
                }
            }
            .disabled(model.installState.isWorking)

            if case .installing = model.installState {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.primary)
            }
            if let status = model.installState.statusText {
                Text(status).foregroundStyle(.secondary)
            }
        }
    }

    /// What the signed manifest says will arrive: one row per license, then the total to download.
    private func modelPackTable(_ offer: ModelPackOffer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(offer.licenses) { license in
                LabeledRow(label: license.role.capitalized) {
                    Link(destination: license.url) { Text(license.name).underline() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 7)
                SectionDivider()
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Total").frame(width: Theme.labelWidth, alignment: .leading)
                Text("Version \(offer.version) · checksummed and signed by Playground Labs")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ByteSize.description(offer.downloadBytes))
                    .fontWeight(.semibold)
            }
            .padding(.vertical, 7)
        }
    }

    // MARK: Shortcut test

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hold the key for a moment, then release it. Poptart records while it is held.")
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                keycap
                if let message = model.shortcutTestMessage ?? model.shortcut.deferredMessage {
                    if model.progress.shortcutTestPassed {
                        Label(message, systemImage: "checkmark.circle.fill")
                    } else {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            LabeledRow(label: "Use a different key") {
                Picker(
                    "Dictation shortcut",
                    selection: Binding(
                        get: { model.shortcut.binding },
                        set: { binding in Task { await model.selectShortcut(binding) } }
                    )
                ) {
                    ForEach(ShortcutBinding.allCases, id: \.self) { binding in
                        Text(binding.displayName).tag(binding)
                    }
                }
                .labelsHidden()
                .frame(width: Theme.controlWidth)
            }

            if !model.requirements.permissions.keyboardMonitoring.isGranted {
                inputMonitoringNotice
            }
        }
    }

    /// The chosen key drawn as the key itself, so the thing to hold is recognisable on the keyboard
    /// rather than only named.
    private var keycap: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .textBackgroundColor))
            .frame(width: 168, height: 64)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary).frame(height: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                VStack(spacing: 4) {
                    Text(keySymbol).font(.system(size: 20, weight: .semibold))
                    Text(model.shortcut.binding.displayName.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.66)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(.primary, lineWidth: 1)
            }
    }

    /// Apple's glyph for the held modifier. The binding's key is private, so the identifier it
    /// persists under names the key instead.
    private var keySymbol: String {
        let identifier = model.shortcut.binding.identifier
        if identifier.hasSuffix("Option") { return "⌥" }
        if identifier.hasSuffix("Command") { return "⌘" }
        if identifier.hasSuffix("Control") { return "⌃" }
        return "⇧"
    }

    private var inputMonitoringNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text("Input Monitoring lets Poptart see the shortcut in any app.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Allow Input Monitoring") {
                Task {
                    await model.requestKeyboardMonitoringPermission()
                    await environment.refreshAfterExternalChange()
                }
            }
            .buttonStyle(.filled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .overlay {
            RoundedRectangle(cornerRadius: 9).stroke(.primary, lineWidth: 1)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            SectionDivider()
            HStack(spacing: 12) {
                Button("Back") { model.goBack() }
                    .buttonStyle(.outlined)
                    .disabled(!model.canGoBack)
                Spacer(minLength: 12)
                if let blocker = model.continueBlocker {
                    Text(blocker)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Continue") { Task { await model.continueOnboarding() } }
                    .buttonStyle(.filled)
                    .disabled(!model.canContinue)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }
}
