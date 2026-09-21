import Foundation
import Sparkle

/// Sparkle owns verified downloads and installation; only the Settings action starts a check.
@MainActor
final class ApplicationUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?

    func check() -> String {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let url = URL(string: feed), url.scheme == "https", url.host?.isEmpty == false,
            let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            Data(base64Encoded: key)?.count == 32
        else { return "Application updates are not configured in this build." }

        if controller == nil {
            let candidate = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            candidate.updater.clearFeedURLFromUserDefaults()
            do { try candidate.updater.start() }
            catch { return "The update check could not start. Try again later." }
            controller = candidate
        }
        guard let controller, controller.updater.canCheckForUpdates else {
            return "An application update check is already open."
        }
        controller.checkForUpdates(nil)
        return "Checking for Poptart updates."
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates else {
            throw NSError(domain: "Poptart.ApplicationUpdater", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Update checks require an explicit action."])
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}
