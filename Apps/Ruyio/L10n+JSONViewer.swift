import Foundation
import RuyioUI

/// Copy for the collapsible, searchable JSON preview.
extension L10n {
    var jsonViewer: JSONViewerStrings {
        let zh = self.zh
        return JSONViewerStrings(
            find: t("在 JSON 中查找（⌘F）", "Find in JSON (⌘F)"), noMatches: t("无结果", "No matches"),
            previous: t("上一个（⇧↩）", "Previous (⇧↩)"), next: t("下一个（↩）", "Next (↩)"),
            expand: t("展开", "Expand"), collapse: t("收起", "Collapse"),
            expandAll: t("全部展开", "Expand All"), collapseAll: t("全部收起", "Collapse All"),
            copyValue: t("拷贝值", "Copy Value"), copyPath: t("拷贝路径", "Copy Path"),
            truncated: t("预览只包含这段 JSON 的开头部分。", "The preview shows the beginning of this JSON only."),
            keys: { count in zh ? "\(count) 个键" : count == 1 ? "1 key" : "\(count) keys" },
            items: { count in zh ? "\(count) 项" : count == 1 ? "1 item" : "\(count) items" })
    }
}
