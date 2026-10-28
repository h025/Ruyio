import AppKit
import RuyioCore
import RuyioHostKit

/// Runs one interactive capture through the bundled helper (`Contents/Helpers`). LaunchServices makes the
/// helper its own responsible process, so Screen Recording is granted to it alone; the host, which spawns
/// plugins, never holds it (PRD §3.5, decision A35).
@MainActor
final class CaptureService {
    static let shared = CaptureService()
    /// Below the 120 s side-effect action timeout, so a slow selection fails here first.
    static let selectionTimeout: TimeInterval = 110
    private static let promptedKey = "capture.screenRecordingPrompted"

    private var running = false

    private struct HelperResult: Decodable {
        var status: String
        var pixelWidth: Int?
        var pixelHeight: Int?
        var scale: Double?
    }

    func capture(model: AppModel?) async throws -> CapturedScreen {
        guard !running else { throw RuyioError(.actionFailed, retryable: true, diagnostic: "a capture is already running") }
        running = true
        defer { running = false }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuyioCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RuyioCaptureHelper.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--output", directory.path]
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
        } catch {
            throw RuyioError(.actionFailed, diagnostic: "capture helper did not start: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(Self.selectionTimeout)
        while !app.isTerminated {
            if Date() > deadline {
                app.forceTerminate()
                throw RuyioError(.cancelled, diagnostic: "selection timed out")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard let data = try? Data(contentsOf: directory.appendingPathComponent("result.json")),
              let result = try? JSONDecoder().decode(HelperResult.self, from: data) else {
            throw RuyioError(.actionFailed, diagnostic: "capture helper produced no result")
        }
        switch result.status {
        case "captured":
            guard let png = try? Data(contentsOf: directory.appendingPathComponent("capture.png")),
                  let width = result.pixelWidth, let height = result.pixelHeight else {
                throw RuyioError(.actionFailed, diagnostic: "capture file missing")
            }
            return CapturedScreen(png: png, pixelWidth: width, pixelHeight: height, scale: result.scale ?? 1)
        case "permissionRequired":
            explainScreenRecording(model: model)
            throw RuyioError(.cancelled, diagnostic: "screen recording not granted to the capture helper")
        case "cancelled":
            throw RuyioError(.cancelled)
        default:
            throw RuyioError(.actionFailed, diagnostic: "capture failed")
        }
    }

    /// The first time, the system's own prompt for the helper is enough; afterwards it no longer appears,
    /// so explain where to turn it on.
    private func explainScreenRecording(model: AppModel?) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.promptedKey) else {
            defaults.set(true, forKey: Self.promptedKey)
            return
        }
        let l = model?.l ?? L10n(Locale.preferredLanguages.first ?? "en")
        let alert = NSAlert()
        alert.messageText = l.screenRecordingTitle
        alert.informativeText = l.screenRecordingMessage
        alert.addButton(withTitle: l.openSystemSettings)
        alert.addButton(withTitle: l.cancel)
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { SystemSettings.openScreenRecording() }
    }
}
