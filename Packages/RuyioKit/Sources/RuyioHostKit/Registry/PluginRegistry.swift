import Foundation
import RuyioCore
import RuyioPersistence
import RuyioProtocol

/// The only writer of installed-plugin state and entry preferences (plan §6.2). Every change bumps
/// `generation`, persists first, then publishes a fresh projection to observers.
public actor PluginRegistry {
    public typealias Observer = @Sendable (RegistrySnapshot) -> Void

    private let database: HostDatabase
    private var records: [PluginID: InstalledPluginRecord] = [:]
    private var manifests: [PluginID: PluginManifest] = [:]
    private var processStates: [PluginID: ProcessState] = [:]
    private var reports: [PluginID: PluginStatusReport] = [:]
    private var errors: [PluginID: RuyioError] = [:]
    private var pendingOutcomes: [PluginID: Int] = [:]
    private var preferences: [String: EntryPreferenceRecord] = [:]
    private var groupOrder: [String: Int] = [:]
    private var hotkeys: [String: HotkeyRecord] = [:]
    private var hotkeyStates: [String: HotkeyRegistrationState] = [:]
    private var bundledDefaults: [PluginID: PluginManifest] = [:]
    private var uninstalledDefaults: [String: UninstalledDefaultRecord] = [:]
    private var observers: [UUID: Observer] = [:]
    private var locale: String
    public private(set) var generation = 0

    public init(database: HostDatabase, locale: String) {
        self.database = database
        self.locale = locale
    }

    public func load() throws {
        records = [:]
        manifests = [:]
        for record in try database.installedPlugins() {
            guard let id = PluginID(rawValue: record.pluginID), let manifest = try? record.decodedManifest() else { continue }
            records[id] = record
            manifests[id] = manifest
        }
        preferences = Dictionary(uniqueKeysWithValues: try database.entryPreferences().map { (Self.prefKey($0.pluginID, $0.actionID, $0.kind), $0) })
        groupOrder = try database.finderGroupOrder()
        hotkeys = Dictionary(uniqueKeysWithValues: try database.hotkeys().map { ("\($0.pluginID)/\($0.actionID)", $0) })
        uninstalledDefaults = Dictionary(uniqueKeysWithValues: try database.uninstalledDefaults().map { ($0.pluginID, $0) })
        for (id, count) in Dictionary(grouping: try database.unresolvedOperations(), by: \.pluginID).mapValues(\.count) {
            if let pid = PluginID(rawValue: id) { pendingOutcomes[pid] = count }
        }
        bump()
    }

    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(snapshot())
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    public func setLocale(_ locale: String) {
        self.locale = locale
        bump()
    }

    public func setBundledDefaults(_ manifests: [PluginManifest]) {
        bundledDefaults = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        bump()
    }

    // MARK: Reads

    public func record(_ id: PluginID) -> InstalledPluginRecord? { records[id] }
    public func manifest(_ id: PluginID) -> PluginManifest? { manifests[id] }
    public func installedIDs() -> [PluginID] { records.keys.sorted() }
    public func isDefaultUninstalled(_ id: PluginID) -> Bool { uninstalledDefaults[id.rawValue] != nil }

    public func status(_ id: PluginID) -> PluginStatus? {
        guard let record = records[id] else { return nil }
        var status = record.status
        status.pendingOutcomeCount = pendingOutcomes[id] ?? 0
        return status
    }

    public func isInvocable(_ ref: ActionRef) -> Bool {
        guard let status = status(ref.pluginID), status.isInvocable, let manifest = manifests[ref.pluginID] else { return false }
        return manifest.action(ref.actionID) != nil
    }

    public func isEntryVisible(_ ref: ActionRef, kind: PresentationKind) -> Bool {
        guard let manifest = manifests[ref.pluginID], let action = manifest.action(ref.actionID), action.presentation(kind) != nil else { return false }
        return preferences[Self.prefKey(ref.pluginID.rawValue, ref.actionID.rawValue, kind)]?.visible ?? true
    }

    public func snapshot() -> RegistrySnapshot {
        RegistrySnapshot(generation: generation, plugins: summaries(), restorableDefaults: restorable(), entries: projection())
    }

    // MARK: Writes (persist first, then publish)

    public func insert(_ record: InstalledPluginRecord) throws {
        let manifest = try record.decodedManifest()
        try database.save(record)
        try database.clearDefaultUninstalled(manifest.id)
        records[manifest.id] = record
        manifests[manifest.id] = manifest
        uninstalledDefaults[manifest.id.rawValue] = nil
        bump()
    }

    public func update(_ id: PluginID, _ change: (inout InstalledPluginRecord) -> Void) throws {
        guard var record = records[id] else { throw RuyioError(.pluginNotFound, objectID: id.rawValue) }
        change(&record)
        try database.save(record)
        records[id] = record
        if let manifest = try? record.decodedManifest() { manifests[id] = manifest }
        bump()
    }

    public func setActivation(_ id: PluginID, _ state: ActivationState, error: RuyioError? = nil, preference: Bool? = nil) throws {
        try update(id) { record in
            record.activationState = state
            record.lastErrorCode = error?.code.rawValue
            if let preference { record.enabledPreference = preference }
        }
        errors[id] = error
        if state != .enabled && state != .needsPermission { reports[id] = nil }
    }

    public func remove(_ id: PluginID, asUninstalledDefault: Bool, keptData: Bool) throws {
        try database.deleteInstalledPlugin(id)
        if asUninstalledDefault { try database.markDefaultUninstalled(id, keptData: keptData) }
        records[id] = nil
        manifests[id] = nil
        processStates[id] = nil
        reports[id] = nil
        errors[id] = nil
        preferences = preferences.filter { $0.value.pluginID != id.rawValue }
        if asUninstalledDefault {
            uninstalledDefaults[id.rawValue] = UninstalledDefaultRecord(pluginID: id.rawValue, keptData: keptData)
        }
        bump()
    }

    public func setProcessState(_ id: PluginID, _ state: ProcessState) {
        guard processStates[id] != state else { return }
        processStates[id] = state
        bump()
    }

    public func setReport(_ id: PluginID, _ report: PluginStatusReport) {
        guard reports[id] != report else { return }
        reports[id] = report
        bump()
    }

    public func setPendingOutcomes(_ id: PluginID, count: Int) {
        pendingOutcomes[id] = count
        bump()
    }

    public func setRuntimeError(_ id: PluginID, _ error: RuyioError) throws {
        try setActivation(id, .runtimeFailed, error: error)
    }

    public func setEntryVisible(_ ref: ActionRef, kind: PresentationKind, visible: Bool) throws {
        let key = Self.prefKey(ref.pluginID.rawValue, ref.actionID.rawValue, kind)
        var record = preferences[key] ?? EntryPreferenceRecord(pluginID: ref.pluginID.rawValue, actionID: ref.actionID.rawValue, kind: kind, visible: visible)
        record.visible = visible
        try database.saveEntryPreferences([record])
        preferences[key] = record
        bump()
    }

    /// Reorders Finder items inside one plugin group; cross-plugin moves are rejected (PRD §19.4).
    public func setFinderOrder(pluginID: PluginID, actionIDs: [ActionID]) throws {
        guard let manifest = manifests[pluginID] else { throw RuyioError(.pluginNotFound) }
        let allowed = Set(manifest.actions.filter { $0.presentation(.finderContextMenu) != nil }.map(\.id))
        guard Set(actionIDs).isSubset(of: allowed) else { throw RuyioError(.invalidRequest, diagnostic: "action outside plugin group") }
        var updated: [EntryPreferenceRecord] = []
        for (index, actionID) in actionIDs.enumerated() {
            let key = Self.prefKey(pluginID.rawValue, actionID.rawValue, .finderContextMenu)
            var record = preferences[key] ?? EntryPreferenceRecord(pluginID: pluginID.rawValue, actionID: actionID.rawValue, kind: .finderContextMenu, visible: true)
            record.orderIndex = index
            updated.append(record)
        }
        try database.saveEntryPreferences(updated)
        for record in updated { preferences[Self.prefKey(record.pluginID, record.actionID, record.kind)] = record }
        bump()
    }

    public func setFinderGroupOrder(_ order: [PluginID]) throws {
        try database.saveFinderGroupOrder(order)
        groupOrder = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.rawValue, $0.offset) })
        bump()
    }

    public func resetFinderLayout() throws {
        try database.resetFinderLayout()
        groupOrder = [:]
        for (key, var record) in preferences where record.kind == .finderContextMenu {
            record.orderIndex = nil
            preferences[key] = record
        }
        bump()
    }

    /// nil shortcut = explicitly cleared. `resetToDefault` drops the custom binding.
    public func setHotkey(_ ref: ActionRef, shortcut: KeyShortcut?, resetToDefault: Bool = false) throws {
        let key = "\(ref.pluginID)/\(ref.actionID)"
        if resetToDefault {
            try database.deleteHotkey(pluginID: ref.pluginID.rawValue, actionID: ref.actionID.rawValue)
            hotkeys[key] = nil
        } else {
            let record = HotkeyRecord(pluginID: ref.pluginID.rawValue, actionID: ref.actionID.rawValue, shortcut: shortcut?.manifestString, isCustom: true)
            try database.saveHotkey(record)
            hotkeys[key] = record
        }
        bump()
    }

    public func setHotkeyStates(_ states: [String: HotkeyRegistrationState]) {
        guard hotkeyStates != states else { return }
        hotkeyStates = states
        bump()
    }

    /// Effective shortcut for an action: custom binding, else manifest default.
    public func effectiveShortcut(_ ref: ActionRef) -> KeyShortcut? {
        if let custom = hotkeys["\(ref.pluginID)/\(ref.actionID)"] {
            return custom.shortcut.flatMap(KeyShortcut.init(manifestString:))
        }
        return manifests[ref.pluginID]?.action(ref.actionID)?.presentation(.globalHotkey)?.defaultShortcut.flatMap(KeyShortcut.init(manifestString:))
    }

    // MARK: Projection

    private func bump() {
        generation += 1
        let snapshot = snapshot()
        for observer in observers.values { observer(snapshot) }
    }

    private func summaries() -> [PluginSummary] {
        records.keys.sorted().compactMap { id in
            guard let record = records[id], let manifest = manifests[id] else { return nil }
            var status = record.status
            status.pendingOutcomeCount = pendingOutcomes[id] ?? 0
            return PluginSummary(
                id: id, manifest: manifest, displayName: manifest.displayName(locale: locale).text,
                displayDescription: manifest.description.map { manifest.localized("description", locale: locale, fallback: $0).text },
                status: status, processState: processStates[id] ?? .stopped, report: reports[id],
                isDefault: record.isDefault, publisherID: record.publisherID, installPath: record.installPath,
                dataGeneration: record.dataGeneration, lastError: errors[id])
        }
    }

    private func restorable() -> [RestorableDefault] {
        bundledDefaults.values.filter { records[$0.id] == nil && uninstalledDefaults[$0.id.rawValue] != nil }
            .sorted { $0.id < $1.id }
            .map { RestorableDefault(id: $0.id, displayName: $0.displayName(locale: locale).text, version: $0.version,
                                     keptData: uninstalledDefaults[$0.id.rawValue]?.keptData ?? false) }
    }

    private func projection() -> EntryProjection {
        var commands: [CommandEntry] = []
        var hotkeyEntries: [HotkeyEntry] = []
        var menuBar: [MenuBarGroup] = []
        var finder: [FinderGroupEntry] = []

        for id in records.keys.sorted() {
            guard let record = records[id], let manifest = manifests[id] else { continue }
            let pluginName = manifest.displayName(locale: locale).text
            let invocable = record.status.isInvocable
            var menuItems: [MenuBarItem] = []
            var finderItems: [FinderItemEntry] = []

            for (index, action) in manifest.actions.enumerated() {
                let ref = ActionRef(pluginID: id, actionID: action.id)
                let title = manifest.actionTitle(action, locale: locale).text
                let shortcut = effectiveShortcut(ref)

                if action.presentation(.globalHotkey) != nil {
                    let key = ref.description
                    let state: HotkeyRegistrationState = !invocable ? .pluginDisabled : (shortcut == nil ? .unset : (hotkeyStates[key] ?? .pending))
                    hotkeyEntries.append(HotkeyEntry(
                        ref: ref, title: title, pluginName: pluginName,
                        defaultShortcut: action.presentation(.globalHotkey)?.defaultShortcut.flatMap(KeyShortcut.init(manifestString:)),
                        shortcut: shortcut, isCustom: hotkeys[key] != nil, isPluginEnabled: invocable, state: state))
                }
                guard invocable else { continue }
                if action.presentation(.commandPalette) != nil, isEntryVisible(ref, kind: .commandPalette) {
                    commands.append(CommandEntry(
                        ref: ref, title: action.presentation(.commandPalette)?.title.map { manifest.localized("action.\(action.id).palette", locale: locale, fallback: $0).text } ?? title,
                        subtitle: action.subtitle.map { manifest.localized("action.\(action.id).subtitle", locale: locale, fallback: $0).text },
                        pluginName: pluginName, keywords: action.keywords, symbol: action.symbol,
                        shortcut: hotkeyStates[ref.description] == .registered ? shortcut : nil,
                        opensView: action.opensView, completion: action.completion,
                        needsFinderContext: false,
                        hasParameters: action.parameters != nil))
                }
                if let presentation = action.presentation(.menuBar), isEntryVisible(ref, kind: .menuBar) {
                    let menuTitle = presentation.title.map { manifest.localized("action.\(action.id).menu", locale: locale, fallback: $0).text } ?? title
                    menuItems.append(MenuBarItem(ref: ref, title: menuTitle, shortcut: hotkeyStates[ref.description] == .registered ? shortcut : nil))
                }
                if let presentation = action.presentation(.finderContextMenu), let contexts = presentation.contexts {
                    let pref = preferences[Self.prefKey(id.rawValue, action.id.rawValue, .finderContextMenu)]
                    let finderTitle = presentation.title.map { manifest.localized("action.\(action.id).finder", locale: locale, fallback: $0).text } ?? title
                    finderItems.append(FinderItemEntry(ref: ref, title: finderTitle, contexts: contexts, childrenProvider: presentation.childrenProvider,
                                                       visible: pref?.visible ?? true, order: pref?.orderIndex ?? (presentation.order ?? 1000 + index)))
                }
            }
            if !menuItems.isEmpty || reports[id]?.statusText != nil {
                menuBar.append(MenuBarGroup(pluginID: id, title: pluginName, status: reports[id], items: menuItems))
            }
            if !finderItems.isEmpty {
                finder.append(FinderGroupEntry(pluginID: id, title: pluginName, items: finderItems.sorted { ($0.order, $0.title) < ($1.order, $1.title) },
                                               order: groupOrder[id.rawValue] ?? 1000))
            }
        }
        finder.sort { ($0.order, $0.pluginID) < ($1.order, $1.pluginID) }
        return EntryProjection(generation: generation, commands: commands, hotkeys: hotkeyEntries, menuBar: menuBar, finder: finder)
    }

    static func prefKey(_ pluginID: String, _ actionID: String, _ kind: PresentationKind) -> String {
        "\(pluginID)/\(actionID)/\(kind.rawValue)"
    }
}
