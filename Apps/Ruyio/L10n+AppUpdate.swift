import Foundation
import RuyioHostKit

/// Copy for Ruyio's own updates (decision A41).
extension L10n {
    var checkForUpdates: String { t("检查更新…", "Check for Updates…") }
    func downloadUpdateMenu(_ version: String) -> String { t("下载 Ruyio \(version)…", "Download Ruyio \(version)…") }
    func downloadingUpdateMenu(_ version: String) -> String { t("正在下载 Ruyio \(version)…", "Downloading Ruyio \(version)…") }
    func installUpdateMenu(_ version: String) -> String { t("安装 Ruyio \(version) 并重新打开", "Install Ruyio \(version) and Relaunch") }
    func updateReady(_ version: String) -> String { t("Ruyio \(version) 已下载，可以安装", "Ruyio \(version) is downloaded and ready to install") }
    var appVersionRow: String { t("Ruyio 更新", "Ruyio Updates") }
    var checkNow: String { t("检查更新", "Check Now") }
    var upToDate: String { t("已是最新版本", "Ruyio is up to date") }
    func updateAvailable(_ version: String) -> String { t("新版本 \(version) 可用", "Version \(version) is available") }
    var downloadUpdate: String { t("下载更新", "Download Update") }
    var releaseNotes: String { t("发行说明", "Release Notes") }
    func installUpdateTitle(_ version: String) -> String { t("安装 Ruyio \(version)？", "Install Ruyio \(version)?") }
    var installUpdateHelp: String {
        t("Ruyio 会退出，换成新版本后自动重新打开。辅助功能等系统授权会保留。", "Ruyio quits, is replaced with the new version and opens again. System permissions such as Accessibility are kept.")
    }
    var installAndRelaunch: String { t("安装并重新打开", "Install and Relaunch") }
    var localBuildNoUpdates: String { t("这是本地构建，不会自动更新。", "This is a local build; it does not update itself.") }
    var checkFailed: String { t("检查更新失败：", "Couldn't check for updates: ") }
    var updateFailed: String { t("更新失败：", "Update failed: ") }
    var relaunchManually: String { t("更新已安装，但无法自动重新打开：请退出 Ruyio 后再打开。", "The update is installed but Ruyio could not relaunch itself: quit Ruyio and open it again.") }
    var openDownloadPage: String { t("打开下载页面", "Open Download Page") }

    func installProblem(_ problem: AppUpdateService.InstallProblem) -> String {
        switch problem {
        case .translocated:
            return t("Ruyio 是从下载位置直接打开的，无法自行更新。请先把它移到“应用程序”文件夹，再重新打开。",
                     "Ruyio was opened straight from its download location and cannot update itself. Move it to the Applications folder and open it again.")
        case .notWritable:
            return t("当前用户无法修改 Ruyio 所在的位置。请从下载页面获取新版本并手动替换。",
                     "This user cannot modify Ruyio's location. Get the new version from the download page and replace Ruyio manually.")
        }
    }
}
