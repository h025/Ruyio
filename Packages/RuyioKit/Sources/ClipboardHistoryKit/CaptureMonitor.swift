import AppKit
import Foundation
import RuyioPluginSDK

/// One consistent read of the general pasteboard.
public struct CapturedClip: Sendable {
    public var items: [[String: Data]]
    public var sourceApp: String?
    public var sourceBundleID: String?
    public var changeCount: Int
    public var skippedOversize: Bool
}

/// Polls `changeCount` (no reliable system "copy happened" notification exists) and reads a batch only
/// when it changed and the copy is allowed (plan §12.1). Runs on the main run loop of the plugin process.
@MainActor
public final class CaptureMonitor {
    public var onCapture: ((CapturedClip) -> Void)?
    public var onStateChange: ((CaptureState, String?) -> Void)?
    public var ignoredBundleIDs: Set<String> = []

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var baseline = 0
    private var wantsRecording = false
    private var suspended = false
    private(set) public var state: CaptureState = .userPaused
    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Starts with a fresh baseline: content copied while Ruyio was not recording is never back-filled.
    public func start() {
        wantsRecording = true
        installObservers()
        rebaseline()
        evaluate()
    }

    public func pause() {
        wantsRecording = false
        stopTimer()
        setState(.userPaused, nil)
    }

    /// Re-checks system permission and resumes polling when allowed (explicit "Check Again").
    public func recheck() {
        guard wantsRecording else { return }
        rebaseline()
        evaluate()
    }

    public func stop() {
        stopTimer()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
    }

    /// Records Ruyio's own write so it is ignored even if the marker type is stripped by the system.
    public func noteOwnWrite(changeCount: Int) {
        if changeCount >= baseline { baseline = changeCount }
    }

    private func evaluate() {
        guard wantsRecording else { setState(.userPaused, nil); return }
        guard !suspended else { stopTimer(); setState(.suspended, nil); return }
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .alwaysDeny:
                stopTimer(); setState(.blockedBySystem, "deny"); return
            case .ask:
                // Polling reads would prompt on every copy; stay blocked until the user allows access.
                stopTimer(); setState(.blockedBySystem, "ask"); return
            case .default, .alwaysAllow:
                break
            @unknown default:
                stopTimer(); setState(.unknown, nil); return
            }
        }
        startTimer()
        setState(.recording, nil)
    }

    private func rebaseline() { baseline = pasteboard.changeCount }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: CaptureLimits.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func setState(_ newState: CaptureState, _ detail: String?) {
        state = newState
        onStateChange?(newState, detail)
    }

    func poll() {
        let current = pasteboard.changeCount
        guard current != baseline else { return }
        baseline = current
        let allTypes = Set((pasteboard.types ?? []).map(\.rawValue))
        // Sensitive and self-written content is skipped before any payload is read (PRD §8.2).
        if PasteboardRules.isSensitive(types: allTypes) || PasteboardRules.isOwnWrite(types: allTypes) { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let bundleID = frontmost?.bundleIdentifier, ignoredBundleIDs.contains(bundleID) { return }
        if frontmost == nil && !ignoredBundleIDs.isEmpty { return }

        var items: [[String: Data]] = []
        var skipped = false
        var total = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [String: Data] = [:]
            for type in item.types.map(\.rawValue) where PasteboardRules.isPersistable(type) {
                guard let data = item.data(forType: NSPasteboard.PasteboardType(type)) else { continue }
                let limit = PasteboardRules.imageTypes.contains(type) ? CaptureLimits.maxImageBytes : CaptureLimits.maxTextBytes
                if data.count > limit { skipped = true; continue }
                total += data.count
                representations[type] = data
            }
            if total > CaptureLimits.maxRecordBytes { skipped = true; representations = [:] }
            if !representations.isEmpty && !PasteboardRules.isEffectivelyEmpty(representations) { items.append(representations) }
        }
        // A copy that changed while we were reading is incomplete; read it again next tick.
        guard pasteboard.changeCount == current else { baseline = current - 1; return }
        guard !items.isEmpty else { return }
        onCapture?(CapturedClip(items: items, sourceApp: frontmost?.localizedName, sourceBundleID: frontmost?.bundleIdentifier,
                                changeCount: current, skippedOversize: skipped))
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let suspend: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.suspended = true; self?.evaluate() } }
        let resume: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.suspended = false
                self.rebaseline() // never back-fill content copied while asleep or locked
                self.evaluate()
            }
        }
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: suspend))
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: resume))
        observers.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: suspend))
        observers.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: resume))
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: suspend))
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: resume))
    }
}

/// Image helpers that run inside the sandboxed plugin, so the host only ever decodes small PNGs.
public enum ImageThumbnails {
    public static func png(from data: Data, maxPixel: Int) -> (png: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= CaptureLimits.maxImagePixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, width, height)
    }
}
