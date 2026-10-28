import AppKit
import Carbon

/// Puts files created from a right-click on the Desktop where the user clicked, as Finder's own
/// "New Folder" does. macOS has no public API for icon positions, so Finder is asked with fixed Apple
/// Events ("set/get desktop position of item <name> of desktop") built in process: no script source, and
/// the file name only travels as data. Finder does not resolve an alias container for these (-1728). The first use asks for Automation consent; a refusal, a file outside the Desktop or
/// a sorted or stacked Desktop simply leaves the icon where Finder put it (A38). Plugins cannot send Apple
/// Events themselves: their entitlements are allow-listed without it.
enum DesktopPlacement {
    private static let notAuthorized = -1743
    private static func fourCC(_ code: String) -> OSType { code.utf8.reduce(0) { $0 << 8 | OSType($1) } }
    /// Finder's "desktop position" (dpos), "desktop" (desk) and "item" (cobj).
    private static let desktopPosition = fourCC("dpos")
    private static let queue = DispatchQueue(label: "ruyio.desktop-placement")

    static func place(_ urls: [URL], at location: CGPoint, log: @escaping @Sendable ([String: String]) -> Void) async {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath().path else { return }
        let onDesktop = urls.filter { $0.deletingLastPathComponent().resolvingSymlinksInPath().path == desktop }
        guard !onDesktop.isEmpty, let main = await MainActor.run(body: { NSScreen.screens.first?.frame }) else { return }
        // Finder's Desktop coordinates start at the top-left of the main display and grow downwards.
        let x = Int32(location.x.rounded())
        let y = Int32((main.maxY - location.y).rounded())
        for (index, url) in onDesktop.prefix(16).enumerated() {
            let target = (x + Int32(index) * 90, y)
            var fields = ["target": "\(target.0),\(target.1)"]
            defer { log(fields) }
            let set = await setPosition(of: url, to: target)
            fields["set"] = String(set)
            if set == notAuthorized { return }
            guard set == 0 else { continue }
            // Finder lays out a file it has only just noticed on its own a moment later, which can undo
            // the first move; check once and move it again if needed.
            try? await Task.sleep(for: .milliseconds(900))
            let actual = await position(of: url)
            fields["after"] = actual.map { "\($0.0),\($0.1)" } ?? "-"
            if let actual, abs(actual.0 - target.0) > 80 || abs(actual.1 - target.1) > 80 {
                fields["retry"] = String(await send(setEvent(url, target)).code)
                fields["final"] = (await position(of: url)).map { "\($0.0),\($0.1)" } ?? "-"
            }
        }
    }

    /// Finder lists a brand-new Desktop file only after it notices it (a second or more), so attempts
    /// continue for about five seconds while it is "not found" (-1728).
    private static func setPosition(of url: URL, to target: (Int32, Int32)) async -> Int {
        var code = -1
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(400)) }
            code = await send(setEvent(url, target)).code
            if code == 0 || code == notAuthorized { return code }
        }
        return code
    }

    private static func position(of url: URL) async -> (Int32, Int32)? {
        let reply = await send(event(AEEventID(kAEGetData), url))
        guard reply.code == 0, reply.numbers.count >= 2 else { return nil }
        return (reply.numbers[0], reply.numbers[1])
    }

    private static func setEvent(_ url: URL, _ target: (Int32, Int32)) -> NSAppleEventDescriptor? {
        guard let event = event(AEEventID(kAESetData), url) else { return nil }
        let point = NSAppleEventDescriptor.list()
        point.insert(NSAppleEventDescriptor(int32: target.0), at: 1)
        point.insert(NSAppleEventDescriptor(int32: target.1), at: 2)
        event.setParam(point, forKeyword: AEKeyword(keyAEData))
        return event
    }

    /// One object-specifier level: `want`, `form`, `seld`, `from`.
    private static func specifier(_ want: OSType, _ form: OSType, _ selector: NSAppleEventDescriptor,
                                  from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        guard let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { return nil }
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(selector, forKeyword: AEKeyword(keyAEKeyData))
        spec.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return spec
    }

    /// `<id> desktop position of item "<name>" of desktop` addressed to Finder.
    private static func event(_ id: AEEventID, _ url: URL) -> NSAppleEventDescriptor? {
        guard let desktop = specifier(OSType(cProperty), OSType(formPropertyID), NSAppleEventDescriptor(typeCode: fourCC("desk")),
                                      from: NSAppleEventDescriptor.null()),
              let item = specifier(fourCC("cobj"), OSType(formName), NSAppleEventDescriptor(string: url.lastPathComponent), from: desktop),
              let property = specifier(OSType(cProperty), OSType(formPropertyID), NSAppleEventDescriptor(typeCode: desktopPosition), from: item)
        else { return nil }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: id,
                                           targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(property, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    /// Sends off the main thread (the first send waits for the Automation consent dialog). Returns the
    /// error number and, for a reply that is a list, its integers.
    private static func send(_ event: NSAppleEventDescriptor?) async -> (code: Int, numbers: [Int32]) {
        guard let event else { return (-1, []) }
        nonisolated(unsafe) let message = event
        return await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let reply = try message.sendEvent(options: [.waitForReply, .canInteract], timeout: 60)
                    let error = Int(reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0)
                    var numbers: [Int32] = []
                    if let list = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)), list.numberOfItems > 0 {
                        for index in 1...list.numberOfItems { numbers.append(list.atIndex(index)?.int32Value ?? 0) }
                    }
                    continuation.resume(returning: (error, numbers))
                } catch {
                    continuation.resume(returning: ((error as NSError).code, []))
                }
            }
        }
    }
}
