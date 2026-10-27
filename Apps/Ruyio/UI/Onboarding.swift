import AppKit
import RuyioCore
import RuyioHostKit
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
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
            self.state.practiceText = text
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch state.step {
            case 0: welcome
            case 1: clipboard
            case 2: finder
            default: done
            }
        }
        .padding(32)
        .frame(width: 600, height: 480, alignment: .topLeading)
        .environment(\.locale, Locale(identifier: model.language))
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandWordmark().frame(height: 44)
            Text(l.welcomeTitle).font(.title.weight(.semibold))
            Text(l.welcomeBody).fixedSize(horizontal: false, vertical: true)
            Toggle(l.launchAtLogin, isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if let error = model.settingsError { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer()
            HStack {
                Spacer()
                Button(l.later) { finish(false) }
                Button(l.continueTitle) { state.step = 1 }.keyboardShortcut(.defaultAction)
            }
        }
    }

    var clipboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(model.summary(PluginID("app.ruyio.clipboard-history"))?.displayName ?? "Clipboard History").font(.headline); Spacer(); Text("1 / 2").foregroundStyle(.secondary) }
            Text(l.clipboardStepTitle).font(.title2.weight(.semibold))
            captureStatus
            Text(l.thenPress("⇧⌘V"))
            Text(l.practiceField).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $state.practiceText).font(.body).frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if state.clipboardDone { Label(l.clipboardStepDone, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            Spacer()
            HStack {
                Spacer()
                Button(l.skip) { state.step = 2 }
                Button(l.continueTitle) { state.step = 2 }.keyboardShortcut(.defaultAction).disabled(!state.clipboardDone)
            }
        }
    }

    @ViewBuilder
    var captureStatus: some View {
        let report = model.summary(PluginID("app.ruyio.clipboard-history"))?.report
        switch report?.captureState {
        case .blockedBySystem?:
            HStack {
                Label(l.t("系统未允许读取剪贴板", "macOS is not allowing clipboard access"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button(l.openSystemSettings) { SystemSettings.openPasteboardPrivacy() }
            }
        case .recording?:
            Label(l.waitingForCopy, systemImage: "ellipsis.circle").foregroundStyle(.secondary)
        default:
            Label(report?.statusText ?? l.waitingForCopy, systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }

    var finder: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(l.finderExtension).font(.headline); Spacer(); Text("2 / 2").foregroundStyle(.secondary) }
            Text(l.finderStepTitle).font(.title2.weight(.semibold))
            if FinderExtensionStatus.isTranslocated {
                Label(l.moveToApplications, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Text(l.finderExtension)
                Spacer()
                StatusChip(text: model.finderExtensionEnabled ? l.enabledState : l.notEnabled, tone: model.finderExtensionEnabled ? .green : .orange)
            }
            if !model.finderExtensionEnabled {
                Text(OSVersion.current < OSVersion(major: 15, minor: 2) ? l.finderLegacyHint : l.finderNotEnabledHint).foregroundStyle(.secondary)
                HStack {
                    Button(l.openSystemSettings) { FinderExtensionStatus.showManagementInterface() }
                    Button(l.recheck) { model.refreshSystemState() }
                }
            } else {
                Button(l.tryInFinder) { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")) }
            }
            Spacer()
            HStack {
                Spacer()
                Button(l.skip) { state.finderSkipped = true; state.step = 3 }
                Button(l.done) { state.step = 3 }.keyboardShortcut(.defaultAction).disabled(!model.finderExtensionEnabled)
            }
        }
        .onAppear { model.refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshSystemState() }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l.readyTitle).font(.title.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text(model.summary(PluginID("app.ruyio.clipboard-history"))?.displayName ?? "Clipboard History")
                    Text("⇧⌘V").font(.system(.body, design: .monospaced))
                    StatusChip(text: state.clipboardDone ? l.finished : l.notCompleted, tone: state.clipboardDone ? .green : .orange)
                }
                GridRow {
                    Text(l.finderExtension)
                    Text("Ruyio ›")
                    StatusChip(text: model.finderExtensionEnabled ? l.enabledState : l.notCompleted, tone: model.finderExtensionEnabled ? .green : .orange)
                }
                GridRow {
                    Text(l.commandPalette)
                    Text(model.settings.commandPaletteShortcut.flatMap(KeyShortcut.init(manifestString:))?.displayString ?? l.notSet).font(.system(.body, design: .monospaced))
                    Text("")
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button(l.viewPlugins) { finish(false); model.page = .plugins; NSApp.sendAction(#selector(AppDelegate.showMainWindow), to: nil, from: nil) }
                Button(l.startUsing) { finish(true) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
