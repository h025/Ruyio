import Foundation
import RuyioCore
import RuyioProtocol

/// Host UI copy (PRD §16). A code table instead of a String Catalog so the language switches instantly
/// without relaunch (plan §17.1) and missing keys fail to compile. Decision A16 in implementation-status.md.
struct L10n {
    let zh: Bool
    init(_ language: String) { zh = language.hasPrefix("zh") }
    func t(_ zhText: String, _ enText: String) -> String { zh ? zhText : enText }

    // Navigation
    var plugins: String { t("插件", "Plugins") }
    var market: String { t("插件市场", "Market") }
    var shortcuts: String { t("快捷键", "Shortcuts") }
    var privacy: String { t("权限与隐私", "Permissions & Privacy") }
    var general: String { t("通用设置", "General") }
    var tagline: String { t("开源 · 本地优先", "Open source · Local first") }

    // Plugins page
    var addSource: String { t("添加插件或市场…", "Add Plugin or Market…") }
    var searchPlugins: String { t("搜索名称、作者或来源", "Search name, author or source") }
    var filterAll: String { t("全部", "All") }
    var filterEnabled: String { t("已启用", "Enabled") }
    var filterDisabled: String { t("已停用", "Disabled") }
    var filterAttention: String { t("需要处理", "Needs Attention") }
    var groupEnabled: String { t("已启用", "Enabled") }
    var groupDisabled: String { t("已停用", "Disabled") }
    var groupRestorable: String { t("可恢复默认插件", "Restorable Default Plugins") }
    var restore: String { t("恢复", "Restore") }
    var noPlugins: String { t("还没有安装插件", "No plugins installed") }
    var noPluginsHint: String { t("添加一个插件或市场地址来开始。", "Add a plugin or market address to get started.") }
    var official: String { t("官方", "Official") }
    var developer: String { t("开发者插件", "Developer") }
    func entries(_ n: Int) -> String { t("\(n) 个入口", n == 1 ? "1 entry" : "\(n) entries") }

    // Detail
    var overview: String { t("概览", "Overview") }
    var actionsAndEntries: String { t("动作与入口", "Actions & Entries") }
    var permissions: String { t("权限", "Permissions") }
    var settings: String { t("设置", "Settings") }
    var version: String { t("版本", "Version") }
    var author: String { t("作者", "Author") }
    var source: String { t("来源", "Source") }
    var sourceUnverified: String { t("（发布者声明，未验证）", "(declared by publisher, unverified)") }
    var signature: String { t("签名", "Signature") }
    var status: String { t("状态", "Status") }
    var lastError: String { t("最近错误", "Last error") }
    var dataLocation: String { t("数据", "Data") }
    var uninstall: String { t("卸载插件…", "Uninstall Plugin…") }
    var disablePlugin: String { t("停用插件", "Disable Plugin") }
    var enablePlugin: String { t("启用插件", "Enable Plugin") }
    var commandPalette: String { t("命令面板", "Command Palette") }
    var hotkey: String { t("快捷键", "Shortcut") }
    var finder: String { t("Finder", "Finder") }
    var menuBar: String { t("菜单栏", "Menu Bar") }
    var manageFinderMenu: String { t("管理 Finder 菜单…", "Manage Finder Menu…") }
    var restoreDefaultLayout: String { t("恢复默认布局", "Restore Default Layout") }
    var moveUp: String { t("上移", "Move Up") }
    var moveDown: String { t("下移", "Move Down") }
    var done: String { t("完成", "Done") }
    var cancel: String { t("取消", "Cancel") }
    var noSettings: String { t("此插件没有设置项。", "This plugin has no settings.") }
    var settingsNeedEnable: String { t("启用插件后才能编辑这些设置。", "Enable the plugin to edit these settings.") }
    var updateChannel: String { t("更新方式", "Updates") }
    var updatesWithHost: String { t("随 Ruyio 更新", "Updated with Ruyio") }
    var noUpdateSource: String { t("无更新来源", "No update source") }
    var pendingOutcomes: String { t("有操作结果待核对，请在 Finder 中查看目标位置。", "Some operations need checking; review the target in Finder.") }
    var markResolved: String { t("标记已处理", "Mark as Checked") }

    // Uninstall sheet
    func uninstallTitle(_ name: String) -> String { t("卸载“\(name)”？", "Uninstall “\(name)”?") }
    func uninstallMessage(_ entries: Int, running: Bool) -> String {
        t("将移除 \(entries) 个入口\(running ? "，并停止正在运行的进程" : "")。插件数据默认保留，重新安装或恢复后会重新关联。",
          "\(entries) entries will be removed\(running ? " and the running process stopped" : ""). Plugin data is kept by default and reattached on reinstall.")
    }
    var deleteData: String { t("同时删除插件数据（无法撤销）", "Also delete plugin data (cannot be undone)") }
    func dataSummary(_ docs: Int, _ bytes: Int64) -> String {
        t("\(docs) 条记录，\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))",
          "\(docs) records, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
    }
    var containerNote: String { t("插件在其系统容器中自行保存的内容不由 Ruyio 删除。", "Content the plugin stored in its own system container is not deleted by Ruyio.") }

    // States
    func activation(_ state: ActivationState) -> String {
        switch state {
        case .disabled: return t("已停用", "Disabled")
        case .enabling: return t("正在启用", "Enabling")
        case .needsPermission: return t("需要权限", "Needs permission")
        case .enabled: return t("已启用", "Enabled")
        case .disabling: return t("正在停用", "Disabling")
        case .runtimeFailed: return t("运行异常", "Runtime error")
        }
    }

    func badge(_ badge: PluginBadge) -> String {
        switch badge {
        case .runtimeFailed: return t("运行异常", "Runtime error")
        case .identityConflict: return t("身份冲突", "Identity conflict")
        case .incompatible: return t("不兼容", "Incompatible")
        case .needsPermission: return t("需要权限", "Needs permission")
        case .outcomePending: return t("结果待核对", "Needs checking")
        case .updateAvailable: return t("可更新", "Update available")
        case .sourceRemoved: return t("来源已移除", "Source removed")
        case .noUpdateSource: return t("无更新来源", "No update source")
        case .developer: return t("开发者插件", "Developer")
        }
    }

    func errorText(_ error: RuyioError) -> String {
        switch error.code {
        case .pluginNotInvocable: return t("插件当前不可用，请检查是否已启用。", "The plugin is not available. Check that it is enabled.")
        case .pluginCrashed: return t("插件意外退出。可以重试，Ruyio 不会自动反复重启它。", "The plugin quit unexpectedly. You can retry; Ruyio does not restart it in a loop.")
        case .handshakeTimeout, .handshakeFailed: return t("插件未能完成启动握手。", "The plugin did not complete its startup handshake.")
        case .pluginLaunchFailed: return t("无法启动插件进程。", "The plugin process could not start.")
        case .requestTimeout: return t("操作超时，已停止等待；数据未被修改。", "The operation timed out; no data was changed.")
        case .permissionNotDeclared, .permissionDenied: return t("插件没有执行此操作的权限。", "The plugin is not allowed to do this.")
        case .contextExpired: return t("操作已过期，请重新执行。", "This request expired. Please try again.")
        case .fileAccessDenied: return t("没有访问该位置的权限。请在“系统设置 > 隐私与安全性 > 文件与文件夹”中允许 Ruyio。", "No access to this location. Allow Ruyio in System Settings > Privacy & Security > Files and Folders.")
        case .fileConflict: return t("已存在同名文件。", "A file with that name already exists.")
        case .fileNameInvalid: return t("文件名无效。", "The file name is not valid.")
        case .outcomeUnknown: return t("无法确认操作是否完成，请在 Finder 中查看目标位置。不会自动重试。", "Ruyio cannot confirm whether this finished. Check the target in Finder; it will not be retried automatically.")
        case .storageQuotaExceeded: return t("插件数据已达到容量上限。", "The plugin's storage is full.")
        case .retainedDataIncompatible: return t("保留的数据与此插件版本不兼容，请选择使用新数据恢复。", "The retained data is incompatible with this plugin version. Restore with new data to continue.")
        case .cancelled: return t("已取消。", "Cancelled.")
        case .sourceInvalid: return t("插件包未通过校验：", "The package failed verification: ") + (error.diagnostic ?? "")
        case .pluginAlreadyInstalled: return t("该插件已安装。请在插件详情中检查更新或更换来源。", "This plugin is already installed. Check for updates or change its source in its details.")
        default: return t("操作失败：", "The operation failed: ") + error.code.rawValue
        }
    }

    // Command palette
    var commandPlaceholder: String { t("输入命令或搜索插件", "Type a command or search plugins") }
    var recentlyUsed: String { t("最近使用", "Recently Used") }
    var noCommands: String { t("没有匹配命令", "No matching commands") }
    var openMarket: String { t("浏览插件市场", "Browse the Market") }
    var paletteHelp: String { t("↑↓ 选择    ↩ 执行    esc 关闭", "↑↓ Select    ↩ Run    esc Close") }
    var running: String { t("正在执行…", "Running…") }
    var retry: String { t("重试", "Retry") }
    var openPluginDetail: String { t("打开插件详情", "Open Plugin Details") }
    var back: String { t("返回", "Back") }

    // Paste
    var copiedPasteManually: String { t("已复制到剪贴板，请按 ⌘V 粘贴", "Copied to the clipboard. Press ⌘V to paste") }
    var autoPasteTitle: String { t("允许自动粘贴？", "Allow automatic paste?") }
    var autoPasteMessage: String { t("Ruyio 需要“辅助功能”权限，才能把选中的内容直接粘贴到原来的应用。也可以只复制，由你手动按 ⌘V。", "Ruyio needs Accessibility permission to paste into the previous app. You can also copy only and press ⌘V yourself.") }
    var openSystemSettings: String { t("打开系统设置", "Open System Settings") }
    var copyOnlyDontAsk: String { t("仅复制，不再询问", "Copy Only, Don’t Ask Again") }

    // Menu bar
    var openCommandPalette: String { t("打开命令面板", "Open Command Palette") }
    var openPlugins: String { t("插件…", "Plugins…") }
    var openSettings: String { t("设置…", "Settings…") }
    func quit(_ app: String) -> String { t("退出 \(app)", "Quit \(app)") }
    var pauseRecording: String { t("暂停记录", "Pause Recording") }
    var resumeRecording: String { t("恢复记录", "Resume Recording") }

    // Shortcuts page
    var searchActions: String { t("搜索动作", "Search actions") }
    var notSet: String { t("未设置", "Not set") }
    var restoreDefault: String { t("恢复默认", "Restore Default") }
    var recordShortcut: String { t("请按下新的快捷键", "Press the new shortcut") }
    var clear: String { t("清除", "Clear") }
    var unavailable: String { t("不可用", "Unavailable") }
    var pluginDisabledNote: String { t("插件已停用", "Plugin disabled") }
    func conflictMessage(_ other: String) -> String { t("该快捷键已被“\(other)”使用。替换后原绑定将被清除。", "This shortcut is used by “\(other)”. Replacing it clears the existing binding.") }
    var replace: String { t("替换原绑定", "Replace") }
    func shortcutRejected(_ reason: KeyShortcut.Rejection) -> String {
        switch reason {
        case .noModifier: return t("全局快捷键需要包含 ⌘、⌃ 或 ⌥。", "Global shortcuts need ⌘, ⌃ or ⌥.")
        case .systemReserved: return t("该组合由系统或输入法使用。", "This combination is used by macOS or input sources.")
        case .optionOnlyOnEarlySequoia: return t("此系统版本不允许只用 ⌥ 的快捷键。", "Option-only shortcuts are not allowed on this macOS version.")
        }
    }

    // Privacy page
    var systemPermissions: String { t("系统权限", "System Permissions") }
    var pluginPermissions: String { t("插件权限", "Plugin Permissions") }
    var accessibility: String { t("辅助功能", "Accessibility") }
    var accessibilityUse: String { t("自动粘贴", "Automatic paste") }
    var finderExtension: String { t("Finder 扩展", "Finder Extension") }
    var finderExtensionUse: String { t("Finder 右键菜单", "Finder context menu") }
    var filesAndFolders: String { t("文件与文件夹", "Files and Folders") }
    var filesAndFoldersUse: String { t("Finder 动作写入受保护位置时由系统询问", "Asked by macOS when Finder actions write to protected locations") }
    var clipboardAccess: String { t("剪贴板访问", "Clipboard Access") }
    var clipboardAccessUse: String { t("历史剪贴板读取复制内容（macOS 15.4 起由系统管理）", "Clipboard History reads copies (managed by macOS 15.4+)") }
    var authorized: String { t("已授权", "Allowed") }
    var notAuthorized: String { t("未授权", "Not allowed") }
    var enabledState: String { t("已启用", "Enabled") }
    var notEnabled: String { t("未启用", "Not enabled") }
    var asNeeded: String { t("按需", "When needed") }
    var unknownState: String { t("未知", "Unknown") }
    func enforcement(_ level: EnforcementLevel) -> String {
        switch level {
        case .systemEnforced: return t("由 macOS 限制", "Enforced by macOS")
        case .hostMediated: return t("每次使用时由 Ruyio 授权", "Granted by Ruyio per use")
        case .declaredAudited: return t("开发者声明，无法强制", "Declared, not enforced")
        case .hostLifecycle: return t("由 Ruyio 控制运行", "Controlled by Ruyio")
        }
    }
    func permissionName(_ permission: Permission) -> String {
        switch permission {
        case .clipboardRead: return t("读取剪贴板", "Read clipboard")
        case .clipboardWrite: return t("写入剪贴板", "Write clipboard")
        case .filesReadSelected: return t("读取你选择的文件", "Read files you choose")
        case .filesWrite: return t("创建或修改文件", "Create or modify files")
        case .appsOpen: return t("打开外部应用", "Open other apps")
        case .pasteAutomatic: return t("自动粘贴", "Automatic paste")
        case .background: return t("后台运行", "Run in background")
        case .networkClient: return t("网络访问（互联网、本机及局域网）", "Network (internet, this Mac and local network)")
        case .screenCapture: return t("截取你框选的屏幕区域", "Capture the screen area you select")
        case .windowsPin: return t("在其他窗口上方显示图片", "Show images above other windows")
        }
    }
    var auditedNote: String { t("原生插件可能绕过声明直接访问剪贴板；如需阻止，请停用或卸载插件。", "Native plugins can bypass declarations to read the clipboard; disable or uninstall the plugin to stop it.") }
    var recheck: String { t("重新检测", "Check Again") }

    // General
    var startup: String { t("启动", "Startup") }
    var launchAtLogin: String { t("登录时启动", "Open at Login") }
    var showInMenuBar: String { t("在菜单栏显示", "Show in Menu Bar") }
    var appearance: String { t("外观", "Appearance") }
    var theme: String { t("主题", "Theme") }
    var followSystem: String { t("跟随系统", "System") }
    var light: String { t("浅色", "Light") }
    var dark: String { t("深色", "Dark") }
    var language: String { t("语言", "Language") }
    var updates: String { t("更新", "Updates") }
    var autoRefreshMarkets: String { t("自动刷新市场索引", "Refresh market indexes automatically") }
    var autoCheckPlugins: String { t("自动检查插件更新", "Check for plugin updates automatically") }
    var autoCheckApp: String { t("自动检查应用更新", "Check for app updates automatically") }
    var dataSection: String { t("数据", "Data") }
    var includeInBackup: String { t("插件数据包含在 Time Machine 备份中", "Include plugin data in Time Machine backups") }
    var advanced: String { t("高级", "Advanced") }
    var developerMode: String { t("开发者模式", "Developer Mode") }
    var developerModeWarning: String { t("开发者插件可以访问你的数据，且未经 Apple 公证。开启后，本地插件包和市场中未公证的插件都会作为开发者插件安装；关闭后它们会被停用。仅安装你信任的插件。", "Developer plugins can access your data and are not notarized by Apple. While this is on, local packages and un-notarized market plugins install as developer plugins; turning it off disables them. Only install plugins you trust.") }
    var loadDevelopmentPlugin: String { t("选择本地开发插件…", "Choose Local Development Plugin…") }
    var help: String { t("帮助", "Help") }
    var rerunOnboarding: String { t("重新运行首次引导", "Run Onboarding Again") }
    var openLogs: String { t("打开日志目录", "Open Logs Folder") }
    var clearLogs: String { t("清空日志", "Clear Logs") }
    var licenses: String { t("开源许可", "Open Source Licenses") }
    var saveFailed: String { t("保存失败，已恢复原设置：", "Could not save; the previous setting was restored: ") }

    // Market (M4)
    var marketEmpty: String { t("尚未添加插件市场", "No plugin markets added") }
    var marketEmptyHint: String { t("添加 GitHub 或 HTTPS 市场地址，浏览并安装更多插件。", "Add a GitHub or HTTPS market address to browse and install more plugins.") }
    var addMarket: String { t("添加市场…", "Add Market…") }
    var resolve: String { t("解析", "Resolve") }
    var addressPrompt: String { t("GitHub 仓库、子目录或 HTTPS 地址", "GitHub repository, subfolder or HTTPS address") }

    // Onboarding
    var welcomeTitle: String { t("欢迎使用 Ruyio", "Welcome to Ruyio") }
    var welcomeBody: String { t("由插件组成的 macOS 工具箱。已准备好：历史剪贴板、Finder 基础工具。两个插件都可以停用或卸载，随时恢复。", "A macOS toolbox made of plugins. Ready to go: Clipboard History and Finder Essentials. Both can be disabled or uninstalled and restored any time.") }
    var later: String { t("稍后设置", "Set Up Later") }
    var continueTitle: String { t("继续", "Continue") }
    var skip: String { t("跳过", "Skip") }
    var clipboardStepTitle: String { t("复制一段文字或一张图片", "Copy some text or an image") }
    var waitingForCopy: String { t("等待新的复制…", "Waiting for a new copy…") }
    func fromPlugin(_ name: String) -> String { t("来自插件「\(name)」", "From the plugin “\(name)”") }
    func thenPress(_ shortcut: String) -> String { t("然后按 \(shortcut)，在历史中选择它并按 ↩", "Then press \(shortcut), pick it and press ↩") }
    var practiceField: String { t("练习输入框", "Practice field") }
    var clipboardStepDone: String { t("完成！内容已插入练习输入框。", "Done! The item was inserted into the practice field.") }
    var finderStepTitle: String { t("在文件旁边完成常用操作", "Common actions right next to your files") }
    var finderNotEnabledHint: String { t("需要在系统设置中启用 Ruyio 的 Finder 扩展。", "Enable the Ruyio Finder extension in System Settings.") }
    var finderLegacyHint: String { t("此版本 macOS 的系统设置没有扩展开关。请更新到 macOS 15.2 或更高版本，或稍后在设置中重试。", "This macOS version has no extension switch in System Settings. Update to macOS 15.2 or later, or try again later from Settings.") }
    var moveToApplications: String { t("请先把 Ruyio 移到“应用程序”文件夹，再启用 Finder 扩展。", "Move Ruyio to the Applications folder before enabling the Finder extension.") }
    var tryInFinder: String { t("在 Finder 中试用", "Try in Finder") }
    var readyTitle: String { t("准备就绪", "You’re All Set") }
    var viewPlugins: String { t("查看插件", "View Plugins") }
    var startUsing: String { t("开始使用", "Start Using Ruyio") }
    var notCompleted: String { t("未完成", "Not completed") }
    var finished: String { t("已完成", "Done") }

    // Finder feedback
    var openRuyioToLoad: String { t("打开 Ruyio 以加载", "Open Ruyio to Load") }
    var requestExpired: String { t("操作已过期，请在 Finder 中重新执行。", "The request expired. Please try again in Finder.") }
    var hiddenFilesHowTo: String { t("在 Finder 中按 ⇧⌘. 即可显示或隐藏隐藏文件。", "Press ⇧⌘. in Finder to show or hide hidden files.") }
    func openTerminalConfirm(_ count: Int) -> String { t("将打开 \(count) 个终端窗口，继续吗？", "Open \(count) Terminal windows?") }
    var continueAction: String { t("继续", "Continue") }
    func chooseApp(_ role: String) -> String { role == "editor" ? t("选择用于打开的编辑器", "Choose an editor") : t("选择应用", "Choose an app") }

    // Conflict sheet
    func conflictTitle(_ name: String) -> String { t("“\(name)”已经存在", "“\(name)” already exists") }
    var existingFile: String { t("现有文件", "Existing") }
    var newFile: String { t("新文件", "New") }
    func applyToRemaining(_ n: Int) -> String { t("对剩余 \(n) 项使用此选择", "Apply to the remaining \(n) items") }
    var keepBoth: String { t("保留两者", "Keep Both") }
    var skipItem: String { t("跳过", "Skip") }
    var replaceItem: String { t("替换", "Replace") }

    // Recovery
    var recoveryTitle: String { t("Ruyio 正在恢复数据", "Ruyio is recovering its data") }
    var recoveryBody: String { t("数据库迁移未完成。插件和 Finder 动作已暂停，原数据保持不变。", "A database migration did not finish. Plugins and Finder actions are paused; your original data is unchanged.") }
}

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, zhHans = "zh-Hans", en
    var id: String { rawValue }

    var resolved: String {
        switch self {
        case .system: return Localization.hostLanguage(for: Locale.preferredLanguages)
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        }
    }

    func title(_ l: L10n) -> String {
        switch self {
        case .system: return l.followSystem
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}
