import Foundation
import Sparkle
import Testing
@testable import Poptart

@Suite("Explicit application updates")
@MainActor
struct ApplicationUpdateTests {
    @Test("unconfigured builds do not create an update session")
    func missingReleaseConfiguration() {
        #expect(ApplicationUpdater().check() == "Application updates are not configured in this build.")
    }

    @Test("the delegate refuses background and informational network checks")
    func backgroundChecksAreRejected() throws {
        let policy = ApplicationUpdater()
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: policy, userDriverDelegate: nil)
        try policy.updater(controller.updater, mayPerform: .updates)
        #expect(throws: NSError.self) {
            try policy.updater(controller.updater, mayPerform: .updatesInBackground)
        }
        #expect(throws: NSError.self) {
            try policy.updater(controller.updater, mayPerform: .updateInformation)
        }
        #expect(!policy.updaterShouldPromptForPermissionToCheck(forUpdates: controller.updater))
        #expect(policy.allowedSystemProfileKeys(for: controller.updater) == [])
    }
}
