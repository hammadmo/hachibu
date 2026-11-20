import AppKit
import Observation
@preconcurrency import Sparkle

/// Checks for a newer version of Hachibu, and installs it, with Sparkle.
///
/// This is the only thing in Hachibu that uses the network. It reads one
/// feed file (`SUFeedURL` in Info.plist) and, when the person agrees,
/// downloads the new version; each download is checked against the public
/// key in Info.plist before it is installed. Nothing about the Mac is sent.
/// Test runs and command-line runs never check.
@Observable
final class Updates: NSObject {
    static let shared = Updates()

    /// A newer version that a check in the background found and has not
    /// shown yet. The popover offers it, so nothing pops up while the
    /// person is working in another app.
    private(set) var availableVersion: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// False for test runs, command-line runs, and a copy built without a feed.
    static var canUpdate: Bool {
        !Store.isOverridden && !Launch.isOneShot && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    /// The version this copy is.
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    func start() {
        guard Self.canUpdate, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.automaticallyChecksForUpdates = Preferences.shared.checksForUpdates
        controller.startUpdater()
        self.controller = controller
    }

    /// "Check for Updates…": asks now and shows the answer, whatever it is.
    func check() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    func setAutomatic(_ isOn: Bool) {
        controller?.updater.automaticallyChecksForUpdates = isOn
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows what a background check found only when Hachibu is the
    /// app in front. Otherwise the popover says so and waits to be asked.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}
