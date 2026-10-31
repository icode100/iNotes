#if os(macOS)
import AppKit
import Combine
import Sparkle

/// The native updater stays dormant in local builds without a signed release feed.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    let isConfigured: Bool
    let configurationMessage: String
    /// Must flush notes successfully before an update is allowed to restart iNotes.
    var prepareForInstallation: (() -> Bool)?

    private var controller: SPUStandardUpdaterController?
    private var checkObservation: AnyCancellable?
    private var pendingInstallation: (() -> Void)?
    private var updaterCanCheck = false

    override init() {
        let configuration = Self.configuration(in: Bundle.main.infoDictionary ?? [:])
        isConfigured = configuration.valid
        configurationMessage = configuration.message
        super.init()
        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        checkObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                self?.updaterCanCheck = value
                self?.refreshAvailability()
            }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard isConfigured, let controller else {
            showAlert(title: "Updates are not connected yet", message: configurationMessage)
            return
        }
        if let install = pendingInstallation {
            guard prepareForInstallation?() == true else { showSaveFailure(); return }
            pendingInstallation = nil
            refreshAvailability()
            install()
        } else if controller.updater.canCheckForUpdates {
            controller.checkForUpdates(nil)
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard prepareForInstallation?() == true else {
            pendingInstallation = installHandler
            refreshAvailability()
            showSaveFailure()
            return true
        }
        return false
    }

    private func refreshAvailability() {
        canCheckForUpdates = pendingInstallation != nil || updaterCanCheck
    }

    private func showSaveFailure() {
        showAlert(title: "Save your notes before updating",
                  message: "iNotes could not save your latest changes. The update is waiting. Save your notes or export a backup, then choose Check for Updates again.")
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func configuration(in info: [String: Any]) -> (valid: Bool, message: String) {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URLComponents(string: feed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || (1...65535).contains(url.port!),
              let publicKey = info["SUPublicEDKey"] as? String,
              let key = Data(base64Encoded: publicKey), key.count == 32,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              let signatureExpiry = info["SUSignedFeedFailureExpirationInterval"] as? NSNumber,
              signatureExpiry.doubleValue == 0 else {
            return (false, "This copy of iNotes does not have a verified release channel yet. Keep using it normally; a release with secure automatic updates will be available when the project's release channel is ready.")
        }
        return (true, "iNotes checks for signed updates automatically. Downloads are verified before installation, and your notes are saved before restarting.")
    }
}
#endif
