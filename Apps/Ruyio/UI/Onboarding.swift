import AppKit
import RuyioCore
import RuyioHostKit
import RuyioUI
import SwiftUI

/// First launch (PRD §6, §19.1): welcome → clipboard → Finder → done. No purpose questionnaire;
/// every step can be skipped except system prompts the user chooses to open.
@MainActor
final class OnboardingController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    let state = OnboardingState()
    var onFinish: ((_ openPalette: Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, state: state, finish: { [weak self] palette in self?.finish(openPalette: palette) }))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        state.step = 0
        state.practiceText = ""
        state.clipboardDone = false
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        PasteService.shared.inAppPasteTarget = { [weak self] text in
            guard let self, self.state.step == 1 else { return false }
            // An image (or any non-text item) completes the step too, without an Accessibility prompt.
            self.state.practiceText = text ?? self.model.l.t("（已粘贴一张图片或文件）", "(Pasted an image or file)")
            self.state.clipboardDone = true
            return true
        }
    }

    /// Closing the window equals "Set Up Later" (interaction §5.1).
    func windowWillClose(_ notification: Notification) {
        PasteService.shared.inAppPasteTarget = nil
        if !model.settings.onboardingCompleted { model.update { $0.onboardingCompleted = true } }
    }

    func finish(openPalette: Bool) {
        model.update { $0.onboardingCompleted = true }
        PasteService.shared.inAppPasteTarget = nil
        window?.close()
        onFinish?(openPalette)
    }
}

@MainActor
final class OnboardingState: ObservableObject {
    @Published var step = 0
    @Published var practiceText = ""
    @Published var clipboardDone = false
    @Published var finderSkipped = false
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: OnboardingState
    let finish: (Bool) -> Void
    var l: L10n { model.l }
    private var clipboardName: String { model.summary(PluginID("app.ruyio.clipboard-history"))?.displayName ?? "Clipboard History" }

    var body: some View {
        VStack(spacing: 0) {
            stepDots.padding(.top, 22)
            Group {
                switch state.step {
                case 0: welcome
                case 1: clipboard
                case 2: finder
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 56)
        }
        .frame(width: 620, height: 540)
        .environment(\.locale, Locale(identifier: model.language))
    }

    var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4) { index in
                Capsule().fill(index == state.step ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: index == state.step ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy, value: state.step)
        .accessibilityElement()
        .accessibilityLabel("\(state.step + 1) / 4")
    }

    /// Hero icon, title and message centred; actions pinned to the bottom (macOS welcome-screen layout).
    func page<Content: View, Actions: View>(_ title: String, message: String? = nil, @ViewBuilder icon: () -> some View,
                                            @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 12)
            icon()
            Text(title).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
            if let message { Text(message).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            content().padding(.top, 6)
            Spacer(minLength: 12)
            VStack(spacing: 10) { actions() }
                .padding(.bottom, 28)
        }
    }

    func tile(_ symbol: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.gradient).frame(width: 76, height: 76)
            .overlay(Image(systemName: symbol).font(.system(size: 36, weight: .medium)).foregroundStyle(.white))
            .shadow(color: color.opacity(0.35), radius: 10, y: 4)
            .accessibilityHidden(true)
    }

    func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 220) }
            .controlSize(.extraLarge)
            .buttonBorderShape(.capsule)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!enabled)
    }

    func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.link)
    }

    var welcome: some View {
        page(l.welcomeTitle, message: l.welcomeBody) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 104, height: 104).accessibilityHidden(true)
        } content: {
            VStack(spacing: 6) {
                Toggle(l.launchAtLogin, isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                if let error = model.settingsError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        } actions: {
            primary(l.continueTitle) { state.step = 1 }
            secondary(l.later) { finish(false) }
        }
    }

    var clipboard: some View {
        page(l.clipboardStepTitle) {
            tile("list.clipboard.fill", .orange)
        } content: {
            VStack(spacing: 12) {
                captureStatus
                Text(l.thenPress("⇧⌘V")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextEditor(text: $state.practiceText)
                    .font(.body).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 84)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .overlay(alignment: .topLeading) {
                        if state.practiceText.isEmpty {
                            Text(l.practiceField).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                if state.clipboardDone { Label(l.clipboardStepDone, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        } actions: {
            primary(l.continueTitle, enabled: state.clipboardDone) { state.step = 2 }
            secondary(l.skip) { state.step = 2 }
        }
    }

    @ViewBuilder
    var captureStatus: some View {
        let report = model.summary(PluginID("app.ruyio.clipboard-history"))?.report
        switch report?.captureState {
        case .blockedBySystem?:
            HStack {
                Label(l.t("系统未允许读取剪贴板", "macOS is not allowing clipboard access"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button(l.openSystemSettings) { SystemSettings.openPasteboardPrivacy() }
            }
        case .recording?:
            Label(l.waitingForCopy, systemImage: "ellipsis.circle").foregroundStyle(.secondary)
        default:
            Label(report?.statusText ?? l.waitingForCopy, systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }

    var finder: some View {
        page(l.finderStepTitle) {
            tile("folder.fill", .blue)
        } content: {
            VStack(spacing: 12) {
                if FinderExtensionStatus.isTranslocated {
                    Label(l.moveToApplications, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Text(l.finderExtension)
                    Spacer()
                    Label(model.finderExtensionEnabled ? l.enabledState : l.notEnabled,
                          systemImage: model.finderExtensionEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(model.finderExtensionEnabled ? .green : .orange)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                if !model.finderExtensionEnabled {
                    Text(OSVersion.current < OSVersion(major: 15, minor: 2) ? l.finderLegacyHint : l.finderNotEnabledHint)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(l.openSystemSettings) { FinderExtensionStatus.showManagementInterface() }
                        Button(l.recheck) { model.refreshSystemState() }
                    }
                } else {
                    Button(l.tryInFinder) { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")) }
                }
            }
        } actions: {
            primary(l.done, enabled: model.finderExtensionEnabled) { state.step = 3 }
            secondary(l.skip) { state.finderSkipped = true; state.step = 3 }
        }
        .onAppear { model.refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshSystemState() }
    }

    var done: some View {
        page(l.readyTitle) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(.green.gradient).accessibilityHidden(true)
        } content: {
            VStack(spacing: 0) {
                summaryRow(clipboardName, shortcut: "⇧⌘V", ok: state.clipboardDone)
                Divider().padding(.leading, 14)
                summaryRow(l.finderExtension, shortcut: "Ruyio ›", ok: model.finderExtensionEnabled)
                Divider().padding(.leading, 14)
                summaryRow(l.commandPalette, shortcut: model.settings.commandPaletteShortcut.flatMap(KeyShortcut.init(manifestString:))?.displayString ?? l.notSet, ok: nil)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        } actions: {
            primary(l.startUsing) { finish(true) }
            secondary(l.viewPlugins) { finish(false); model.page = .plugins; NSApp.sendAction(#selector(AppDelegate.showMainWindow), to: nil, from: nil) }
        }
    }

    func summaryRow(_ title: String, shortcut: String, ok: Bool?) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyCap(shortcut)
            if let ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(ok ? .green : .secondary)
                    .accessibilityLabel(ok ? l.finished : l.notCompleted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
