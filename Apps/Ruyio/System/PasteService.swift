import AppKit
import Carbon.HIToolbox
import RuyioCore

/// Remembers the previously active app and pastes into it only when it can be proven to be in front
/// again (plan §12.3). Event construction follows Maccy/Clipy (MIT): left-⌘ flag, layout-aware key code.
@MainActor
final class PasteService {
    static let shared = PasteService()

    private(set) var previousApp: NSRunningApplication?
    /// When Ruyio itself was in front (onboarding practice field), the host inserts the text directly:
    /// no ⌘V simulation and no Accessibility request (PRD §19.1).
    /// Receives the pasted text, or nil for non-text content such as an image.
    var inAppPasteTarget: ((String?) -> Bool)?

    func rememberFrontmostApp() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
    }

    /// Returns true when the content was delivered to an in-app target.
    func deliverInApp() -> Bool {
        guard previousApp == nil, let target = inAppPasteTarget else { return false }
        return target(NSPasteboard.general.string(forType: .string))
    }

    enum Outcome { case pasted, copiedOnly(reason: String) }

    /// Called after the overlay is closed and the content is already on the pasteboard.
    func pasteIntoPreviousApp(autoPaste: Bool) async -> Outcome {
        guard autoPaste else { return .copiedOnly(reason: "copy-only") }
        guard let target = previousApp, !target.isTerminated else { return .copiedOnly(reason: "no-target") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
        }
        // Wait for the target to really become frontmost; never send keys to the wrong app.
        for _ in 0..<40 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return .copiedOnly(reason: "focus")
        }
        guard AXIsProcessTrusted() else { return .copiedOnly(reason: "accessibility") }
        guard !IsSecureEventInputEnabled() else { return .copiedOnly(reason: "secure-input") }
        try? await Task.sleep(for: .milliseconds(60))
        postCommandV()
        return .pasted
    }

    private func postCommandV() {
        let keyCode = KeyboardLayout.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        // 0x000008 marks the left command key (Flycut PR #18, adopted by Maccy).
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// First automatic paste without permission: explain once, then never ask again on refusal (PRD §19.16).
    func requestAccessibilityIfAppropriate(model: AppModel) -> Bool {
        if AXIsProcessTrusted() { return true }
        if model.settings.neverAskAutoPaste { return false }
        let l = model.l
        let alert = NSAlert()
        alert.messageText = l.autoPasteTitle
        alert.informativeText = l.autoPasteMessage
        alert.addButton(withTitle: l.openSystemSettings)
        alert.addButton(withTitle: l.copyOnlyDontAsk)
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            SystemSettings.openAccessibility()
        } else {
            model.update { $0.neverAskAutoPaste = true }
        }
        return false
    }
}

/// Key codes for characters in the current keyboard layout (the idea behind Clipy's Sauce, MIT).
enum KeyboardLayout {
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
