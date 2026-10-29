import AppKit
import CryptoKit
import RuyioCore
import RuyioHostKit
import RuyioUI

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
    /// The latest capture's screen frame, matched to a pin request by the image's digest.
    private var recent: (digest: String, frame: CGRect, at: Date)?

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
        // Where the selection began and ended: the system capture reports only the image, and a pin goes
        // back over the region it came from.
        var start: CGPoint?
        var end: CGPoint?
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown { if start == nil { start = point } } else { end = point }
            }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
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
            let scale = result.scale ?? 1
            let size = CGSize(width: Double(width) / scale, height: Double(height) / scale)
            if let frame = CapturePlacement.frame(start: start, end: end, size: size, windows: Self.windowFrames()) {
                recent = (Self.digest(png), frame, Date())
            } else {
                recent = nil
            }
            return CapturedScreen(png: png, pixelWidth: width, pixelHeight: height, scale: scale)
        case "permissionRequired":
            explainScreenRecording(model: model)
            throw RuyioError(.cancelled, diagnostic: "screen recording not granted to the capture helper")
        case "cancelled":
            throw RuyioError(.cancelled)
        default:
            throw RuyioError(.actionFailed, diagnostic: "capture failed")
        }
    }

    /// Where a pin of `png` should appear: over the region of the capture it came from, if that capture was
    /// the latest and recent. Pins from older captures (from a history) are placed at the pointer instead.
    func placement(for png: Data) -> CGRect? {
        guard let recent, Date().timeIntervalSince(recent.at) < 600, recent.digest == Self.digest(png) else { return nil }
        return recent.frame
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Normal on-screen windows, front to back, in AppKit coordinates. Bounds need no Screen Recording.
    private static func windowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame.height else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return CapturePlacement.appKitRect(fromWindowBounds: rect, primaryScreenHeight: primary)
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
