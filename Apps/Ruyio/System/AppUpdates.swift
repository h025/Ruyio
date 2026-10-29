import AppKit
import RuyioCore
import RuyioHostKit

extension AppUpdateService.Configuration {
    /// Release builds only (A41): Scripts/release.sh sets the feed and the EdDSA key, and signs the app with
    /// the release certificate. A local build is ad-hoc or lacks the keys, so it never updates itself.
    static func mainBundle() -> Self? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https",
              let key = (info["SUPublicEDKey"] as? String).flatMap({ Data(base64Encoded: $0) }), key.count == 32,
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init),
              let requirement = CodeSigning.designatedRequirementOfSelf() else { return nil }
        return Self(feedURL: feed, publicKey: key, currentVersion: version, installedApp: Bundle.main.bundleURL, designatedRequirement: requirement)
    }
}

/// Ruyio's own update state, shown in General settings and the menu bar menu.
enum AppUpdatePhase: Equatable {
    case idle, checking, upToDate
    case available(AppcastItem)
    case downloading(Double?)
    case failed(String)

    var available: AppcastItem? {
        if case .available(let item) = self { return item }
        return nil
    }
}

extension AppModel {
    static let downloadPage = URL(string: "https://github.com/h025/Ruyio/releases/latest")!

    /// Background checks report through `appUpdateFound`; this one also reports "up to date" and errors.
    func checkForAppUpdate() {
        guard let appUpdates, appUpdatePhase != .checking else { return }
        if case .downloading = appUpdatePhase { return }
        appUpdatePhase = .checking
        Task {
            do {
                appUpdatePhase = try await appUpdates.check().map(AppUpdatePhase.available) ?? .upToDate
            } catch let error as RuyioError {
                appUpdatePhase = .failed(l.checkFailed + l.errorText(error))
            } catch {
                appUpdatePhase = .failed(l.checkFailed + error.localizedDescription)
            }
        }
    }

    func appUpdateFound(_ item: AppcastItem?) {
        switch appUpdatePhase {
        case .checking, .downloading: return
        default: appUpdatePhase = item.map(AppUpdatePhase.available) ?? .upToDate
        }
    }

    /// Downloads and verifies first; Ruyio quits only after the user confirms the verified update.
    func installAppUpdate(_ item: AppcastItem) {
        guard let appUpdates else { return }
        if case .downloading = appUpdatePhase { return }
        if let problem = appUpdates.installProblem {
            let alert = NSAlert()
            alert.messageText = l.installUpdateTitle(item.version.description)
            alert.informativeText = l.installProblem(problem)
            alert.addButton(withTitle: l.openDownloadPage)
            alert.addButton(withTitle: l.cancel)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.downloadPage) }
            return
        }
        appUpdatePhase = .downloading(nil)
        Task {
            let staged: URL
            do {
                staged = try await appUpdates.prepare(item) { done, total in
                    Task { @MainActor in
                        guard case .downloading = self.appUpdatePhase else { return }
                        self.appUpdatePhase = .downloading(total.map { Double(done) / Double(max($0, 1)) })
                    }
                }
            } catch {
                appUpdatePhase = .failed(l.updateFailed + ((error as? RuyioError).map(l.errorText) ?? error.localizedDescription))
                return
            }
            let alert = NSAlert()
            alert.messageText = l.installUpdateTitle(item.version.description)
            alert.informativeText = l.installUpdateBody
            alert.addButton(withTitle: l.installAndRelaunch)
            alert.addButton(withTitle: l.cancel)
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                try? FileManager.default.removeItem(at: AppUpdateService.workFolder(of: staged))
                appUpdatePhase = .available(item)
                return
            }
            do {
                let previous = try await appUpdates.install(staged: staged)
                do {
                    try appUpdates.relaunch(after: getpid(), removing: [previous, AppUpdateService.workFolder(of: staged)])
                } catch {
                    show(l.relaunchManually)
                }
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: AppUpdateService.workFolder(of: staged))
                appUpdatePhase = .failed(l.updateFailed + ((error as? RuyioError).map(l.errorText) ?? error.localizedDescription))
            }
        }
    }
}
