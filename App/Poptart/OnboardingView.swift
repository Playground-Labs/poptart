import PoptartApplication
import SwiftUI
import SystemIntegration

/// A thin projection of ``OnboardingModel``. Every decision about which step comes next, what
/// blocks completion, and when the shortcut may be rebound belongs to the model.
struct OnboardingView: View {
    let environment: AppEnvironment

    private var model: OnboardingModel { environment.onboarding }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            stepList
                .frame(width: 220)
                .padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(model.step.title).font(.largeTitle.bold())
                        Spacer()
                        Button("Back") { model.goBack() }
                            .disabled(!model.canGoBack)
                    }
                    stepDetail
                    Divider()
                    remaining
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .task { await model.refresh() }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Button { model.visit(step) } label: {
                    Label(
                        step.title,
                        systemImage: step == model.step ? "circle.inset.filled" : "circle"
                    )
                    .foregroundStyle(step == model.step ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!model.canVisit(step))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var stepDetail: some View {
        switch model.step {
        case .explanation:
            VStack(alignment: .leading, spacing: 12) {
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
                Button("Continue") { Task { await model.acknowledgeExplanation() } }
                    .keyboardShortcut(.defaultAction)
            }

        case .microphonePermission:
            permissionStep(
                explanation: "Poptart needs the microphone to hear a Dictation.",
                state: model.requirements.permissions.microphone,
                actionTitle: "Allow Microphone",
                action: {
                    await model.requestMicrophonePermission()
                    await environment.refreshAfterExternalChange()
                }
            )

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
            VStack(alignment: .leading, spacing: 12) {
                Text("Confirm Poptart can dictate with the network switched off.")
                Button("Run the readiness check") {
                    Task { await model.runOfflineReadinessCheck() }
                }
                if let report = model.readinessReport {
                    Label(
                        report.failureDescription
                            ?? "Poptart can turn speech into text with the network switched off.",
                        systemImage: report.isReady ? "checkmark.circle" : "exclamationmark.circle"
                    )
                }
            }

        case .shortcutTest:
            shortcutStep

        case .firstDictation:
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    """
                    Open any text field, hold \(model.shortcut.binding.displayName), say a sentence, \
                    and release.
                    """
                )
                HStack {
                    Button("Start the test") { model.beginFirstDictationTest() }
                    Button("I dictated something") {
                        Task { await model.confirmFirstDictation() }
                    }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(explanation)
            Label(
                state.isGranted ? "Granted" : "Not granted",
                systemImage: state.isGranted ? "checkmark.circle" : "circle"
            )
            HStack {
                Button(actionTitle) { Task { await action() } }
                    .keyboardShortcut(.defaultAction)
                Button("Check again") { Task { await model.refresh() } }
            }
        }
    }

    private var modelPackStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                """
                Poptart installs one verified Model Pack containing the recognition and Cleanup \
                models. Nothing downloads until you choose it.
                """
            )
            HStack {
                Button("Show what will download") { Task { await model.describeModelPack() } }
                if let offer = model.installState.offer {
                    Button("Download Model Pack (\(ByteSize.description(offer.downloadBytes)))") {
                        Task {
                            await model.installModelPack()
                            await environment.refreshAfterExternalChange()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(model.installState.isWorking)

            if let status = model.installState.statusText {
                Text(status).foregroundStyle(.secondary)
            }
            if let offer = model.installState.offer {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Licenses").font(.headline)
                    ForEach(offer.licenses) { license in
                        Link("\(license.role): \(license.name)", destination: license.url)
                    }
                }
            }
        }
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.requirements.permissions.keyboardMonitoring.isGranted {
                Label(
                    "Input Monitoring is needed before Poptart can see the shortcut.",
                    systemImage: "exclamationmark.circle"
                )
                Button("Allow Input Monitoring") {
                    Task {
                        await model.requestKeyboardMonitoringPermission()
                        await environment.refreshAfterExternalChange()
                    }
                }
            }
            Text("Hold \(model.shortcut.binding.displayName) for a moment, then release it.")
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
            .frame(maxWidth: 320)
            if let message = model.shortcutTestMessage ?? model.shortcut.deferredMessage {
                Text(message).foregroundStyle(.secondary)
            }
        }
    }

    private var remaining: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.blockers.isEmpty {
                Label("Permissions, Model Pack, and the shortcut test all succeeded.",
                      systemImage: "checkmark.seal")
            } else {
                Text("Still needed before Poptart is set up").font(.headline)
                ForEach(model.blockers, id: \.self) { blocker in
                    Label(blocker.description, systemImage: "circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
