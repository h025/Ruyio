import Foundation
import RuyioCore

extension L10n {
    /// Who signed a plugin (A39): an Apple team, a self-signed certificate, or nobody (ad-hoc).
    func publisher(_ publisherID: String?) -> String {
        if let fingerprint = PublisherID.certificateSHA256(publisherID) {
            return t("自签名证书 ", "Self-signed certificate ") + Self.fingerprintPrefix(fingerprint)
        }
        if let publisherID, !publisherID.isEmpty { return "Apple Team " + publisherID }
        return t("无（ad-hoc 签名）", "None (ad-hoc signature)")
    }

    /// The first 16 hex digits in groups of four, enough to compare two certificates by eye.
    static func fingerprintPrefix(_ hex: String) -> String {
        stride(from: 0, to: 16, by: 4).map { String(hex.dropFirst($0).prefix(4)).uppercased() }.joined(separator: " ")
    }

    var publisherPrefix: String { t("发布者：", "Publisher: ") }
    var notarizedByApple: String { t("已经 Apple 公证", "Notarized by Apple") }
    var notNotarizedByApple: String {
        t("未经 Apple 公证：插件仍在沙盒中运行，只能使用列出的权限", "Not notarized by Apple: the plugin still runs in the sandbox, with only the permissions listed")
    }

    /// Install verification steps (`VerificationCheck.name`).
    func checkName(_ name: String) -> String {
        switch name {
        case "manifest": return t("清单", "Manifest")
        case "compatibility": return t("兼容性", "Compatibility")
        case "architecture": return t("架构", "Architecture")
        case "bundle": return t("App 结构", "App bundle")
        case "nestedCode": return t("内嵌代码", "Nested code")
        case "signature": return t("签名", "Signature")
        case "signingIdentity": return t("签名标识", "Signing identifier")
        case "entitlements": return t("签名权限", "Entitlements")
        case "publisher": return t("发布者证书", "Publisher certificate")
        case "officialNamespace": return t("官方插件 ID", "Official plugin ID")
        case "descriptor": return t("与描述文件一致", "Matches its descriptor")
        case "sha256": return "SHA-256"
        default: return name
        }
    }
}
