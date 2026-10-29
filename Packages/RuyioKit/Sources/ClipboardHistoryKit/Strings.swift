import Foundation

/// Plugin UI copy in zh-Hans and en (PRD §16). Keys stay stable; the host never translates plugin text.
struct Strings {
    let zh: Bool
    init(locale: String) { zh = locale.lowercased().hasPrefix("zh") }

    func t(_ zhText: String, _ enText: String) -> String { zh ? zhText : enText }

    var searchPlaceholder: String { t("搜索复制内容", "Search clipboard history") }
    var all: String { t("全部", "All") }
    var text: String { t("文本", "Text") }
    var image: String { t("图片", "Images") }
    var link: String { t("链接", "Links") }
    var json: String { "JSON" }
    var file: String { t("文件", "Files") }
    var favorites: String { t("收藏", "Favorites") }
    var paste: String { t("粘贴", "Paste") }
    var pastePlain: String { t("纯文本粘贴", "Paste as Plain Text") }
    var copyOnly: String { t("仅复制", "Copy Only") }
    var preview: String { t("预览", "Preview") }
    var favorite: String { t("收藏", "Favorite") }
    var unfavorite: String { t("取消收藏", "Unfavorite") }
    var delete: String { t("删除", "Delete") }
    var clearUnfavorited: String { t("清空未收藏…", "Clear Unfavorited…") }
    var emptyTitle: String { t("复制内容后会显示在这里", "Copied items will appear here") }
    var noResults: String { t("没有匹配结果", "No matching items") }
    var clearFilters: String { t("清除筛选", "Clear Filters") }
    var deleted: String { t("已删除 1 条记录", "Deleted 1 item") }
    var resume: String { t("恢复记录", "Resume Recording") }
    var pause: String { t("暂停记录", "Pause Recording") }
    var openSystemSettings: String { t("打开系统设置", "Open System Settings") }
    var recheck: String { t("重新检测", "Check Again") }
    var retry: String { t("重试", "Retry") }
    var pausedBanner: String { t("记录已暂停。恢复后只记录新的复制。", "Recording is paused. Only new copies are recorded after resuming.") }
    var blockedBanner: String { t("系统未允许读取剪贴板。", "macOS is not allowing clipboard access.") }
    var askBanner: String { t("系统设为每次询问。请在系统设置中允许 Ruyio 访问剪贴板。", "macOS asks each time. Allow Ruyio to access the clipboard in System Settings.") }
    var suspendedBanner: String { t("锁屏或睡眠后暂停，唤醒后继续。", "Paused while locked or asleep; resumes on wake.") }
    var failedBanner: String { t("记录已停止：", "Recording stopped: ") }
    var unknownBanner: String { t("无法确认系统是否允许读取剪贴板。", "Cannot confirm clipboard access.") }
    var fileMissing: String { t("文件已移动或删除", "File moved or deleted") }
    var copyPath: String { t("复制原路径", "Copy Original Path") }
    var source: String { t("来源", "Copied from") }
    var copiedAt: String { t("时间", "Copied") }
    var size: String { t("大小", "Size") }
    var count: String { t("数量", "Count") }
    var dimensions: String { t("尺寸", "Dimensions") }
    var times: String { t("复制次数", "Times Copied") }
    var showAll: String { t("显示全部历史…", "Show All History…") }
    var saveAsFilePrefix: String { t("存为文件：", "Save as File: ") }
    var clearConfirmTitle: String { t("清空未收藏的记录？", "Clear unfavorited items?") }
    func clearConfirmMessage(_ count: Int, _ favorites: Int) -> String {
        t("将删除 \(count) 条普通记录，保留 \(favorites) 条收藏。此操作无法撤销。",
          "\(count) items will be deleted and \(favorites) favorites kept. This cannot be undone.")
    }
    var clear: String { t("清空", "Clear") }
    func filesTitle(_ first: String, _ count: Int) -> String {
        count <= 1 ? first : t("\(first) 等 \(count) 个文件", "\(first) and \(count - 1) more")
    }
    func imageTitle(_ width: Int, _ height: Int) -> String { t("图片 \(width)×\(height)", "Image \(width)×\(height)") }
    func kindName(_ kind: PasteboardRules.Kind) -> String {
        switch kind {
        case .text: return t("文本", "Text")
        case .richText: return t("富文本", "Rich Text")
        case .image: return t("图片", "Image")
        case .url: return t("链接", "Link")
        case .file: return t("文件", "File")
        }
    }

    // Settings
    var settingsRecording: String { t("记录剪贴板", "Record Clipboard") }
    var settingsRetentionDays: String { t("保留天数", "Keep for (days)") }
    var settingsMaxRecords: String { t("最多保留条数", "Maximum items") }
    var settingsMaxMegabytes: String { t("最多占用空间（MB）", "Maximum disk space (MB)") }
    var openSettings: String { t("设置…", "Settings…") }
    func usageFootnote(records: Int, bytes: Int64, limitMegabytes: Int) -> String {
        let used = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return t("现有 \(records) 条，占用 \(used)，上限 \(limitMegabytes) MB。超出天数、条数或空间时，最旧的普通记录会被自动删除；收藏的条目不会被删除，但计入占用。",
                 "\(records) items using \(used) of \(limitMegabytes) MB. Past the days, items or space set here, the oldest regular items are removed; favorites are never removed but count toward the space.")
    }
    var settingsPasteMode: String { t("默认粘贴方式", "Default paste") }
    var settingsOriginal: String { t("原样粘贴", "Keep formatting") }
    var settingsPlain: String { t("纯文本粘贴", "Plain text") }
    var settingsAfterPaste: String { t("粘贴后动作", "After choosing an item") }
    var settingsAutoPaste: String { t("自动粘贴到原应用", "Paste into the previous app") }
    var settingsCopyOnly: String { t("仅复制，手动粘贴", "Copy only, paste manually") }
    var settingsIgnoredApps: String { t("忽略的应用（每行一个 Bundle ID）", "Ignored apps (one bundle ID per line)") }
    var settingsSave: String { t("保存", "Save") }
    var settingsSaved: String { t("设置已保存", "Settings saved") }
    func retentionPreview(_ count: Int) -> String {
        t("按新规则将删除 \(count) 条普通记录（收藏不受影响）。", "\(count) items will be removed under the new rules (favorites are kept).")
    }
}

extension Date {
    func relative(locale: String) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.unitsStyle = .short
        if abs(timeIntervalSinceNow) < 60 { return locale.hasPrefix("zh") ? "刚刚" : "now" }
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    func clock(locale: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(self) ? "HH:mm" : "MMMd HH:mm")
        return formatter.string(from: self)
    }
}
