import Foundation
import RuyioPluginSDK

/// Official Finder Essentials plugin (PRD §9, §19.18). All file system effects go through the host.
public final class FinderEssentialsPlugin: RuyioPlugin, @unchecked Sendable {
    let context: PluginContext

    public init(context: PluginContext) {
        self.context = context
    }

    func t(_ zh: String, _ en: String) -> String { context.isChinese ? zh : en }

    public func checkHealth(_ request: DataPreparationRequest) async throws {
        // This plugin has no persistent business records; verify the candidate store is readable.
        _ = try await context.storage.count(StorageQuery(collection: "settings"))
    }

    public func perform(_ invocation: ActionInvocation, execution: ExecutionID, operation: OperationID?) async throws -> ActionResult {
        let finder = invocation.finder
        let selection = finder?.selection ?? []
        switch invocation.actionID.rawValue {
        case "copy-path":
            return try await copy(selection.map(\.path), noun: t("条路径", "paths"))
        case "copy-name":
            return try await copy(selection.map(\.name), noun: t("个文件名", "names"))
        case "copy-parent":
            // Parent directories are de-duplicated before copying (PRD §19.18).
            var seen = Set<String>()
            let parents = selection.map { ($0.path as NSString).deletingLastPathComponent }.filter { seen.insert($0).inserted }
            return try await copy(parents, noun: t("个父目录", "folders"))
        case "open-terminal":
            let targets = selection.isEmpty ? [finder?.targetDirectory].compactMap { $0 } : selection
            guard !targets.isEmpty else { throw RuyioError(.contextExpired, recovery: .retry) }
            try await context.capabilities.openTerminal(directories: targets)
            return .succeeded()
        case "open-editor":
            let targets = selection.isEmpty ? [finder?.targetDirectory].compactMap { $0 } : selection
            guard !targets.isEmpty else { throw RuyioError(.contextExpired, recovery: .retry) }
            try await context.capabilities.openInConfiguredApplication(role: "editor", targets: targets)
            return .succeeded()
        case "new-text-file":
            return try await newFile(invocation, ext: "txt", operation: operation)
        case "new-markdown-file":
            return try await newFile(invocation, ext: "md", operation: operation)
        case "toggle-hidden-files":
            let shown = try await context.capabilities.toggleHiddenFiles()
            return .succeeded(.notice(shown ? t("已显示隐藏文件", "Hidden files shown") : t("已隐藏隐藏文件", "Hidden files hidden")))
        default:
            throw RuyioError(.actionNotFound, objectID: invocation.actionID.rawValue)
        }
    }

    /// Multiple values are joined by newlines in Finder order; failures never overwrite the clipboard.
    func copy(_ values: [String], noun: String) async throws -> ActionResult {
        guard !values.isEmpty else { throw RuyioError(.contextExpired, recovery: .retry) }
        let text = values.joined(separator: "\n")
        try await context.capabilities.writeClipboard(ClipboardWriteRequest(
            items: [PasteboardItemPayload(representations: [PasteboardRepresentation(type: "public.utf8-plain-text", text: text)])],
            originToken: UUID().uuidString))
        return .succeeded(.notice(t("已复制 \(values.count) \(noun)", "Copied \(values.count) \(noun)")))
    }

    /// Name sheet first (awaitingInput), then a non-overwriting create (PRD §19.18).
    func newFile(_ invocation: ActionInvocation, ext: String, operation: OperationID?) async throws -> ActionResult {
        guard let directory = invocation.finder?.targetDirectory else { throw RuyioError(.contextExpired, recovery: .retry) }
        let defaultName = "Untitled.\(ext)"
        guard let raw = invocation.parameters["name"]?.stringValue else {
            return .succeeded(.requestInput(form(name: defaultName, error: nil, ext: ext, directory: directory.path)))
        }
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (name as NSString).pathExtension.isEmpty { name += ".\(ext)" }
        if let problem = validate(name) {
            return .succeeded(.requestInput(form(name: raw, error: problem, ext: ext, directory: directory.path)))
        }
        let reply = try await context.capabilities.writeFiles(
            FileWriteRequest(directory: directory, items: [FileWriteItem(fileName: name, source: .empty)], conflictPolicy: .fail, revealAfterWrite: true),
            operation: operation ?? OperationID())
        guard let outcome = reply.outcomes.first else { throw RuyioError(.fileWriteFailed) }
        switch outcome.status {
        case .written:
            return .succeeded(.notice(t("已创建 \(name)", "Created \(name)")))
        case .conflict:
            return .succeeded(.requestInput(form(name: raw, error: t("已存在同名文件，请修改名称", "A file with this name already exists"), ext: ext, directory: directory.path)))
        case .failed:
            throw RuyioError(ErrorCode(rawValue: outcome.errorCode ?? ErrorCode.fileWriteFailed.rawValue), objectID: name, recovery: .openSystemSettings)
        case .skipped, .cancelled:
            return ActionResult(state: .cancelled)
        }
    }

    func form(name: String, error: String?, ext: String, directory: String) -> FormSpec {
        FormSpec(fields: [
            FieldSpec(id: "name", label: t("文件名", "File name"), kind: .textField, value: .string(name), isRequired: true,
                      error: error, selectsBaseName: true),
        ], submitTitle: t("创建", "Create"), footnote: t("位置：", "Location: ") + (directory as NSString).abbreviatingWithTildeInPath)
    }

    func validate(_ name: String) -> String? {
        if name.isEmpty || name == "." || name == ".." { return t("请输入文件名", "Enter a file name") }
        if name.contains("/") || name.contains(":") { return t("文件名不能包含 / 或 :", "File names cannot contain / or :") }
        if name.hasPrefix(".") { return t("不能创建以“.”开头的隐藏文件", "Hidden files starting with “.” cannot be created here") }
        if name.utf8.count > 255 { return t("文件名过长", "File name is too long") }
        return nil
    }
}
