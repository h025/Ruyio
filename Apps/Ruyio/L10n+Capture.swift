import Foundation

/// Copy for screen capture and pinned images (decision A35).
extension L10n {
    var screenRecordingTitle: String { t("需要屏幕录制权限", "Screen Recording Needed") }
    var screenRecordingMessage: String {
        t("截图由“Ruyio 截图助手”完成。请在“系统设置 › 隐私与安全性 › 屏幕与系统录音”中打开它，然后再截一次。Ruyio 主程序和插件都不会获得这项权限。",
          "Screenshots are taken by “Ruyio Capture Helper”. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then capture again. Neither Ruyio nor its plugins receive this permission.")
    }
    func pinTitle(_ plugin: String) -> String { t("钉图 · \(plugin)", "Pinned Image · \(plugin)") }
    func pinTooltip(_ plugin: String) -> String {
        t("来自插件“\(plugin)”。拖动可移动，滚动可缩放，右键查看更多选项。",
          "From “\(plugin)”. Drag to move, scroll to zoom, right-click for more.")
    }
    var copy: String { t("复制", "Copy") }
    var saveAs: String { t("存储为…", "Save As…") }
    var actualSize: String { t("实际大小", "Actual Size") }
    var zoomIn: String { t("放大", "Zoom In") }
    var zoomOut: String { t("缩小", "Zoom Out") }
    var opacity: String { t("不透明度", "Opacity") }
    var close: String { t("关闭", "Close") }
    var closeAllPins: String { t("关闭所有钉图", "Close All Pinned Images") }
    var screenshotFileName: String { t("截图", "Screenshot") }
    var developerModeInstall: String { t("未经 Apple 公证，将作为开发者插件安装", "Not notarized by Apple; installs as a developer plugin") }
}
