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
    case downloading(AppcastItem, Double?)
    /// Downloaded and verified; installing quits and relaunches Ruyio, so it waits for the user.
    case ready(AppcastItem, staged: URL)
    case failed(String)

    var item: AppcastItem? {
        switch self {
        case .available(let item), .downloading(let item, _), .ready(let item, _): return item
        default: return nil
        }
    }

    /// What the menu bar menu shows; progress ticks do not change it.
    var menuKey: String {
        switch self {
        case .available(let item): return "available " + item.version.description
        case .downloading(let item, _): return "downloading " + item.version.description
        case .ready(let item, _): return "ready " + item.version.description
        default: return "check"
        }
    }
}

extension AppModel {
    static let downloadPage = URL(string: "https://github.com/h025/Ruyio/releases/latest")!

    /// Background checks report through `appUpdateFound`; this one also reports "up to date" and errors.
    func checkForAppUpdate() {
        guard let appUpdates else { return }
        switch appUpdatePhase {
        case .checking, .downloading, .ready: return
        default: break
        }
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
        case .checking, .downloading, .ready: return
        default: appUpdatePhase = item.map(AppUpdatePhase.available) ?? .upToDate
        }
    }

    /// Downloads and verifies the update, then waits in `.ready`. No modal dialog: one shown from a task
    /// would hold the main actor, and with it Finder requests and the menus, until it is answered.
    func downloadAppUpdate(_ item: AppcastItem) {
        guard let appUpdates else { return }
        switch appUpdatePhase {
        case .downloading, .ready: return
        default: break
        }
        if let problem = appUpdates.installProblem {
            let alert = NSAlert()
            alert.messageText = l.installUpdateTitle(item.version.description)
            alert.informativeText = l.installProblem(problem)
            alert.addButton(withTitle: l.openDownloadPage)
            alert.addButton(withTitle: l.cancel)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.downloadPage) }
            return
        }
        appUpdatePhase = .downloading(item, nil)
        Task {
            do {
                let staged = try await appUpdates.prepare(item) { done, total in
                    Task { @MainActor in
                        guard case .downloading(let current, _) = self.appUpdatePhase, current == item else { return }
                        self.appUpdatePhase = .downloading(item, total.map { Double(done) / Double(max($0, 1)) })
                    }
                }
                appUpdatePhase = .ready(item, staged: staged)
                show(l.updateReady(item.version.description))
            } catch {
                appUpdatePhase = .failed(l.updateFailed + ((error as? RuyioError).map(l.errorText) ?? error.localizedDescription))
            }
        }
    }

    /// The user chose "Install and Relaunch": swap in the verified update, then quit for the relauncher.
    func installAppUpdate() {
        guard let appUpdates, case .ready(let item, let staged) = appUpdatePhase else { return }
        appUpdatePhase = .downloading(item, 1)
        Task {
            let previous: URL
            do {
                previous = try await appUpdates.install(staged: staged, item: item)
            } catch {
                try? FileManager.default.removeItem(at: AppUpdateService.workFolder(of: staged))
                appUpdatePhase = .failed(l.updateFailed + ((error as? RuyioError).map(l.errorText) ?? error.localizedDescription))
                return
            }
            do {
                try appUpdates.relaunch(after: getpid(), removing: [previous, AppUpdateService.workFolder(of: staged)])
            } catch {
                // The new version is in place but nothing will open it: say so and keep running.
                appUpdatePhase = .failed(l.relaunchManually)
                return
            }
            NSApp.terminate(nil)
        }
    }
}
