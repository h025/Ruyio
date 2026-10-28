import AppKit
import Carbon

/// Puts files created from a right-click on the Desktop where the user clicked, as Finder's own
/// "New Folder" does. macOS has no public API for icon positions, so Finder is asked with one fixed Apple
/// Event ("set position of <file> to {x, y}") built in process: no script source, and the file only ever
/// travels as an alias. The first use asks for Automation consent; a refusal, a file outside the Desktop or
/// a sorted or stacked Desktop simply leaves the icon where Finder put it (A38). Plugins cannot send Apple
/// Events themselves: their entitlements are allow-listed without it.
enum DesktopPlacement {
    private static let notAuthorized = -1743
    private static let queue = DispatchQueue(label: "ruyio.desktop-placement")

    static func place(_ urls: [URL], at location: CGPoint) async {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath().path else { return }
        let onDesktop = urls.filter { $0.deletingLastPathComponent().resolvingSymlinksInPath().path == desktop }
        guard !onDesktop.isEmpty, let main = await MainActor.run(body: { NSScreen.screens.first?.frame }) else { return }
        // Finder's Desktop coordinates start at the top-left of the main display and grow downwards.
        let x = Int32(location.x.rounded())
        let y = Int32((main.maxY - location.y).rounded())
        for (index, url) in onDesktop.prefix(16).enumerated() {
            guard await setPosition(of: url, x: x + Int32(index) * 90, y: y) else { return }
        }
    }

    /// Finder may not list a brand-new file for a moment, so a few attempts are made. Returns false once
    /// the user has refused Automation, so the remaining files are not tried.
    private static func setPosition(of url: URL, x: Int32, y: Int32) async -> Bool {
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            switch await send(url, x, y) {
            case 0: return true
            case notAuthorized: return false
            default: continue
            }
        }
        return true
    }

    /// Sends off the main thread: the first send waits for the Automation consent dialog.
    private static func send(_ url: URL, _ x: Int32, _ y: Int32) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let alias = NSAppleEventDescriptor(fileURL: url).coerce(toDescriptorType: DescType(typeAlias)),
                      let property = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
                    continuation.resume(returning: -1)
                    return
                }
                property.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
                property.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
                property.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(pPosition)), forKeyword: AEKeyword(keyAEKeyData))
                property.setDescriptor(alias, forKeyword: AEKeyword(keyAEContainer))
                let point = NSAppleEventDescriptor.list()
                point.insert(NSAppleEventDescriptor(int32: x), at: 1)
                point.insert(NSAppleEventDescriptor(int32: y), at: 2)
                let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAESetData),
                                                   targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
                                                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(property, forKeyword: AEKeyword(keyDirectObject))
                event.setParam(point, forKeyword: AEKeyword(keyAEData))
                do {
                    let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 60)
                    let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
                    continuation.resume(returning: Int(error))
                } catch {
                    continuation.resume(returning: (error as NSError).code)
                }
            }
        }
    }
}
