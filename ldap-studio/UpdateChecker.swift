//
//  UpdateChecker.swift
//  ldap-studio
//
//  Updates through Sparkle: it reads appcast.xml from the repo's main
//  branch (SUFeedURL in Info.plist), looks once a day and whenever asked,
//  and downloads, verifies and installs the new version itself.
//
//  Two channels: stable releases for everyone, and betas (appcast items on
//  the "beta" channel) for whoever turns on "Check for Beta Versions" — on
//  by default in a beta build.
//

import Foundation
import Sparkle

final class UpdateChecker: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateChecker()
    override private init() {}

    /// Starting it is what schedules the daily check.
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    /// The `@AppStorage` key behind the "Check for Beta Versions" menu item.
    static let includesBetasKey = "updateCheck.includesBetas"

    /// Until the user picks, a beta build follows betas — whoever installed
    /// one asked for them — and a stable build doesn't.
    static var includesBetasByDefault: Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version?.contains("-beta.") ?? false
    }

    static var includesBetas: Bool {
        UserDefaults.standard.object(forKey: includesBetasKey) as? Bool ?? includesBetasByDefault
    }

    func start() {
        _ = controller
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    /// Stable items have no channel, so they're always in; a stable release
    /// outranks the betas that led up to it, so a beta user is offered it.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.includesBetas ? ["beta"] : []
    }
}
